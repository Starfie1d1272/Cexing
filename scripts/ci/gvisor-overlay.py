#!/usr/bin/env python3
"""Patch only the selected gVisor endpoint through Go's build overlay."""
import json
import pathlib
import subprocess
import sys
import zipfile

out = pathlib.Path(sys.argv[1]).resolve()
module = json.loads(subprocess.check_output(
    ['go', 'list', '-m', '-json', 'github.com/metacubex/gvisor'], text=True))
endpoint = pathlib.Path(module['Dir']) / 'pkg/tcpip/link/fdbased/endpoint.go'
source = endpoint.read_text()
old = '\t\treturn false, fmt.Errorf("unix.Fstat(%v,...) failed: %v", fd, err)\n'
new = '\t\treturn false, nil // OHOS: VPN tun fd is not Fstat-able (musl/SELinux); treat as non-socket\n'
download = json.loads(subprocess.check_output(
    ['go', 'mod', 'download', '-json', module['Path'] + '@' + module['Version']], text=True))
with zipfile.ZipFile(download['Zip']) as archive:
    original = archive.read(module['Path'] + '@' + module['Version'] + '/pkg/tcpip/link/fdbased/endpoint.go').decode()
if original.count(old) != 1 or source not in (original, original.replace(old, new, 1)):
    raise SystemExit('gVisor source drift: expected original or exact legacy Fstat patch; use a pristine isolated GOMODCACHE')
out.mkdir(parents=True, exist_ok=True)
patched = out / 'endpoint.go'
patched.write_text(original.replace(old, new, 1))
(out / 'overlay.json').write_text(json.dumps({'Replace': {str(endpoint): str(patched)}}))
print('gVisor overlay prepared for ' + module['Version'])
