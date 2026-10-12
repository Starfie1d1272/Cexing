#!/usr/bin/env python3
"""Patch/verify only the selected gVisor in a disposable build module cache."""
import json
import pathlib
import subprocess
import sys
import zipfile

cache = pathlib.Path(sys.argv[1]).resolve()
actual = pathlib.Path(subprocess.check_output(['go', 'env', 'GOMODCACHE'], text=True).strip()).resolve()
if cache != actual or cache.is_symlink():
    raise SystemExit('Expected the explicitly supplied private GOMODCACHE')
module = json.loads(subprocess.check_output(
    ['go', 'list', '-m', '-json', 'github.com/metacubex/gvisor'], text=True))
endpoint = pathlib.Path(module['Dir']) / 'pkg/tcpip/link/fdbased/endpoint.go'
endpoint.resolve().relative_to(cache)
source = endpoint.read_text()
old = '\t\treturn false, fmt.Errorf("unix.Fstat(%v,...) failed: %v", fd, err)\n'
new = '\t\treturn false, nil // OHOS: VPN tun fd is not Fstat-able (musl/SELinux); treat as non-socket\n'
download = json.loads(subprocess.check_output(
    ['go', 'mod', 'download', '-json', module['Path'] + '@' + module['Version']], text=True))
with zipfile.ZipFile(download['Zip']) as archive:
    original = archive.read(module['Path'] + '@' + module['Version'] + '/pkg/tcpip/link/fdbased/endpoint.go').decode()
if original.count(old) != 1 or source not in (original, original.replace(old, new, 1)):
    raise SystemExit('gVisor source drift: expected original or exact legacy Fstat patch; use a pristine isolated GOMODCACHE')
endpoint.chmod(endpoint.stat().st_mode | 0o200)
if len(sys.argv) > 2 and sys.argv[2] == 'verify':
    # Restore only in the private cache for upstream integrity verification.
    endpoint.write_text(original)
    try:
        subprocess.check_call(['go', 'mod', 'verify'])
    finally:
        endpoint.write_text(source)
else:
    endpoint.write_text(original.replace(old, new, 1))
print('gVisor private-cache patch verified for ' + module['Version'])
