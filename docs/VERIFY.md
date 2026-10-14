# Verifying sources on robin.etherscan.io

The launch deploys the five manifest contracts from the bytecode built here. After the deployment
handoff provides addresses, verify each with the exact compiler settings from `foundry.toml`:

- Compiler: solc 0.8.26, EVM version cancun, optimizer on (200 runs), via-IR on,
  `bytecode_hash = "none"`, `cbor_metadata = false`.
- Standard JSON input is the easiest route: `forge verify-contract --show-standard-json-input`
  prints it without sending anything.

```
forge verify-contract <address> src/PadToken.sol:PadToken --chain-id 4663 \
  --verifier etherscan --verifier-url https://robin.etherscan.io/api --watch
forge verify-contract <address> src/PadGame.sol:PadGame --chain-id 4663 ...
forge verify-contract <address> src/PvPPad.sol:PvPPad --chain-id 4663 \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" \
     0x5b95a971b4583a5f011e9da082acdd679b870d06 <PadToken> <PadGame>) ...
forge verify-contract <address> src/PadLiquidity.sol:PadLiquidity --chain-id 4663 \
  --constructor-args $(cast abi-encode "constructor(address,address)" \
     0x8366a39cc670b4001a1121b8f6a443a643e40951 <PvPPad>) ...
forge verify-contract <address> src/KingOfThePad.sol:KingOfThePad --chain-id 4663 \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" \
     <PvPPad> <PadLiquidity> 0x5b95a971b4583a5f011e9da082acdd679b870d06) ...
```

`PadHook` is deployed later by `openPad(salt)`; verify it at `PvPPad.hook()` with constructor args
`(poolManager, padLiquidity)`. Clones (tokens and games) are EIP-1167 proxies: the explorer shows
them as proxies of `PadToken` / `PadGame` once the templates are verified.

Verification is the deployer's step; this repository never broadcasts or calls RPCs.

Source of truth for clones: anyone can deploy their own EIP-1167 proxy to the verified templates and
initialize a look-alike token or game with the genesis name and symbol (AUDIT #27). Only
`PvPPad.tokenOf(id)`, `PvPPad.gameOf(id)` and `PvPPad.isGame(address)` identify the pad's launches;
a site or explorer label must resolve clones through the pad, never through the implementation
address or the token name.

V3 verification checks
----------------------

Run `forge build`, `forge fmt --check` and `python3 tools/validate_manifest.py` locally before handing
off artifacts. The validator checks the exact original deployment order and constructor arguments,
static lowercase addresses, compiler pin, metadata settings, link references, runtime/initcode sizes
and the same forbidden-opcode scan as the protected deployment floor. No application requires an
external contract to exist during its constructor. The supplied PoolManager address is inherited
from the pinned base; this job has not attested its target-chain code.

There is **no genesis token or game clone at deployment** in v3. Verify the five applications and
confirm the initial token template has zero supply and empty name/symbol. The existing `openPad(salt)`
action subsequently creates both the hook and genesis clones. Do not expect a token constructor name,
symbol or token allocation in `launch.json`. No website, deployment transaction or chain address
for this fresh launch is produced by this job.

Use [Robinhood Etherscan](https://robin.etherscan.io) to submit the standard JSON for each confirmed
application address after the authorized deployment handoff. The command examples above are for
the deployer's later verification step; they were not executed here. Retain the exact compiler
version, optimization, Cancun and metadata settings when exporting JSON. Token/game clones use the
verified templates; the PadHook constructor arguments are the inherited manager and the confirmed
PadLiquidity address. Mine the hook salt anew using the final `hookInitCodeHash()` as described in
the README; salts or addresses from the base launch are not reusable assumptions.


V3 handoff additions
-------------------

The five manifest entries and arguments are byte-for-byte inherited from the pinned v2 base.
`launch.json.notes` is consequently historical v2 prose; README and AUDIT.md describe v3 behavior.
Do not reuse the old application's deployed addresses for this fresh deployment. The owner/dev and
PoolManager arguments remain unchanged. `foundry.toml` is also unchanged (Solidity 0.8.26, Cancun,
via-IR, optimizer 200, no bytecode hash or CBOR metadata). All libraries are inlined or vendored;
none of the application artifacts has link references.

The authorized deployer must check the live manager supports `exttload(bytes32)` and the vendored
Lock slot, as well as the existing slot0 layout and v4 graduation behavior, before public opening.
The previous external audit reported a different manager build. This task did not query any chain
or claim a bytecode match for the new contracts. An independent audit and a target-chain graduation
rehearsal remain outstanding operational steps. No post-constructor configuration is required to
complete the deployment; the intentional later `openPad` action creates hook and genesis clones.
