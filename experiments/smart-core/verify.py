"""Check generated ABI and ARM64 ELF; optionally check unsigned HAP contents."""
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import zipfile

root, work = map(Path, sys.argv[1:3])
libs = work / "stage/clash-openharmony/entry/libs/arm64-v8a"
symbols = ["mihomoInit", "mihomoStartTun", "mihomoStop", "mihomoFree"]


def abi(header):
    return [line.strip() for line in header.splitlines()
            if re.match(r"extern .*\bmihomo(?:Init|StartTun|Stop|Free)\(", line)]


def elf(data):
    assert data[:6] == b"\x7fELF\x02\x01", "requires ELF64 little endian"
    assert struct.unpack_from("<H", data, 18)[0] == 183, "requires AArch64"
    assert struct.unpack_from("<H", data, 16)[0] == 3, "requires shared ELF"
    for symbol in symbols:
        assert symbol.encode() + b"\0" in data, f"missing {symbol}"
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


baseline = root / "clash-openharmony/entry/libs/arm64-v8a/libmihomo.h"
header = libs / "libmihomo.h"
sdk = Path(__import__("os").environ.get("HARMONYOS_CLT_ROOT", root / "command-line-tools"))
readelf = sdk / "sdk/default/openharmony/native/llvm/bin/llvm-readelf"
exports = subprocess.check_output([str(readelf), "--dyn-syms", str(libs / "libmihomo.so")], text=True)
for symbol in symbols:
    assert re.search(r"GLOBAL\s+DEFAULT\s+\d+\s+" + symbol + r"\b", exports), f"missing exported {symbol}"
expected = ["extern char* mihomoInit(char* homeDir);",
            "extern char* mihomoStartTun(int fd, char* configJson, char* overridesJson);",
            "extern void mihomoStop(void);", "extern void mihomoFree(char* p);"]
assert abi(header.read_text()) == expected, "ABI differs from wrapper contract"
if baseline.exists():
    assert abi(baseline.read_text()) == expected, "baseline ABI differs"
result = {"library": elf((libs / "libmihomo.so").read_bytes()), "abi": expected}
if len(sys.argv) > 3:
    hap = work / "stage/clash-openharmony/entry/build/default/outputs/default/entry-default-unsigned.hap"
    with zipfile.ZipFile(hap) as archive:
        assert archive.testzip() is None, "HAP CRC failure"
        required = ["libs/arm64-v8a/libmihomo.so", "libs/arm64-v8a/libentry.so",
                    "libs/arm64-v8a/libc++_shared.so", "resources/rawfile/override.yaml",
                    "resources/rawfile/geodata/geoip.metadb"]
        for name in required:
            assert name in archive.namelist(), f"missing {name}"
        assert not any(Path(name).name.lower() == "model.bin" for name in archive.namelist())
        result["hap_library"] = elf(archive.read(required[0]))
    result["hap"] = {"bytes": hap.stat().st_size,
                     "sha256": hashlib.sha256(hap.read_bytes()).hexdigest()}
print(json.dumps(result, indent=2))
(work / ("hap-verification.json" if len(sys.argv) > 3 else "core-verification.json")).write_text(json.dumps(result, indent=2) + "\n")
