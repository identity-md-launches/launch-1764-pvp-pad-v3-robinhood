#!/usr/bin/env python3
"""Offline validation of this launch's manifest, compiler settings and built app artifacts."""
import json
from pathlib import Path
import re
import tomllib

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "launch.json").read_text())
assert set(manifest) == {"kind", "contracts", "notes"}
assert manifest["kind"] == "evm_contracts"
expected = [
    ("PadToken", []),
    ("PadGame", []),
    ("PvPPad", ["$owner", "$contract:PadToken", "$contract:PadGame"]),
    ("PadLiquidity", ["0x8366a39cc670b4001a1121b8f6a443a643e40951", "$contract:PvPPad"]),
    ("KingOfThePad", ["$contract:PvPPad", "$contract:PadLiquidity", "0x5b95a971b4583a5f011e9da082acdd679b870d06"]),
]
assert len(manifest["contracts"]) == len(expected)
seen = set()
total_runtime = 0
for item, (name, args) in zip(manifest["contracts"], expected):
    assert set(item) == {"contract", "constructorArgs"}
    assert item == {"contract": name, "constructorArgs": args}
    assert re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]{0,31}", name)
    assert len(args) <= 16
    for arg in args:
        assert isinstance(arg, str)
        if arg.startswith("$contract:"):
            assert arg.split(":", 1)[1] in seen
        elif arg != "$owner":
            assert re.fullmatch(r"0x[0-9a-f]{40}", arg)
    seen.add(name)
    artifact = json.loads((root / "out" / (name + ".sol") / (name + ".json")).read_text())
    constructors = [e for e in artifact["abi"] if e["type"] == "constructor"]
    assert len(constructors) == 1
    assert constructors[0]["stateMutability"] == "nonpayable"
    assert [e["type"] for e in constructors[0]["inputs"]] == ["address"] * len(args)
    creation = bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))
    runtime = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    assert 0 < len(creation) + 32 * len(args) <= 49_152
    assert 0 < len(runtime) <= 24_576
    assert not artifact["bytecode"].get("linkReferences", {})
    assert not artifact["deployedBytecode"].get("linkReferences", {})
    pc = 0
    while pc < len(runtime):
        op = runtime[pc]
        assert op not in (0xF2, 0xF4, 0xFF), f"{name}: forbidden opcode {op:x} at {pc}"
        pc += 1 + (op - 0x5F if 0x60 <= op <= 0x7F else 0)
    total_runtime += len(runtime)
    print(f"{name}: init {len(creation):,}, runtime {len(runtime):,} bytes")
cfg = tomllib.loads((root / "foundry.toml").read_text())["profile"]["default"]
assert cfg["solc"] == "0.8.26"
assert cfg["bytecode_hash"] == "none" and cfg["cbor_metadata"] is False
assert cfg["ffi"] is False and cfg["fs_permissions"] == []
assert cfg["evm_version"] == "cancun"
assert cfg["optimizer"] is True and cfg["optimizer_runs"] == 200 and cfg["via_ir"] is True
print(f"Manifest valid; total application runtime {total_runtime:,} bytes, code-deposit gas {200 * total_runtime:,}.")
