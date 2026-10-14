// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PadLib} from "./libs/PadLib.sol";
import {IArbSys, IPadToken, IPvPPad, IPadLiquidity} from "./interfaces/Interfaces.sol";

/// @title PadGame
/// @notice Template (EIP-1167 cloned per launch) holding one launch's bonding curve and its Spireth game.
/// Wall-clock rules (signup, cooldown, death, 50 min play cap) use block.timestamp; randomness and the
/// commit window use ArbSys (0x64) arbBlockNumber / arbBlockHash, never block.number or blockhash.
contract PadGame {
    using PadLib for *;

    // ---- constants -------------------------------------------------------------------------
    IArbSys internal constant ARB = IArbSys(address(0x64));
    uint256 public constant ROLL_PRICE = 0.002 ether;
    uint256 public constant COOLDOWN = 60;
    uint256 public constant SIGNUP = 10 minutes;
    uint256 public constant DEATH = 10 minutes;
    uint256 public constant MAX_PLAY = 50 minutes;
    uint256 public constant ENTRY_PRICE = 0.001 ether;
    uint256 public constant DRAW_BATCH = 32;
    uint256 public constant MAX_IMPS = 200;
    int256 public constant HEIGHT_CAP = 50;
    uint256 public constant RESOLVE_BATCH = 16;
    uint256 public constant ROLL_TIP = ROLL_PRICE / 100;
    uint256 internal constant RESOLVE_GAS_FLOOR = 200_000;
    uint256 public constant HASH_WINDOW = 256;
    uint256 public constant VETH = 1 ether;
    uint256 public constant VTOK = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant K = VETH * VTOK;
    uint256 public constant FINALIZER_BPS = 50;
    uint256 public constant FINALIZER_MAX = 0.005 ether;
    /// @notice Funded ETH (carry pot, king share) is paid out only when at least this many Imps live at the end.
    uint256 public constant FUNDED_MIN_LIVING = 5;
    /// @notice Funded ETH paid out is capped at this multiple of the roll-earned pot; the rest returns to the carry.
    uint256 public constant FUNDED_RELEASE_MULTIPLE = 3;
    /// @notice Funded ETH paid out is also capped at this share of the curve ETH raised. A sole buyer who
    /// dumps every token into the graduated pool recovers at most 0.99(1+e)/(1.99+0.99e) of the e ETH
    /// in the curve (83% at the 4 ETH sell-out), so at least e/(1.99+0.99e) > e/6 stays in the pool
    /// forever; a release below that is a loss to any sybil however the roll pot was inflated.
    uint256 public constant FUNDED_RELEASE_CURVE_BPS = 1_500;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ---- types ----------------------------------------------------------------------------
    struct Imp {
        address owner;
        int16 height;
        uint40 lastRoll;
        uint40 heightReachedAt; // commit L2 block of the roll that reached the current height
        uint32 nonce;
        uint32 pendingRoll; // roll index + 1, 0 when none pending
        uint32 heightRoll; // roll index + 1 that reached the current height (tie-break inside one block)
    }

    struct Roll {
        uint32 imp;
        uint32 nonce;
        uint64 commitBlock;
        bool resolved;
        bool expired;
        int8 delta;
    }

    // ---- state ----------------------------------------------------------------------------
    address public pad;
    address public token;
    address public liquidity;
    uint256 public launchId;
    bool public genesis;
    bool private initialized;
    bool private locked;

    uint256 public ethRaised;
    uint256 public tokensSold;
    uint256 public pot; // total: roll-earned + funded

    uint64 public firstEntryAt;
    uint64 public bellAt;
    uint64 public maxActivity;
    address public bellRinger;
    bool public finalized;
    bool public graduated;
    bool public failed;
    uint32 public livingAtEnd;
    uint32 public paidAtEnd;

    Imp[] internal imps;
    mapping(address => uint256) public impOf; // index + 1
    Roll[] internal rolls;
    uint256 public nextPending;
    uint256 public pendingCount;
    mapping(address => uint256) public claimable;
    uint256 public fundedPot; // part of `pot` that came from the pad (carry pot, king share)

    // Appended state keeps the existing game accounting layout intact.
    address[] internal entrants;
    mapping(address => uint256) public entryOf; // 1-based; zero means not entered
    mapping(uint256 => uint256) private shuffled; // sparse Fisher-Yates, value + 1
    uint256 public drawCommitBlock;
    bytes32 public drawSeed;
    uint256 public drawNonce;
    bool public drawCommitted;
    bool public drawSeeded;
    bool public drawComplete;
    uint64 public playStartedAt;
    uint256 public drawBounty;

    // ---- events ---------------------------------------------------------------------------
    event Initialized(uint256 indexed launchId, address indexed token, bool genesis);
    event Entered(address indexed owner, uint256 indexed entry, bool signupStarted);
    event DrawCommitted(uint256 indexed commitBlock);
    event DrawBounty(address indexed capturer, uint256 amount);
    event ResolverTip(uint256 indexed roll, address indexed resolver, uint256 amount, bool expired);
    event DrawSeedReady(uint256 indexed commitBlock, bytes32 seed);
    event Seated(address indexed owner, uint256 indexed imp, uint256 indexed entry);
    event DrawProgress(uint256 seats, uint256 target, uint256 nonce);
    event PlayStarted(uint256 at, uint256 hardEnd);
    event Rolled(address indexed owner, uint256 indexed imp, uint256 indexed roll, uint256 commitBlock, uint256 tokens);
    event Resolved(uint256 indexed roll, uint256 indexed imp, int256 delta, int256 height, bool expired);
    event Bell(uint256 indexed imp, address indexed ringer, int256 height);
    event CurveBuy(uint256 ethIn, uint256 ethToCurve, uint256 tokensOut, uint256 ethToPot);
    event PotFunded(address indexed from, uint256 amount);
    event Finalized(address indexed finalizer, uint256 pot, uint256 living, uint256 paid, bool bell);
    event FundedReturned(uint256 amount);
    event Paid(address indexed to, uint256 amount, bool pushed);
    event Claimed(address indexed to, uint256 amount);
    event Graduated(uint256 eth, uint256 tokens);
    event Failed(uint256 tokensBurned);

    modifier guard() {
        require(!locked, "reentrancy");
        locked = true;
        _;
        locked = false;
    }

    constructor() {
        initialized = true;
    }

    // ---- lifecycle ------------------------------------------------------------------------
    function initialize(uint256 launchId_, address token_, address liquidity_, bool genesis_) external {
        require(!initialized, "initialized");
        initialized = true;
        pad = msg.sender;
        token = token_;
        liquidity = liquidity_;
        launchId = launchId_;
        genesis = genesis_;
        emit Initialized(launchId_, token_, genesis_);
    }

    /// @notice One nonrefundable entry per wallet, no entry cap. First entry starts signup.
    function enter() external payable guard {
        require(IPvPPad(pad).opened(), "pad not open");
        require(msg.value == ENTRY_PRICE, "entry price");
        require(entryOf[msg.sender] == 0, "one entry per wallet");
        bool first = entrants.length == 0;
        if (first) firstEntryAt = uint64(block.timestamp);
        else require(block.timestamp < signupEnd(), "signup over");
        entrants.push(msg.sender);
        entryOf[msg.sender] = entrants.length;
        emit Entered(msg.sender, entrants.length, first);
        if (first) drawBounty = msg.value;
        else IPadLiquidity(liquidity).fundBurn{value: msg.value}();
        if (first) IPvPPad(pad).noteFirstEntry(launchId);
        IPvPPad(pad).upkeepFor(msg.sender);
    }

    /// @notice Commit or advance the raffle. At most DRAW_BATCH random trials per call.
    /// n cannot select a seed or change the result; it only bounds work.
    function draw(uint256 n) external guard {
        require(IPvPPad(pad).opened(), "pad not open");
        require(entrants.length != 0 && block.timestamp >= signupEnd(), "signup not over");
        require(n != 0, "zero chunk");
        _draw(n, msg.sender);
    }

    function _draw(uint256 n, address caller) internal {
        if (drawComplete || entrants.length == 0 || block.timestamp < signupEnd()) return;
        uint256 cur = ARB.arbBlockNumber();
        if (!drawSeeded) {
            if (!drawCommitted) {
                drawCommitBlock = cur;
                drawCommitted = true;
                emit DrawCommitted(cur);
                return;
            }
            if (cur <= drawCommitBlock + 3) return;
            if (cur > drawCommitBlock + 1 + HASH_WINDOW) {
                drawSeed = keccak256(abi.encode(address(this), drawCommitBlock, entrants.length));
            } else {
                drawSeed = keccak256(
                    abi.encode(
                        address(this),
                        ARB.arbBlockHash(drawCommitBlock + 1),
                        ARB.arbBlockHash(drawCommitBlock + 2),
                        ARB.arbBlockHash(drawCommitBlock + 3)
                    )
                );
            }
            drawSeeded = true;
            emit DrawSeedReady(drawCommitBlock, drawSeed);
            uint256 bounty = drawBounty;
            drawBounty = 0;
            _pay(caller, bounty);
            emit DrawBounty(caller, bounty);
        }
        if (n > DRAW_BATCH) n = DRAW_BATCH;
        uint256 total = entrants.length;
        uint256 target = total < MAX_IMPS ? total : MAX_IMPS;
        for (uint256 trial; trial < n && imps.length < target; ++trial) {
            uint256 remaining = total - imps.length;
            uint256 rand = uint256(keccak256(abi.encode(drawSeed, drawNonce++)));
            // Rejection sampling eliminates modulo bias. Even rejection is bounded by n.
            uint256 threshold;
            unchecked {
                threshold = (0 - remaining) % remaining;
            }
            if (rand < threshold) continue;
            uint256 pick = rand % remaining;
            uint256 entry = shuffled[pick];
            entry = entry == 0 ? pick : entry - 1;
            uint256 last = shuffled[remaining - 1];
            shuffled[pick] = last == 0 ? remaining : last;
            address who = entrants[entry];
            imps.push(Imp(who, 0, 0, 0, 0, 0, 0));
            impOf[who] = imps.length;
            emit Seated(who, imps.length, entry + 1);
        }
        emit DrawProgress(imps.length, target, drawNonce);
        if (imps.length == target) {
            drawComplete = true;
            playStartedAt = uint64(block.timestamp);
            maxActivity = uint64(block.timestamp);
            emit PlayStarted(block.timestamp, block.timestamp + MAX_PLAY);
        }
    }

    /// @notice Roll the dice: 0.002 ETH, 60 s cooldown, 90% curve, 7% pot, 2% burn (genesis: pot), 1% resolver tip.
    function roll() external payable guard {
        require(IPvPPad(pad).opened(), "pad not open");
        require(msg.value == ROLL_PRICE, "roll price");
        require(drawComplete, "not playing");
        uint256 idx = impOf[msg.sender];
        require(idx != 0, "no imp");
        require(!ended(), "game over");
        Imp storage imp = imps[idx - 1];
        require(_lastActivity(imp) + DEATH > block.timestamp, "imp dead");
        require(imp.lastRoll == 0 || imp.lastRoll + COOLDOWN <= block.timestamp, "cooldown");
        if (imp.pendingRoll != 0) _resolveRoll(imp.pendingRoll - 1, msg.sender);
        require(!ended(), "game over"); // the previous roll may have rung the bell just now

        uint256 curveEth = msg.value * 90 / 100;
        uint256 burnEth = msg.value * 2 / 100;
        uint256 potEth = msg.value - curveEth - burnEth - ROLL_TIP;
        (uint256 tokensOut, uint256 ethUsed) = _buy(curveEth);
        potEth += curveEth - ethUsed;
        if (genesis) potEth += burnEth;
        pot += potEth;
        emit CurveBuy(msg.value, ethUsed, tokensOut, potEth);

        uint256 rollId = rolls.length;
        rolls.push(Roll(uint32(idx - 1), imp.nonce, uint64(ARB.arbBlockNumber()), false, false, 0));
        imp.nonce += 1;
        imp.pendingRoll = uint32(rollId + 1);
        imp.lastRoll = uint40(block.timestamp);
        if (block.timestamp > maxActivity) maxActivity = uint64(block.timestamp);
        pendingCount += 1;
        emit Rolled(msg.sender, idx - 1, rollId, rolls[rollId].commitBlock, tokensOut);

        if (tokensOut != 0) require(IPadToken(token).transfer(msg.sender, tokensOut), "token");
        if (!genesis && burnEth != 0) IPadLiquidity(liquidity).fundBurn{value: burnEth}();
        _resolve(RESOLVE_BATCH, msg.sender);
        IPvPPad(pad).upkeepFor(msg.sender);
    }

    /// @notice Permissionless upkeep for this game plus the pad's bounded upkeep.
    function poke() external guard {
        _draw(DRAW_BATCH, msg.sender);
        _resolve(RESOLVE_BATCH, msg.sender);
        if (entrants.length != 0) {
            if (!finalized) _finalize(msg.sender);
            else if (!graduated) _graduate();
        }
        IPvPPad(pad).upkeepFor(msg.sender);
    }

    /// @notice Ranks living Imps and pays the pot. Permissionless once the game has ended.
    function finalize() external guard {
        _resolve(RESOLVE_BATCH, msg.sender);
        require(_finalize(msg.sender), "not finalizable");
        IPvPPad(pad).upkeepFor(msg.sender);
    }

    /// @notice Moves curve ETH and remaining tokens into the v4 pool (or burns all when no ETH was raised).
    function graduate() external guard {
        require(_graduate(), "not graduable");
        IPvPPad(pad).upkeepFor(msg.sender);
    }

    /// @notice Pad-driven bounded upkeep: one draw chunk, roll resolution and one lifecycle step.
    function upkeepStep(address caller) external {
        require(msg.sender == pad, "not pad");
        if (locked || entrants.length == 0) return;
        locked = true;
        _draw(DRAW_BATCH, caller);
        _resolve(RESOLVE_BATCH, caller);
        if (!finalized) {
            _finalize(caller);
        } else if (!graduated) {
            _graduate();
        }
        locked = false;
    }

    function resolvePending(uint256 max) external guard {
        _resolve(max, msg.sender);
    }

    /// @notice Pad-only top-up (bounded carry at finalization, king's games share). Tracked apart from roll
    /// income: it is paid out only to a game with >= 5 living Imps, capped at 3x the roll-earned pot,
    /// and otherwise returns to the carry pot at the end.
    function fundPot() external payable {
        require(msg.sender == pad, "not pad");
        require(!finalized, "finalized");
        pot += msg.value;
        fundedPot += msg.value;
        emit PotFunded(msg.sender, msg.value);
    }

    function claim() external guard {
        uint256 amount = claimable[msg.sender];
        require(amount != 0, "nothing");
        claimable[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "claim failed");
        emit Claimed(msg.sender, amount);
    }

    // ---- views ------------------------------------------------------------------------------
    function playStart() public view returns (uint256) {
        return playStartedAt;
    }

    function hardEnd() public view returns (uint256) {
        return drawComplete ? playStartedAt + MAX_PLAY : 0;
    }

    /// @notice Bell, 50 minutes after draw completion, or 10 minutes after last activity.
    function endTime() public view returns (uint256 e) {
        if (!drawComplete) return 0;
        e = hardEnd();
        uint256 allDead = uint256(maxActivity) + DEATH;
        if (allDead < e) e = allDead;
        if (bellAt != 0 && bellAt < e) e = bellAt;
    }

    function ended() public view returns (bool) {
        return drawComplete && block.timestamp >= endTime();
    }

    function bellRang() public view returns (bool) {
        return bellAt != 0 && bellAt == endTime();
    }

    /// @notice 0 waiting, 1 signup, 2 play, 3 ended, 4 finalized, 5 graduated, 6 failed, 7 drawing.
    function status() external view returns (uint8) {
        if (failed) return 6;
        if (graduated) return 5;
        if (finalized) return 4;
        if (entrants.length == 0) return 0;
        if (block.timestamp < signupEnd()) return 1;
        if (!drawComplete) return 7;
        if (!ended()) return 2;
        return 3;
    }

    /// @notice Live for the king: signup started, not ended, >= 5 entries before the draw completes
    /// or >= 5 Imps afterwards. Weight is the roll-earned pot; funded ETH cannot steer the split.
    function isLiveForKing() external view returns (bool live, uint256 potSize) {
        live = entrants.length != 0 && !ended() && (drawComplete ? imps.length : entrants.length) >= 5;
        potSize = pot - fundedPot;
    }

    /// @notice ETH earned from rolls: 7%, genesis burn share, sold-out overflow and expired tips.
    function rollPot() external view returns (uint256) {
        return pot - fundedPot;
    }

    /// @notice Most funded ETH this game can pay out at its end (with >= 5 living Imps): the smaller of
    /// 3x the roll-earned pot and 15% of the curve ETH raised. Before finalization, as of now.
    function fundedReleaseCap() external view returns (uint256) {
        return _releaseCap(pot - fundedPot);
    }

    function _releaseCap(uint256 earned) internal view returns (uint256 cap) {
        cap = earned * FUNDED_RELEASE_MULTIPLE;
        uint256 curveCap = ethRaised * FUNDED_RELEASE_CURVE_BPS / 10_000;
        if (curveCap < cap) cap = curveCap;
    }

    function signupEnd() public view returns (uint256) {
        return entrants.length == 0 ? 0 : firstEntryAt + SIGNUP;
    }

    function entryCount() external view returns (uint256) {
        return entrants.length;
    }

    /// @notice Stable entry order, paginated to at most 200 records. Seat order is randomized.
    function getEntrants(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 total = entrants.length;
        if (offset >= total) return new address[](0);
        if (limit > MAX_IMPS) limit = MAX_IMPS;
        if (limit > total - offset) limit = total - offset;
        page = new address[](limit);
        for (uint256 i; i < limit; ++i) {
            page[i] = entrants[offset + i];
        }
    }

    /// @notice Both indexes are 1-based; a zero seat can mean pending or unselected (see complete).
    function myEntry() external view returns (uint256 entry, uint256 seat, bool complete) {
        return (entryOf[msg.sender], impOf[msg.sender], drawComplete);
    }

    function drawProgress()
        external
        view
        returns (uint256 entries, uint256 seated, uint256 target, uint256 commit, bool seeded, bool complete)
    {
        entries = entrants.length;
        return
            (entries, imps.length, entries < MAX_IMPS ? entries : MAX_IMPS, drawCommitBlock, drawSeeded, drawComplete);
    }

    function impCount() external view returns (uint256) {
        return imps.length;
    }

    function getImp(uint256 i) external view returns (Imp memory) {
        return imps[i];
    }

    function isAlive(uint256 i) public view returns (bool) {
        if (!drawComplete || i >= imps.length) return false;
        uint256 at = ended() ? endTime() : block.timestamp;
        return _lastActivity(imps[i]) + DEATH > at;
    }

    function rollCount() external view returns (uint256) {
        return rolls.length;
    }

    function getRoll(uint256 i) external view returns (Roll memory) {
        return rolls[i];
    }

    function curveState() external view returns (uint256 vEth, uint256 vTok, uint256 remaining) {
        vEth = VETH + ethRaised;
        vTok = VTOK - tokensSold;
        remaining = CURVE_SUPPLY - tokensSold;
    }

    function quote(uint256 ethIn) public view returns (uint256 tokensOut, uint256 ethUsed) {
        uint256 remaining = CURVE_SUPPLY - tokensSold;
        if (remaining == 0 || ethIn == 0) return (0, 0);
        uint256 vEth = VETH + ethRaised;
        uint256 vTok = VTOK - tokensSold;
        uint256 newTok = (K + vEth + ethIn - 1) / (vEth + ethIn);
        tokensOut = vTok > newTok ? vTok - newTok : 0;
        ethUsed = ethIn;
        if (tokensOut >= remaining) {
            tokensOut = remaining;
            ethUsed = K / (VTOK - CURVE_SUPPLY) - vEth;
            if (ethUsed > ethIn) ethUsed = ethIn;
        }
    }

    // ---- internals --------------------------------------------------------------------------
    function _lastActivity(Imp storage imp) internal view returns (uint256) {
        return imp.lastRoll == 0 ? playStart() : imp.lastRoll;
    }

    function _buy(uint256 ethIn) internal returns (uint256 tokensOut, uint256 ethUsed) {
        (tokensOut, ethUsed) = quote(ethIn);
        ethRaised += ethUsed;
        tokensSold += tokensOut;
    }

    function _resolve(uint256 max, address resolver) internal {
        if (max > RESOLVE_BATCH) max = RESOLVE_BATCH;
        uint256 n = rolls.length;
        uint256 done;
        while (done < max && nextPending < n && gasleft() >= RESOLVE_GAS_FLOOR) {
            ++done;
            if (rolls[nextPending].resolved) {
                nextPending += 1;
                continue;
            }
            if (!_resolveRoll(nextPending, resolver)) break;
            nextPending += 1;
        }
    }

    function _resolveRoll(uint256 id, address resolver) internal returns (bool) {
        Roll storage r = rolls[id];
        if (r.resolved) return true;
        uint256 cur = ARB.arbBlockNumber();
        uint256 commit = r.commitBlock;
        Imp storage imp = imps[r.imp];
        int256 h = imp.height;
        int256 d;
        bool expired;
        if (commit + 1 + HASH_WINDOW < cur) {
            expired = true;
            if (h > 0) d = h >= 4 ? int256(-4) : -h;
            else if (h < 0) d = h <= -4 ? int256(4) : -h;
        } else if (cur > commit + 3) {
            bytes32 h1 = ARB.arbBlockHash(commit + 1);
            bytes32 h2 = ARB.arbBlockHash(commit + 2);
            bytes32 h3 = ARB.arbBlockHash(commit + 3);
            uint256 rand = uint256(keccak256(abi.encode(address(this), uint256(r.imp), uint256(r.nonce), h1, h2, h3)));
            uint256 face = rand % 8;
            d = face < 4 ? -int256(face + 1) : int256(face - 3);
        } else {
            return false;
        }
        r.resolved = true;
        r.expired = expired;
        r.delta = int8(d);
        pendingCount -= 1;
        if (expired) pot += ROLL_TIP;
        else claimable[resolver] += ROLL_TIP;
        emit ResolverTip(id, resolver, ROLL_TIP, expired);
        if (imp.pendingRoll == id + 1) imp.pendingRoll = 0;
        int256 nh = h + d;
        if (nh > HEIGHT_CAP) nh = HEIGHT_CAP;
        if (nh < -HEIGHT_CAP) nh = -HEIGHT_CAP;
        if (nh != h) {
            imp.height = int16(nh);
            imp.heightReachedAt = uint40(commit);
            imp.heightRoll = uint32(id + 1);
        }
        emit Resolved(id, r.imp, d, nh, expired);
        bool alive = _lastActivity(imp) + DEATH > block.timestamp;
        if (alive && !expired && (nh == HEIGHT_CAP || nh == -HEIGHT_CAP) && bellAt == 0 && !ended()) {
            bellAt = uint64(block.timestamp);
            bellRinger = imp.owner;
            emit Bell(r.imp, imp.owner, nh);
        }
        return true;
    }

    function _finalize(address finalizer) internal returns (bool) {
        if (finalized || !ended() || pendingCount != 0) return false;
        uint256 end = endTime();
        uint256 n = imps.length;
        // one packed key per living Imp, sorted in memory (heap sort: O(n log n) whatever the order)
        uint256[] memory keys = new uint256[](n);
        uint256 living;
        for (uint256 i; i < n; ++i) {
            Imp storage imp = imps[i];
            if (_lastActivity(imp) + DEATH <= end) continue;
            keys[living++] = _sortKey(imp, i);
        }
        if (living > 1) _heapSort(keys, living);
        // Carry stays in the pad throughout play. Existing king funding consumes this cap first.
        if (living >= FUNDED_MIN_LIVING) {
            uint256 available = _releaseCap(pot - fundedPot);
            if (available > fundedPot) IPvPPad(pad).takeCarry(launchId, available - fundedPot);
        }
        finalized = true;
        uint256 p = pot;
        uint256 funded = fundedPot;
        uint256 earned = p - funded;
        pot = 0;
        fundedPot = 0;
        // finalizer fee: 0.5% of the pot, max 0.005 ETH, paid from roll-earned ETH only
        uint256 fee = p * FINALIZER_BPS / 10_000;
        if (fee > FINALIZER_MAX) fee = FINALIZER_MAX;
        if (fee > earned) fee = earned;
        if (finalizer == address(0)) fee = 0;
        p -= fee;
        // funded ETH is released only to a game with enough living Imps, at most 3x what rolls earned
        // and at most 15% of the curve ETH (the part a token dump cannot pull back out of the pool)
        uint256 returned;
        if (living < FUNDED_MIN_LIVING) {
            returned = funded;
        } else {
            uint256 cap = _releaseCap(earned);
            if (funded > cap) returned = funded - cap;
        }
        if (returned > p) returned = p;
        p -= returned;
        bool bell = bellAt != 0 && bellAt == end;
        uint256 paid;
        uint256 toCarry = returned;
        if (living == 0) {
            toCarry += p;
        } else {
            uint256 bellShare = bell ? p * 20 / 100 : 0;
            uint256 rankShare = p - bellShare;
            paid = (living + 1) / 2;
            uint256 weightSum = paid * (paid + 1) / 2;
            uint256 sent;
            for (uint256 r; r < paid; ++r) {
                uint256 amount = rankShare * (paid - r) / weightSum;
                sent += amount;
                _pay(imps[_keyIndex(keys[living - 1 - r])].owner, amount);
            }
            if (bellShare != 0) _pay(bellRinger, bellShare);
            toCarry += rankShare - sent;
        }
        livingAtEnd = uint32(living);
        paidAtEnd = uint32(paid);
        if (fee != 0) _pay(finalizer, fee);
        if (returned != 0) emit FundedReturned(returned);
        if (toCarry != 0) IPvPPad(pad).fundCarry{value: toCarry}();
        emit Finalized(finalizer, p, living, paid, bell);
        return true;
    }

    /// @dev Higher key ranks first: |height| desc, then earlier heightReachedAt (commit block), then
    /// earlier roll, then lower Imp index. The index sits in the low 8 bits (MAX_IMPS <= 256).
    function _sortKey(Imp storage imp, uint256 index) internal view returns (uint256) {
        return (PadLib.abs(imp.height) << 80) | (uint256(type(uint40).max - imp.heightReachedAt) << 40)
            | (uint256(type(uint32).max - imp.heightRoll) << 8) | (255 - index);
    }

    function _keyIndex(uint256 key) internal pure returns (uint256) {
        return 255 - (key & 0xFF);
    }

    /// @dev In-place ascending heap sort of a[0..n).
    function _heapSort(uint256[] memory a, uint256 n) internal pure {
        for (uint256 i = n / 2; i > 0; --i) {
            _siftDown(a, i - 1, n);
        }
        for (uint256 last = n - 1; last > 0; --last) {
            (a[0], a[last]) = (a[last], a[0]);
            _siftDown(a, 0, last);
        }
    }

    function _siftDown(uint256[] memory a, uint256 root, uint256 n) internal pure {
        while (true) {
            uint256 child = 2 * root + 1;
            if (child >= n) return;
            if (child + 1 < n && a[child + 1] > a[child]) ++child;
            if (a[root] >= a[child]) return;
            (a[root], a[child]) = (a[child], a[root]);
            root = child;
        }
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        bool ok = PadLib.push(to, amount);
        if (!ok) claimable[to] += amount;
        emit Paid(to, amount, ok);
    }

    function _graduate() internal returns (bool) {
        if (!finalized || graduated) return false;
        graduated = true;
        uint256 bal = IPadToken(token).balanceOf(address(this));
        if (ethRaised == 0) {
            failed = true;
            if (bal != 0) require(IPadToken(token).transfer(DEAD, bal), "burn");
            emit Failed(bal);
            return true;
        }
        require(IPadToken(token).transfer(liquidity, bal), "token");
        IPadLiquidity(liquidity).graduate{value: ethRaised}(launchId, token, bal, VETH + ethRaised, VTOK - tokensSold);
        emit Graduated(ethRaised, bal);
        return true;
    }
}
