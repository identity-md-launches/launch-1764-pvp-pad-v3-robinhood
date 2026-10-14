// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadLib} from "./libs/PadLib.sol";
import {Lock} from "../lib/v4-core/src/libraries/Lock.sol";
import {PadHook} from "./PadHook.sol";
import {
    IArbSys,
    IPoolManager,
    IPoolStateReader,
    IUnlockCallback,
    IPadToken,
    IPvPPad,
    PoolKey,
    ModifyLiquidityParams,
    SwapParams
} from "./interfaces/Interfaces.sol";

interface IKingView {
    function king() external view returns (address);
}

/// @title PadLiquidity
/// @notice Graduates launches into Uniswap v4 pools (native ETH / token, fee 10000, tickSpacing 200,
/// hooks = PadHook), owns the full-range LP forever, collects its fees for the king, and buys and
/// burns PvP with the burn bucket. All v4 interaction goes through PoolManager.unlock with own funds.
contract PadLiquidity is IUnlockCallback {
    uint24 public constant FEE = 10_000;
    int24 public constant TICK_SPACING = 200;
    int24 public constant MIN_TICK = -887_200;
    int24 public constant MAX_TICK = 887_200;
    // TickMath.getSqrtPriceAtTick(-887200) and (887200) of v4-core v4.0.0; asserted in LiquidityV4.t.sol.
    uint160 public constant SQRT_MIN_FULL = 4_310_618_292;
    uint160 public constant SQRT_MAX_FULL = 1_456_195_216_270_955_103_206_513_029_158_776_779_468_408_838_535;
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4_295_128_740;
    uint256 internal constant Q96 = 1 << 96;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BURN_MAX = 0.02 ether;
    uint256 public constant BURN_INTERVAL = 10 minutes;
    uint256 public constant COLLECT_GAS = 300_000;
    uint256 public constant MAX_DISTRIBUTE_POOLS = 16;
    uint256 internal constant COLLECTION_RESERVE_GAS = 100_000;
    uint256 internal constant BROKEN_FAILURES = 3;
    uint256 internal constant LIQUIDITY_MARGIN_PPM = 1_000_000;
    /// @notice Each burn buy is limited to this sqrt-price move from the
    /// pre-swap spot: 0.5% in sqrt price, about 1% in price. Unfilled input stays for a later chunk.
    /// This bounds per-call impact; it is not a general guarantee against MEV or spot manipulation.
    uint256 public constant IMPACT_BPS = 50;
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    uint8 internal constant ACT_ADD = 1;
    uint8 internal constant ACT_COLLECT = 2;
    uint8 internal constant ACT_BURN = 3;

    struct Pool {
        uint256 launchId;
        address token;
        uint128 liquidity;
        uint256 ethFees;
        uint256 tokenFees;
        uint64 lastFailureBlock;
        uint8 failures;
    }

    IPoolManager public immutable poolManager;
    address public immutable pad;
    address public king;
    address public hook;
    uint256 public burnBucket;
    uint64 public lastBurnAt;
    uint256 public distributeCursor;
    uint256 public totalBurnedEth;
    bool private locked;
    bool private claimLocked;

    Pool[] internal pools;
    mapping(uint256 => uint256) public poolIndexOf; // launchId => index + 1
    mapping(address => uint256) public claimable;

    event KingBound(address indexed king);
    event HookDeployed(address indexed hook, bytes32 salt);
    event Graduated(
        uint256 indexed launchId,
        address indexed token,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 eth,
        uint256 tokens,
        uint256 burnedTokens
    );
    event BurnFunded(address indexed from, uint256 amount);
    event Burned(uint256 ethSpent, uint256 tokensBurned);
    event FeesCollected(uint256 indexed launchId, address indexed king, uint256 eth, uint256 tokens);
    event PoolCollectionFailed(uint256 indexed launchId);
    event PoolHealth(uint256 indexed launchId, uint256 failures, bool broken);
    event KingPaid(address indexed king, uint256 amount, bool pushed);
    event Claimed(address indexed to, uint256 amount);

    modifier guard() {
        require(!locked, "reentrancy");
        locked = true;
        _;
        locked = false;
    }

    constructor(address poolManager_, address pad_) {
        require(poolManager_ != address(0) && pad_ != address(0), "zero");
        poolManager = IPoolManager(poolManager_);
        pad = pad_;
        IPvPPad(pad_).bindLiquidity();
    }

    /// @dev Only the PoolManager pays ETH here (fee collection); everything else uses fundBurn/graduate.
    receive() external payable {
        require(msg.sender == address(poolManager), "not pool manager");
    }

    function bindKing() external {
        require(king == address(0), "bound");
        king = msg.sender;
        emit KingBound(msg.sender);
    }

    // ---- hook ------------------------------------------------------------------------------------
    function deployHook(bytes32 salt) external returns (address h) {
        require(msg.sender == pad, "not pad");
        require(hook == address(0), "deployed");
        h = address(new PadHook{salt: salt}(address(poolManager), address(this)));
        hook = h;
        emit HookDeployed(h, salt);
    }

    /// @notice Init code hash to mine the open salt against (CREATE2 from this contract).
    function hookInitCodeHash() public view returns (bytes32) {
        return keccak256(abi.encodePacked(type(PadHook).creationCode, abi.encode(address(poolManager), address(this))));
    }

    function hookAddressFor(bytes32 salt) public view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitCodeHash()))))
            );
    }

    // ---- graduation ------------------------------------------------------------------------------
    function poolKey(address token) public view returns (PoolKey memory) {
        return PoolKey(address(0), token, FEE, TICK_SPACING, hook);
    }

    /// @notice Called by a launch's game inside its graduation: tokens already transferred here, ETH sent.
    function graduate(uint256 launchId, address token, uint256 tokenAmount, uint256 vEth, uint256 vTok)
        external
        payable
        guard
    {
        require(msg.sender == IPvPPad(pad).gameOf(launchId), "not game");
        require(hook != address(0), "pad not open");
        require(poolIndexOf[launchId] == 0, "graduated");
        require(msg.value != 0 && tokenAmount != 0, "empty");
        uint160 sqrtP = uint160(PadLib.sqrt(PadLib.mulDiv(vTok, Q96 * Q96, vEth)));
        if (sqrtP <= SQRT_MIN_FULL) sqrtP = SQRT_MIN_FULL + 1;
        if (sqrtP >= SQRT_MAX_FULL) sqrtP = SQRT_MAX_FULL - 1;
        uint256 l0 = PadLib.mulDiv(msg.value, PadLib.mulDiv(sqrtP, SQRT_MAX_FULL, Q96), SQRT_MAX_FULL - sqrtP);
        uint256 l1 = PadLib.mulDiv(tokenAmount, Q96, sqrtP - SQRT_MIN_FULL);
        uint256 l = l0 < l1 ? l0 : l1;
        l = l - l / LIQUIDITY_MARGIN_PPM;
        require(l != 0 && l <= type(uint128).max, "liquidity");

        PoolKey memory key = poolKey(token);
        poolManager.initialize(key, sqrtP);
        bytes memory res = poolManager.unlock(abi.encode(ACT_ADD, key, l, msg.value, tokenAmount));
        (uint256 usedEth, uint256 usedTok) = abi.decode(res, (uint256, uint256));

        pools.push(Pool(launchId, token, uint128(l), 0, 0, 0, 0));
        poolIndexOf[launchId] = pools.length;
        IPadToken(token).unlock();
        uint256 excess = IPadToken(token).balanceOf(address(this));
        if (excess != 0) require(IPadToken(token).transfer(DEAD, excess), "burn");
        if (msg.value > usedEth) burnBucket += msg.value - usedEth;
        emit Graduated(launchId, token, sqrtP, uint128(l), usedEth, usedTok, excess);
    }

    // ---- fees to the king -----------------------------------------------------------------------
    /// @notice Reject nested v4 unlocks even when this contract itself is idle.
    /// The slot comes directly from the pinned v4-core Lock library.
    function requireManagerLocked() public view {
        require(
            IPoolStateReader(address(poolManager)).exttload(Lock.IS_UNLOCKED_SLOT) == bytes32(0), "manager unlocked"
        );
    }

    /// @notice Permissionless round-robin collection. Fees stay in positions before the first crown.
    /// Three failed, fully gas-funded attempts in distinct L2 blocks flag a pool as broken.
    function distribute(uint256 n) external guard {
        _distribute(n, false);
    }

    /// @notice Atomic pre-crown batch: an unflagged collection failure vetoes the bid.
    /// Failed bids revert their failure counters too; use distribute/retryPool to diagnose a pool.
    function settleCrown() external guard {
        require(msg.sender == king, "not king");
        _distribute(MAX_DISTRIBUTE_POOLS, true);
    }

    function _distribute(uint256 n, bool strict) internal {
        requireManagerLocked();
        address k = IKingView(king).king();
        uint256 count = pools.length;
        if (k == address(0) || count == 0 || n == 0) return;
        if (n > MAX_DISTRIBUTE_POOLS) n = MAX_DISTRIBUTE_POOLS;
        if (n > count) n = count;
        for (uint256 i; i < n; ++i) {
            uint256 idx = distributeCursor % count;
            if (pools[idx].failures < BROKEN_FAILURES) {
                if (gasleft() < COLLECT_GAS + COLLECTION_RESERVE_GAS) {
                    require(!strict, "collection gas");
                    break;
                }
                bool ok = _collect(idx, k);
                require(ok || !strict, "pool collection failed");
            }
            distributeCursor = idx + 1;
        }
    }

    /// @notice Anyone can retry any pool, including a broken one. Success clears the flag.
    function retryPool(uint256 idx) external guard returns (bool) {
        requireManagerLocked();
        address k = IKingView(king).king();
        require(k != address(0), "no king");
        require(gasleft() >= COLLECT_GAS + COLLECTION_RESERVE_GAS, "collection gas");
        return _collect(idx, k);
    }

    function _collect(uint256 idx, address k) internal returns (bool) {
        Pool storage p = pools[idx];
        try this.collectPool{gas: COLLECT_GAS}(idx, k) {
            if (p.failures != 0) {
                p.failures = 0;
                p.lastFailureBlock = 0;
                emit PoolHealth(p.launchId, 0, false);
            }
            return true;
        } catch {
            uint256 current = IArbSys(address(0x64)).arbBlockNumber();
            if (p.failures < BROKEN_FAILURES && (p.failures == 0 || current > p.lastFailureBlock)) {
                p.lastFailureBlock = uint64(current);
                ++p.failures;
                emit PoolHealth(p.launchId, p.failures, p.failures == BROKEN_FAILURES);
            }
            emit PoolCollectionFailed(p.launchId);
            return false;
        }
    }

    /// @dev The self-call isolates a pool's revert. Both currencies are paid to the captured king;
    /// tokens are never swapped or stashed, and rejected ETH stays owed to that same king.
    function collectPool(uint256 idx, address k) external {
        require(msg.sender == address(this) && locked, "not self");
        Pool storage p = pools[idx];
        bytes memory res = poolManager.unlock(abi.encode(ACT_COLLECT, poolKey(p.token)));
        (uint256 e, uint256 t) = abi.decode(res, (uint256, uint256));
        p.ethFees += e;
        p.tokenFees += t;
        if (t != 0) require(IPadToken(p.token).transfer(k, t), "token fees");
        if (e != 0) {
            bool ok = PadLib.push(k, e);
            if (!ok) claimable[k] += e;
            emit KingPaid(k, e, ok);
        }
        emit FeesCollected(p.launchId, k, e, t);
    }

    // ---- burn ------------------------------------------------------------------------------------
    function fundBurn() external payable {
        burnBucket += msg.value;
        emit BurnFunded(msg.sender, msg.value);
    }

    /// @notice Buys PvP with up to 0.02 ETH of the burn bucket and sends it to dEaD, once per 10 minutes.
    /// The buy stops at a 1% price move; ETH not spent stays in the bucket for the next chunk.
    function burnChunk() external guard {
        uint256 gid = IPvPPad(pad).genesisId();
        uint256 idx = gid == 0 ? 0 : poolIndexOf[gid];
        if (burnBucket == 0 || idx == 0) return;
        if (block.timestamp < lastBurnAt + BURN_INTERVAL) return;
        uint256 amount = burnBucket > BURN_MAX ? BURN_MAX : burnBucket;
        burnBucket -= amount;
        lastBurnAt = uint64(block.timestamp);
        bytes memory res = poolManager.unlock(abi.encode(ACT_BURN, poolKey(pools[idx - 1].token), amount));
        (uint256 spent, uint256 tokens) = abi.decode(res, (uint256, uint256));
        if (spent < amount) burnBucket += amount - spent;
        totalBurnedEth += spent;
        emit Burned(spent, tokens);
    }

    /// @notice Current sqrt price of a pool, read from the PoolManager's storage (v4 StateLibrary layout).
    function sqrtPriceOf(PoolKey memory key) public view returns (uint160) {
        bytes32 slot = keccak256(abi.encodePacked(keccak256(abi.encode(key)), POOLS_SLOT));
        return uint160(uint256(IPoolStateReader(address(poolManager)).extsload(slot)));
    }

    /// @dev Burn-buy price limit `IMPACT_BPS` below spot, kept above the minimum valid price.
    function _priceLimit(PoolKey memory key) internal view returns (uint160) {
        uint256 spot = sqrtPriceOf(key);
        uint256 limit = spot - spot * IMPACT_BPS / 10_000;
        if (limit <= MIN_SQRT_PRICE_LIMIT) limit = MIN_SQRT_PRICE_LIMIT + 1;
        return uint160(limit);
    }

    /// @notice Pays a parked king payment to its owner. Uses its own lock, not the pool `guard`: the
    /// claimer receives all remaining gas, and holding the pool lock while untrusted code runs would
    /// let a claimer bid for the crown while `distribute` is unreachable (revision finding e2ea0e40).
    function claim() external {
        require(!claimLocked, "reentrancy");
        claimLocked = true;
        uint256 amount = claimable[msg.sender];
        require(amount != 0, "nothing");
        claimable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "claim failed");
        emit Claimed(msg.sender, amount);
        claimLocked = false;
    }

    // ---- v4 callback -----------------------------------------------------------------------------
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        uint8 action = abi.decode(data, (uint8));
        if (action == ACT_ADD) {
            (, PoolKey memory key, uint256 l, uint256 maxEth, uint256 maxTok) =
                abi.decode(data, (uint8, PoolKey, uint256, uint256, uint256));
            (int256 delta,) =
                poolManager.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, int256(l), 0), "");
            (int128 a0, int128 a1) = _split(delta);
            require(a0 <= 0 && a1 <= 0, "delta sign");
            uint256 owe0 = uint256(uint128(-a0));
            uint256 owe1 = uint256(uint128(-a1));
            require(owe0 <= maxEth && owe1 <= maxTok, "owes too much");
            _settleEth(owe0);
            _settleToken(key.currency1, owe1);
            return abi.encode(owe0, owe1);
        }
        if (action == ACT_COLLECT) {
            (, PoolKey memory key) = abi.decode(data, (uint8, PoolKey));
            (, int256 fees) = poolManager.modifyLiquidity(key, ModifyLiquidityParams(MIN_TICK, MAX_TICK, 0, 0), "");
            (int128 f0, int128 f1) = _split(fees);
            uint256 e = f0 > 0 ? uint256(uint128(f0)) : 0;
            uint256 t = f1 > 0 ? uint256(uint128(f1)) : 0;
            if (e != 0) poolManager.take(address(0), address(this), e);
            if (t != 0) poolManager.take(key.currency1, address(this), t);
            return abi.encode(e, t);
        }
        if (action == ACT_BURN) {
            (, PoolKey memory key, uint256 amount) = abi.decode(data, (uint8, PoolKey, uint256));
            int256 d = poolManager.swap(key, SwapParams(true, -int256(amount), _priceLimit(key)), "");
            (int128 s0, int128 s1) = _split(d);
            require(s0 <= 0, "swap sign");
            uint256 spent = uint256(uint128(-s0));
            require(spent <= amount, "overspent");
            _settleEth(spent);
            uint256 out = s1 > 0 ? uint256(uint128(s1)) : 0;
            if (out != 0) poolManager.take(key.currency1, DEAD, out);
            return abi.encode(spent, out);
        }
        revert("bad action");
    }

    function _settleEth(uint256 amount) internal {
        if (amount == 0) return;
        // v4 sync is permissionless and transient across unlocks in the same transaction.
        // Explicitly select native ETH so a preceding token sync cannot poison settlement.
        poolManager.sync(address(0));
        poolManager.settle{value: amount}();
    }

    function _settleToken(address token, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(token);
        require(IPadToken(token).transfer(address(poolManager), amount), "token");
        poolManager.settle();
    }

    function _split(int256 delta) internal pure returns (int128 a0, int128 a1) {
        assembly ("memory-safe") {
            a0 := sar(128, delta)
            a1 := signextend(15, delta)
        }
    }

    // ---- views -----------------------------------------------------------------------------------
    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function getPool(uint256 idx) external view returns (Pool memory) {
        return pools[idx];
    }

    function currentKing() external view returns (address) {
        return king == address(0) ? address(0) : IKingView(king).king();
    }
}
