# PvP Pad v3

Contracts-only launchpad on Robinhood Chain (4663): every launch is a fast Spireth game and all
payments are in ETH. This is a **fresh deployment** of the pinned v2 base
`identity-md-launches/launch-1715-pvp-pad-v2-robinhood@cf4835d5388d5025c282a3cc59426fd730eaf88f`,
with the six requested fixes to external audit job `5c4ec689-085b-4d72-8807-668b284d3222`.
No website is included.

**An independent audit is required before public launch.** These tests and the builder's review
are not an independent security audit. Retain the base's legal review before operating a game of
chance, token issuance and ETH auction. See [AUDIT.md](docs/AUDIT.md) for each fix, its regression
proof, trust assumptions and remaining risks.

## Deployment and ownership

Deployment creates **no token supply, token name/symbol, game clone, hook, pool or distributor**.
The two sealed templates cannot be initialized directly. The pad itself creates every token later,
including genesis PVP when the owner opens the pad. The manifest contains five applications:

| Order | Contract | Constructor arguments |
|---|---|---|
| 1 | `PadToken` | none |
| 2 | `PadGame` | none |
| 3 | `PvPPad` | `$owner`, `$contract:PadToken`, `$contract:PadGame` |
| 4 | `PadLiquidity` | `0x8366a39cc670b4001a1121b8f6a443a643e40951`, `$contract:PvPPad` |
| 5 | `KingOfThePad` | `$contract:PvPPad`, `$contract:PadLiquidity`, `0x5b95a971b4583a5f011e9da082acdd679b870d06` |

Owner and dev are `0x5b95a971b4583a5f011e9da082acdd679b870d06`. Neither the factory nor IMD owns an
application. The owner can open before day 30 and receives 25% of crown extras; there is no pause,
upgrade, sweep, fee setter or privileged token mint. Anyone can open after day 30.

All five applications **must deploy in one transaction**, consuming the inherited one-shot binders
without an intervening transaction. Constructors are nonpayable, take only static arguments, and
call only earlier manifest contracts. They never call ArbSys or the PoolManager or require external
code. Nothing needs to be called after deployment to configure the applications. No deployment,
broadcast or RPC was performed here. The later `openPad` remains the intended public-opening action.

`launch.json` and `foundry.toml` are preserved byte-for-byte from the base. The manifest's notes
contain historical v2 descriptions; this README and AUDIT.md describe v3 behavior. All argument
values remain strings, addresses lowercase, and backward contract references unchanged. All
libraries/dependencies are ordinary files under `lib/`; there are no submodules or network installs.
The offline validator checks schema, exact constructor arguments, metadata, linking, runtime/initcode
sizes and forbidden application opcodes. The deployment ceiling is 16,777,216 gas; the stricter local
13M target includes a raw-CREATE2 deployment, calldata/intrinsic gas and later `openPad`.
See [TEST-REPORT.md](docs/TEST-REPORT.md) for actual measurements and factory-overhead limitations.

## After deployment: operational responsibilities

1. Obtain the independent audit and legal review before opening. The deployer must separately check
   the intended live PoolManager, `exttload`/Lock slot, slot0 layout and a graduation rehearsal on the
   target chain. The inherited manager address was not queried here; real-core local tests do not
   attest a different live implementation.
2. Mine a hook salt locally against the **final** PadLiquidity address and `hookInitCodeHash()`.
   CREATE2 is from PadLiquidity, and the resulting address must satisfy `address & 0x3fff == 0x2000`.
   About 1 in 16,384 salts match. `hookAddressFor(salt)` predicts the address; `mineSalt()` in
   `test/Base.t.sol` is the local reference. PadHook is deliberately absent from the manifest.
3. The owner calls `openPad(salt)` once, or anyone can after 30 days. It creates the hook and launch
   #1, “Pepes Value Pepes” / PVP. First paid entry starts its signup. If genesis ends with no roll,
   permissionless `restartGenesis()` (or `launch(...)`) creates a replacement. Other launches and
   crown bids wait for a successful genesis graduation.
4. Run permissionless resolvers and monitor draw commits. At ~10 L2 blocks/s the 256-block hash
   window is about 26 seconds, **shorter than the 60-second roll cooldown**. Resolve from commit+4,
   preferably within a few seconds, without waiting for the player to roll again. Watch pending
   queues, unfinished draws/finalizations/graduations, pool health and claimable balances. The 1%
   reward is an incentive, not a guarantee that a resolver is available.
5. Collect fees regularly and diagnose failures with `distribute(n)` or `retryPool(index)`. A bid
   that fails settlement rolls back its counters too. Three failed, fully funded attempts in
   distinct **ArbSys L2 blocks** mark a pool broken. Retry it after recovery; anyone can do so.
   Individual pools and large backlogs can require direct calls rather than opportunistic upkeep.

There are no oracle subscriptions, secret keys, backend signers, additional settings or operator
roles to configure in these contracts. Explorer verification is the deployer's later step:
[VERIFY.md](docs/VERIFY.md), for robin.etherscan.io.

## Game and raffle

