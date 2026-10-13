"""Tamper real-build HAP fixtures and check gates in normal and optimized Python."""
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
WORK = HERE / ".work"
ENTRY = WORK / "stage/clash-openharmony/entry"
HAP_PATH = Path("build/default/outputs/default/entry-default-unsigned.hap")
NAMES = ["libs/arm64-v8a/libmihomo.so", "libs/arm64-v8a/libentry.so",
         "libs/arm64-v8a/libc++_shared.so", "resources/rawfile/override.yaml",
         "resources/rawfile/geodata/geoip.metadb"]


def load_verifier():
    spec = importlib.util.spec_from_file_location("smart_verify", HERE / "verify.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def child(case):
    gate = load_verifier()
    llvm = Path(os.environ.get("HARMONYOS_CLT_ROOT", ROOT / "command-line-tools")) / "sdk/default/openharmony/native/llvm/bin"
    with tempfile.TemporaryDirectory(prefix="gate-test-", dir=WORK) as directory:
        temporary = Path(directory)
        entry = temporary / "entry"
        (entry / HAP_PATH).parent.mkdir(parents=True)
        for name in ["src", "build/default/intermediates"]:
            dest = entry / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.symlink_to(ENTRY / name, target_is_directory=True)
        with zipfile.ZipFile(ENTRY / HAP_PATH) as archive:
            entries = {name: archive.read(name) for name in NAMES}
        core = gate.stripped(ENTRY / NAMES[0], temporary / "expected-core.so", llvm / "llvm-strip")
        if case == "fake112":
            fake = bytearray(112)
            fake[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", fake, 16, 3)
            struct.pack_into("<H", fake, 18, 183)
            text = b"mihomoInit\0mihomoStartTun\0mihomoStop\0mihomoFree\0"
            fake[64:64 + len(text)] = text
            entries[NAMES[0]] = bytes(fake)
        elif case.startswith("empty:"):
            entries[NAMES[int(case.split(":")[1])]] = b""
        elif case == "model":
            entries["resources/rawfile/Model.bin"] = b"synthetic prohibited model"
        elif case == "stale-core":
            with zipfile.ZipFile(ROOT / "cexing/entry" / HAP_PATH) as archive:
                entries[NAMES[0]] = archive.read(NAMES[0])
        elif case == "unstripped-core":
            entries[NAMES[0]] = (ENTRY / NAMES[0]).read_bytes()
        elif case == "missing-export":
            path = temporary / "missing-export.so"
            changed = core.replace(b"mihomoFree\0", b"mihomoGone\0")
            if changed == core:
                raise SystemExit("test fixture did not alter export")
            path.write_bytes(changed)
            gate.elf(path, llvm / "llvm-readelf", gate.SYMBOLS)
            return
        elif case != "valid":
            raise SystemExit("unknown test case")
        with zipfile.ZipFile(entry / HAP_PATH, "w") as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        result = {}
        gate.verify_hap(ROOT, entry, temporary, core, llvm / "llvm-readelf", llvm / "llvm-strip", result)
        if case == "valid" and result["hap_library"] != json.loads((WORK / "core-verification.json").read_text())["stripped_library"]:
            raise SystemExit("positive fixture differs from recorded core")


def parent():
    cases = {"valid": None, "fake112": "HAP content differs",
             "unstripped-core": "HAP content differs", "model": "Model.bin is prohibited",
             "missing-export": "missing defined dynamic export mihomoFree"}
    if (ROOT / "cexing/entry" / HAP_PATH).exists():
        cases["stale-core"] = "HAP content differs"
    for index in range(1, 5):
        cases[f"empty:{index}"] = "HAP content differs"
    for optimize in ["0", "1"]:
        for case, error in cases.items():
            process = subprocess.run([sys.executable, str(Path(__file__).resolve()), case],
                                     env={**os.environ, "PYTHONOPTIMIZE": optimize},
                                     capture_output=True, text=True)
            valid = process.returncode == 0 if error is None else process.returncode != 0 and error in process.stderr
            if not valid:
                raise SystemExit(f"FAIL optimize={optimize} {case}: {process.stdout} {process.stderr}")
            print(f"PASS optimize={optimize} {case}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) == 1:
        parent()
    else:
        child(sys.argv[1])
