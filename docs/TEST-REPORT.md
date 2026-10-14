# PvP Pad v3 test report

Local offline verification on 2026-10-14, Foundry 1.8.3, Solidity 0.8.26, Cancun, via-IR,
optimizer 200, `bytecode_hash = "none"`, `cbor_metadata = false`.

## Reproduction

```sh
forge build
FOUNDRY_FUZZ_SEED=0x1e572fb3fcde0b288122efe0d6a70e987a222567a2ac5cd3bc7883ffbf299030 forge test -vv --threads 4
forge fmt --check
python3 tools/validate_manifest.py
```

**181 tests passed, zero failed, zero skipped, across 15 suites** (including one aggregate
covering twelve invariant properties). `forge build`, `forge fmt --check` and the offline manifest
validator also pass. Tests have no environment reads,
RPC, forks, broadcasts, FFI, filesystem permissions or unvendored dependencies. The explicit fuzz
seed above overrides the base seed retained in the unchanged foundry.toml. Compiler heuristic lint
warnings about casts, timestamps and guarded external calls remain; build success does not mean
warning-free static analysis or an independent audit.

## Suite coverage

| Suite | Tests | Evidence |
|---|---:|---|
| AtomicDeployment | 1 | Five raw artifacts CREATE2-deployed atomically; constructor args, no external manager code, no initial token supply, runtime/initcode bounds, later opening gas |
| Pad | 21 | Ownership, binders, sealed templates, empty initial deployment, open/salt/30-day gates, launch metadata, recovery, hook access |
| Game | 35 | Roll prerequisites, curve, timing, expiry and bell, ranking, claims, funded limits, real graduation, 200-player finalization |
| King | 14 | Bid/hold/refund/split rules, live-game weighting, in-kind fees, fees remain in positions without king, burn cap, partial fills and sandwich regression |
| Adversarial | 36 | Reentrancy, RNG boundaries, curve sell-out, rank ties, 200-player settlement, restart paths, funding windows, multiple real pools |
| Fuzz | 9 | Curve arithmetic, roll/tip/burn conservation, king arithmetic, ranks and funded release |
| Invariants | 1 aggregate / 12 properties | Exact ETH obligations including bounty/pending tips/claims, total ETH, token supply, lifecycle and registry rules |
| Raffle | 15 | Exact fees, bounty routing, entry/seat uniqueness, callback reentrancy, 5,000 entries, bounded draw gas, chunk independence, fallback boundary and statistical selection |
| LiquidityV4 | 9 | Real sold-out and minimal-raise graduation, dirty currency sync, actual trading fees in kind, healthy/broken pools (retry pays the reign's king), strict failures, all 18 pools before crown |
| CrownSettlement | 7 | Revision finding 8b022036: cursor steering before a bid on 18 real pools, 60 real pools with a minimum-gas and a generous bid, 16-pool floor revert, non-king settlement, first-crown reign, broken pool skipped by two crowns paid to the earliest reign |
| RaffleEdges | 6 | Signup/play/death/end boundaries, unselected wallets, late entries, king signup funding, five-seat draw never takes carry |
| Revision | 9 | Original claim-reentry proof, strict distributor failure, separate claim lock, 15% sybil loss proof, free launches, registered-game pulls, event indexes, TickMath |
| AuditV3King | 7 | Real unlock callback bid/distribute rejection, first-crown check, gas-starved bid/probe, distinct-block failures and recovery, atomic rollback, large token fees, 16 pools with gas-exhausting king |
| AuditV3Game | 5 | 60-second roller with a 10-block/s resolver; direct/upkeep beneficiary; exact 90/7/2/1 accounting; expiry penalty/tip routing; bounded resolution; deterministic fallback and bounty once |
| AuditV3CarryUpkeep | 6 | Three linked five-wallet games, no-roll carry chain, own-action gas estimates with foreign draw/finalize/graduate, a foreign step exhausting its entire stipend |

The eleven fuzz properties run **3,380 cases**: 3,292 in Fuzz, 64 in Raffle, 24 in RaffleEdges.
The invariant campaign executes 40 sequences of 60 actions (2,400 calls), checking all twelve
properties. The statistical raffle regression samples 256 different mocked future-hash triples
with 400 entrants (51,200 seats). This checks positional regressions, not sequencer entropy.

## Gas measurements

| Operation | Local gas |
|---|---:|
| Atomic raw-CREATE2 deployment, including calldata and intrinsic | 12,188,501 |
| Later openPad, including hook and genesis clones | 786,290 |
| Combined deployment and later opening | **12,974,791** |
| Crown transition: 18 real pools, all 18 before crown and 2 empty upkeep collections after | 2,730,025 |
| Crown transition: 16 real pools, both currencies, outgoing king exhausts every ETH push | **4,698,427** |
| Crown transition: 60 real pools fully settled before the crown (12M call gas limit) | 7,545,395 |
| Crown transition: 60 real pools, minimum-gas bid (5.8M call gas limit): pools settled before the crown | 41 of 60; the other 19 paid to the outgoing king by later public collection |
| Finalize 200 living Imps, reverse ranking, EOA recipients | 3,802,560 |
| Largest 32-seat draw chunk at 5,000 entries, cold game | 2,655,494 |
| Seven draw chunks selecting 200 seats, including seed capture | 16,172,036 |
| Entry with pending foreign draw/finalize/graduate, locally estimated call gas limit | 185,039 |
| Roll with pending foreign draw, locally estimated call gas limit | 178,613 |
| Roll with pending foreign finalize/graduate, locally estimated call gas limit | 183,203 |

The minimum settlement stipend is 5M and `takeCrown` forwards everything above its 600k reserve;
each collection gets 300k and the walk stops when less than 400k remains, reverting the bid only if
fewer than 16 pools were visited. Pools the walk does not reach keep their reign stamp and are paid
to the outgoing king by whoever collects them next. The worst-case recipient test requires the
actual bid to succeed with a 6M call gas limit, records the consumed gas (below the 5M minimum
stipend), and checks both ETH claimables and every token payment. The first 250k trial was insufficient for
cold fee accounting, both currencies and a recipient consuming its whole push; the final 300k
stipend passes. This is a local real-v4 measurement, not a claim about an untested manager build.

The own-action gas test uses snapshot/replay to find a successful call limit below 500k, adds 10k
estimator headroom, and then executes real entry and roll while another game needs each of the
three expensive lifecycle steps. It verifies the user's state changes and the foreign work remains
pending. A separate gas-eating game callback proves that an executed stipend may be fully consumed
without reverting entry. These figures are EVM call gas; transaction intrinsic/data costs are extra.

Large test fixtures may pause gas metering; it is resumed before measured operations, gas estimates
and gas-eating recipient callbacks. Draw selection totals span multiple calls. Raw deployment uses
`vm.getCode` plus assembly CREATE2 rather than Solidity `new`, avoiding Foundry's dynamic-linking
code-deposit shortcuts. It checks the 13M target including later opening and the 16,777,216 deployment
ceiling. Factory-specific attestation/wrapper overhead is outside this rehearsal; the authorized
launch pipeline must enforce the actual transaction ceiling.

## Artifact and provenance checks

| Application | Initcode bytes before constructor arguments | Runtime bytes |
|---|---:|---:|
| PadToken | 3,255 | 3,210 |
| PadGame | 18,706 | 18,665 |
| PvPPad | 12,198 | 11,790 |
| PadLiquidity | 14,251 | 13,808 |
| KingOfThePad | 3,648 | 3,138 |

Total application runtime: **50,611 bytes**, **10,122,200** gas in code deposits. Each runtime is
below 24,576 bytes; each initcode plus static arguments is below 49,152 bytes. No link references,
forbidden application escape opcodes, deployment token mint, external constructor calls, dynamic
constructor arguments or post-constructor setup are introduced.

All **85 vendored files** were compared byte-for-byte with the pinned base archive. The real
Uniswap v4.0.0 PoolManager is unmodified; success tests use actual swaps, donation fees, liquidity,
fee growth, unlock callbacks and settlement. Pool-failure tests explicitly inject a revert with
`vm.mockCallRevert`. Some ranking/expensive-lifecycle fixtures set game storage to a bell or rank;
none substitutes manager math or storage for successful graduation/collection. MockArbSys models
the L2 clock and 256-block hash validity, including the requested 10-block/s scenario.

The inherited config and manifest were compared byte-for-byte against the exact base commit:

- foundry.toml SHA-256: `7f894c78a476218520231ce2d621bd70a5c827fb3232ade4375319df0b6968d9`
- launch.json SHA-256: `23fa6dfd13dd1b4d8b5db12f306ebdf286deca50afad3bc63b0984a8f181a376`

## Limits and pre-opening work

These checks do not attest target-chain deployed bytecode, sequencer fairness or censorship
resistance. The prior external report noted that the live manager differs from the vendored build.
The deployer must check the actual manager and rehearse graduation before opening, outside this
no-RPC assignment. Independent audit and legal review remain required before public launch.
Slither/Mythril and an independent contributor review were not performed here. See AUDIT.md for
reign-stamped crown coverage, diagnosed broken-pool exceptions, predictable seed fallback and
resolver availability assumptions.