- Anyone can `launch(name,ticker,imageURL)` after genesis graduates. Limits remain 32/10/200 bytes;
  name and ticker are nonempty. Each launch creates an EIP-1167 token and game clone, 1 billion
  tokens at 18 decimals. Transfers stay locked until graduation except transfers by the game or
  liquidity contract. Names and template addresses do not prove a clone belongs to the pad:
  use `tokenOf(id)`, `gameOf(id)` and `isGame(address)`.
- Entry costs exactly **0.001 ETH**, one per wallet, with no entry cap or EOA restriction. It is
  nonrefundable whether seated or not. First entry starts ten minutes of signup and stays in the
  game as `drawBounty`; every subsequent entry fee goes to the PVP burn bucket.
- The first post-signup draw call commits its ArbSys L2 block once. At commit+4 through commit+257
  the seed is `keccak256(abi.encode(game, hash(commit+1), hash(commit+2), hash(commit+3)))`. If nobody
  captures it before expiry, the seed is `keccak256(abi.encode(game, commitBlock, entryCount))`.
  **There is no recommit.** The caller that captures either seed earns the first entry fee once,
  by capped ETH push or claimable fallback. Upkeep forwards the actual user as bounty beneficiary.
- `draw(n)` performs up to 32 sparse Fisher-Yates trials with rejection sampling and seats at most
  200 distinct wallets. All wallets play when entries <=200; otherwise seat selection is random
  under the hash assumptions. Chunking, caller and capture delay do not change an already captured
  seed. Play starts only when all seats are drawn; seats are Imp records, not NFTs.
- This is not VRF randomness. Sequencer influence/censorship remains. The deterministic fallback
  prevents unlimited fresh-seed fishing but is predictable; a sole keeper still has the choice of
  timely capture versus the one fixed fallback. Independent prompt capture is desirable. Multiple
  wallets remain possible; the first entrant can recover its own fee by capturing the seed, so a
  solo failed-genesis round no longer necessarily burns that wallet's entry fee.
- Rolls cost **0.002 ETH**, with a **60-second cooldown**. The split is **90% curve, 7% pot,
  2% PVP burn, 1% resolver tip**. Genesis sends its 2% burn share to its own pot. The virtual curve
  starts with 1 ETH/1 billion tokens and sells 800 million tokens; sell-out requires 4 ETH on the
  curve. Unused curve share after sell-out goes to the pot; the tip remains separate.
- Each roll commits its L2 block. Three future hashes plus game/Imp/nonce determine -4..-1 or
  +1..+4, clamped to ±50. Anyone can `resolvePending(max)`, at most 16 records per call, with a
  gas floor; successful timely resolution credits **0.00002 ETH** to that resolver's game
  `claimable`. `claim()` withdraws tips, including after graduation. A roll past commit+257 instead
  moves height up to four toward zero, sends its tip to the pot, and pays no resolver. The expiry
  penalty is retained to discourage withholding. Calls are idempotent and cannot double-pay.
- Death is ten minutes since last roll, or play start if none. A bell at ±50, all dead, or fifty
  minutes after play starts ends the game. Living Imps rank by absolute height, earlier committing
  L2 block, earlier roll index, then lower randomized seat index. The top ceil(living/2) split the
  ranked pot with triangular weights. Bell ringer receives 20%; without a bell all goes to ranks.
  With none living, the distributable pot carries forward. Finalizer receives 0.5%, max 0.005 ETH,
  capped by roll-earned ETH. Rejected ETH pushes are claimable; rounding dust goes to carry.

## Carry, liquidity and crown

`fundCarry()` is **permissionless**. Carry remains in PvPPad throughout signup, drawing and play.
At finalization, with at least five living Imps, a game pulls only its unused funded allowance:
`max(0, min(3 * rollPot, 15% * ethRaised) - fundedPot)`, limited by available carry. Existing king
funding uses the cap first. Excess existing funding returns to carry. Completing another game's
draw inside the same transaction cannot capture the remainder. Donations never increase the cap.

Permissionless graduation moves raised ETH and remaining tokens into a native-ETH/token Uniswap
v4 pool: fee 10000 (1%), tick spacing 200, full-range ticks ±887200, PadHook, price from the final
curve. PadLiquidity owns LP forever with no withdrawal path. The inherited full-range math, 1 ppm
liquidity haircut, native sync-before-settle fix and token excess burn are retained. A game with no
raised ETH burns its supply and fails; zero-roll genesis can then be restarted.

Crown auction opens after genesis graduates: first bid >=0.01 ETH; subsequent bids >=110% after
one hour. The outgoing bid is refunded in full by push/claimable. The extra (the whole first bid)
splits 50% games, 25% burn, 25% dev. Games share follows v2: last ten **entered** launches with five
entries during signup/draw or five seats after draw, weighted by roll-earned pot (equal if all zero).
No eligible game means carry. Free launches never displace entered games from this window.

