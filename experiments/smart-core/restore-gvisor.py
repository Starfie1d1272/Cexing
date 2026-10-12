"""Restore only the exact supported Fstat cache patch before go mod verify."""
import json
from pathlib import Path
import subprocess
import zipfile

module = json.loads(subprocess.check_output(
    ["go", "mod", "download", "-json", "github.com/metacubex/gvisor"]))
relative = "pkg/tcpip/link/fdbased/endpoint.go"
endpoint = Path(module["Dir"]) / relative
with zipfile.ZipFile(module["Zip"]) as archive:
    original = archive.read(f'{module["Path"]}@{module["Version"]}/{relative}')
old = b'\t\treturn false, fmt.Errorf("unix.Fstat(%v,...) failed: %v", fd, err)\n'
new = b'\t\treturn false, nil // OHOS: VPN tun fd is not Fstat-able (musl/SELinux); treat as non-socket\n'
assert original.count(old) == 1, "gVisor baseline drift"
current = endpoint.read_bytes()
assert current in (original, original.replace(old, new, 1)), "unexpected gVisor cache modification"
if current != original:
    endpoint.chmod(endpoint.stat().st_mode | 0o200)
    endpoint.write_bytes(original)
