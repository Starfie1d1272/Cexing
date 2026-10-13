"""Bind HAP contents to the independently verified experimental build, also under -O."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

BASE = "7f731d5c9c8d4eba7a1680bcb3981d7877232bcc"
SMART_SHA = "daf3ad03021cca6031f4a7303ca6d861a14d5a16"
SYMBOLS = ["mihomoInit", "mihomoStartTun", "mihomoStop", "mihomoFree"]
ABI = ["extern char* mihomoInit(char* homeDir);",
       "extern char* mihomoStartTun(int fd, char* configJson, char* overridesJson);",
       "extern void mihomoStop(void);", "extern void mihomoFree(char* p);"]
GEOIP_SHA = "b8f447617c3f6d8ef0f7528c23dfba695bca16a31a396bc4c1fca49e9f038ae3"


def require(condition, message):
    if not condition:
        raise SystemExit("[smart-verify] " + message)


def digest(data):
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def abi(header):
    return [line.strip() for line in header.splitlines()
            if re.match(r"extern .*\bmihomo(?:Init|StartTun|Stop|Free)\(", line)]


def elf(path, readelf, symbols=()):
    data = path.read_bytes()
    require(len(data) >= 64 and data[:6] == b"\x7fELF\x02\x01",
            f"{path.name}: requires ELF64 little endian")
    require(struct.unpack_from("<H", data, 18)[0] == 183, f"{path.name}: requires AArch64")
    require(struct.unpack_from("<H", data, 16)[0] == 3, f"{path.name}: requires shared ELF")
    require(struct.unpack_from("<H", data, 56)[0] > 0, f"{path.name}: missing program headers")
    # Parse the actual ELF table, rather than finding symbol strings in its bytes.
    exports = subprocess.check_output([str(readelf), "--dyn-syms", str(path)], text=True)
    for symbol in symbols:
        require(re.search(r"FUNC\s+GLOBAL\s+DEFAULT\s+\d+\s+" + symbol + r"\b", exports),
                f"{path.name}: missing defined dynamic export {symbol}")
    return digest(data)


def stripped(source, output, strip):
    # API 26 Hvigor's strip-all output is checked independently of its packaged cache.
    subprocess.run([str(strip), "--strip-all", "-o", str(output), str(source)], check=True)
    return output.read_bytes()


def identity(root, work):
    module = json.loads((work / "upstream-module.json").read_text())
    expected = {"Path": "github.com/vernesong/mihomo",
                "Version": "v1.19.10-0.20261012020909-daf3ad03021c",
                "Sum": "h1:23XrQ5vZacJbpvuIadl9FNjak2VXIQbzwXx+xU/OtME=",
                "GoModSum": "h1:mEF7mJ1rZSghNLjOy3mLQbDjmp8nV2gTGcQT1FFsKRI="}
    require(all(module.get(key) == value for key, value in expected.items()),
            "upstream module identity differs from pinned Smart candidate")
    inputs = {name: digest((root / "experiments/smart-core" / name).read_bytes())
              for name in ["go.mod", "go.sum", "offline-model.patch"]}
    return {"host_sha": BASE, "smart_sha": SMART_SHA, "module": expected, "inputs": inputs}


def verify(root, work, hap_mode):
    entry = work / "stage/clash-openharmony/entry"
    libs = entry / "libs/arm64-v8a"
    sdk = Path(os.environ.get("HARMONYOS_CLT_ROOT", root / "command-line-tools"))
    llvm = sdk / "sdk/default/openharmony/native/llvm/bin"
    readelf, strip = llvm / "llvm-readelf", llvm / "llvm-strip"
    report = work / ("hap-verification.json" if hap_mode else "core-verification.json")
    # A failure must not leave an earlier successful report masquerading as this run.
    report.unlink(missing_ok=True)
    require(abi((libs / "libmihomo.h").read_text()) == ABI, "ABI differs from wrapper contract")
    baseline = root / "cexing/entry/libs/arm64-v8a/libmihomo.h"
    if baseline.exists():
        require(abi(baseline.read_text()) == ABI, "baseline ABI differs")
    library = elf(libs / "libmihomo.so", readelf, SYMBOLS)
    source_identity = identity(root, work)
    build_info = subprocess.check_output(["go", "version", "-m", str(libs / "libmihomo.so")], text=True)
    require(f"\t=>\t{work / 'upstream'}\t(devel)" in build_info,
            "core binary does not identify the experimental Smart source replacement")
    for setting in ["-buildmode=c-shared", "-tags=netgo,ohos,cmfa,with_gvisor",
                    "CGO_ENABLED=1", "GOARCH=arm64", "GOOS=android"]:
        require("\tbuild\t" + setting + "\n" in build_info, f"core build setting missing: {setting}")
    result = {"identity": source_identity, "library": library, "abi": ABI}
    with tempfile.TemporaryDirectory(prefix="smart-verify-", dir=work) as temporary:
        temporary = Path(temporary)
        core_bytes = stripped(libs / "libmihomo.so", temporary / "libmihomo.so", strip)
        result["stripped_library"] = elf(temporary / "libmihomo.so", readelf, SYMBOLS)
        if hap_mode:
            recorded = json.loads((work / "core-verification.json").read_text())
            require(recorded == result, "core differs from the preceding verified build; rebuild core")
            verify_hap(root, entry, temporary, core_bytes, readelf, strip, result)
    report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


def verify_hap(root, entry, temporary, core_bytes, readelf, strip, result):
    hap = entry / "build/default/outputs/default/entry-default-unsigned.hap"
    expected = {"libs/arm64-v8a/libmihomo.so": core_bytes}
    native = entry / "build/default/intermediates/cmake/default/obj/arm64-v8a"
    for name in ["libentry.so", "libc++_shared.so"]:
        expected["libs/arm64-v8a/" + name] = stripped(native / name, temporary / name, strip)
        elf(temporary / name, readelf)
    override = "resources/rawfile/override.yaml"
    expected[override] = subprocess.check_output(
        ["git", "-C", str(root), "show", f"{BASE}:clash-openharmony/entry/src/main/{override}"])
    geoip = "resources/rawfile/geodata/geoip.metadb"
    expected[geoip] = (entry / "src/main" / geoip).read_bytes()
    require(digest(expected[geoip])["sha256"] == GEOIP_SHA, "staged GeoIP digest differs from pinned snapshot")
    result["hap_entries"] = {}
    with zipfile.ZipFile(hap) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "duplicate HAP entry names")
        require(not any(PurePosixPath(name.replace("\\", "/")).name.casefold() == "model.bin"
                        for name in names), "Model.bin is prohibited in experimental HAP")
        require(archive.testzip() is None, "HAP CRC failure")
        for name, data in expected.items():
            require(bool(data), f"empty expected build resource: {name}")
            require(name in names, f"missing HAP entry: {name}")
            packaged = archive.read(name)
            require(packaged == data, f"HAP content differs from verified build: {name}")
            result["hap_entries"][name] = digest(packaged)
            if name.endswith(".so"):
                path = temporary / ("packaged-" + PurePosixPath(name).name)
                path.write_bytes(packaged)
                elf(path, readelf, SYMBOLS if name.endswith("libmihomo.so") else ())
        result["hap_library"] = result["hap_entries"]["libs/arm64-v8a/libmihomo.so"]
    result["hap"] = digest(hap.read_bytes())


if __name__ == "__main__":
    require(len(sys.argv) in (3, 4) and (len(sys.argv) == 3 or sys.argv[3] == "hap"),
            "usage: verify.py REPO WORK [hap]")
    verify(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), len(sys.argv) == 4)