Before changing an existing king, the pre-crown settlement walks **every pool** from the public
cursor while the bid's gas still fits another collection (300k per self-call plus a 100k reserve),
and must reach at least **16 pools** or the bid reverts. A bid requires at least the 5M minimum
stipend plus EIP-150 margin and a 600k reserve; everything above the reserve is forwarded, so a bid
sent with more gas settles more pools (the minimum fits about 40 real pools locally; 60 pools need
about 7.6M). `takeCrown` and `distribute` reject an already-unlocked PoolManager via the vendored
Lock transient slot read through `exttload`. Any failure in an unflagged pool aborts the bid.
Permissionless normal collection records failures instead; after three failures in distinct L2
blocks a pool is skipped as broken until a successful `retryPool` clears its flag. A gas-starved
probe cannot mark it broken.

Collected **ETH and tokens are paid in kind** to the king each pool is owed to. ETH has a 30k push
cap and claimable fallback; tokens use plain transfer. There is no fee sale, token stash,
`SELL_CHUNK` or king escrow. Before the first crown, collection does nothing and fees accrue in LP
positions; the first king collects them. Each settlement closes a **reign**: PadLiquidity records
the outgoing king as `reignKing[reign]` and bumps `reign`; every pool stores the reign it is
settled for. A pool the walk did not reach (gas ran out after the 16-pool floor, or the pool was
flagged broken) keeps the old reign stamp, and its next collection, by anyone, pays that reign's
king rather than the new one. So nothing earned under a reign can be collected by the next king,
whatever the pool count or the public cursor position. The one imprecision runs the other way: fees
such a pool earns between the crown change and its next collection also go to the earlier king,
which the new king avoids by collecting promptly (or by sending the bid with enough gas).

Burn-bucket buys still use at most 0.02 ETH per ten minutes, pay PVP directly to `0x…dEaD`, and stop
at a 0.5% sqrt-price move (about 1% in price). Unspent ETH stays in the bucket. This bounds each buy's
impact but is not a guarantee against MEV or manipulation.

## Gas bounds and public work

| Work | Limit |
|---|---|
| Draw | 32 trials, at most 200 seats |
| Roll resolution | 16 examined records, including already resolved records; 200k gas floor |
| Crown settlement | every pool while gas fits, at least 16; 300k each + 100k reserve; 5M minimum stipend, all surplus forwarded; 600k outer reserve + EIP-150 margin |
| Public distribute(n) | at most 16 pools per call; unreached or broken pools pay the reign's recorded king |
| Collection health probe | Whole 300k stipend + 100k reserve required |
| Pad game upkeep step | 4.5M per call; latest entered game plus one older round-robin game |
| Pad distribute(2) / burnChunk | 750k / 350k |
| Pad reserve | 100k plus cap/63 before each subcall; return immediately below 150k |
| ETH pushes | 30k; rejected push becomes claimable |
| King funding window | Last 10 entered games; eligibility threshold 5 |
| Funded release | >=5 living; min(3x roll pot, 15% curve ETH); unused allowance only for carry |

Entry, roll, launch, crown and game lifecycle calls run best-effort upkeep. Subcalls get explicit
caps and run only with sufficient gas left; other games' draw/finalize/graduate work can be skipped
without reverting the user's action. Direct `draw`, `resolvePending`, `finalize`, `graduate`,
`distribute`, `retryPool`, `burnChunk`, game `poke` and pad `upkeep` remain public. Large queues may
need repeated calls; fee payouts alone do not guarantee operators will find work profitable.

Game views retain `entryCount`, `entryOf`, paginated `getEntrants` (max 200), `impOf`, `myEntry`,
`drawProgress`, `drawSeed`, `drawNonce`, `drawCommitted`, `drawSeeded`, `drawComplete`, and separate
signup/play/end clocks. Entry and seat event indexes are 1-based, matching getters. Status codes:
0 waiting, 1 signup, 2 play, 3 ended, 4 finalized, 5 graduated, 6 failed, 7 drawing. New events expose
resolver tips, seed bounties and pool health. Timers use timestamps; randomness and distinct failure
blocks use ArbSys L2 numbers. No L1 blockhash, block number, or prevrandao drives game outcomes.

## Offline build and checks

```sh
forge build
FOUNDRY_FUZZ_SEED=0x1e572fb3fcde0b288122efe0d6a70e987a222567a2ac5cd3bc7883ffbf299030 forge test
forge fmt --check
python3 tools/validate_manifest.py
```

Compiler: Solidity **0.8.26**, Cancun, via-IR, optimizer 200, `bytecode_hash = "none"`,
`cbor_metadata = false`. FFI and filesystem permissions are disabled. foundry.toml retains its base
fuzz seed; the command above also exercises this assignment's explicit seed. Tests read no
configuration/environment variables and need no network. The real v4.0.0 PoolManager and its
required Solmate dependency are vendored; versions and licenses are in `lib/DEPENDENCIES.md`.
MockArbSys models hash-window boundaries offline, including the requested ten L2 blocks per second.

Further records: [test report](docs/TEST-REPORT.md), [current audit](docs/AUDIT.md),
[original v2 review](docs/AUDIT-V2-HISTORY.md), [verification handoff](docs/VERIFY.md).
