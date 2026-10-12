#!/usr/bin/env python3
"""Critical patch boundaries: selected module, legacy compatibility, fail on drift."""
import json
import os
import pathlib
import subprocess
import tempfile
import zipfile

helper = pathlib.Path('scripts/ci/patch-gvisor.py').resolve()
old = '\t\treturn false, fmt.Errorf("unix.Fstat(%v,...) failed: %v", fd, err)\n'
new = '\t\treturn false, nil // OHOS: VPN tun fd is not Fstat-able (musl/SELinux); treat as non-socket\n'
original = '// synthetic endpoint\n' + old
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    module = root / 'selected'
    endpoint = module / 'pkg/tcpip/link/fdbased/endpoint.go'
    endpoint.parent.mkdir(parents=True)
    archive = root / 'module.zip'
    name, version = 'github.com/metacubex/gvisor', 'v0.0.0-test'
    with zipfile.ZipFile(archive, 'w') as file:
        file.writestr(name + '@' + version + '/pkg/tcpip/link/fdbased/endpoint.go', original)
    fake = root / 'go'
    fake.write_text('#!/usr/bin/env python3\nimport os,sys\nprint(os.environ["CACHE"] if sys.argv[1] == "env" else os.environ["MODULE" if sys.argv[1] == "list" else "DOWNLOAD"])\n')
    fake.chmod(0o755)
    env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'],
               MODULE=json.dumps({'Path': name, 'Version': version, 'Dir': str(module)}),
               DOWNLOAD=json.dumps({'Zip': str(archive)}), CACHE=str(module))
    other = root / 'other-version.go'
    other.write_text(original)
    for case, source, succeeds in [('original', original, True), ('legacy', original.replace(old, new), True),
                                  ('drift', original + '// unexpected change\n', False)]:
        endpoint.write_text(source)
        out = root / case
        result = subprocess.run(['python3', str(helper), str(module)], env=env, capture_output=True, text=True)
        assert (result.returncode == 0) == succeeds, result.stderr
        assert endpoint.read_text() == (original.replace(old, new) if succeeds else source)
        assert other.read_text() == original, 'unselected version was changed'
print('PASS: selected private-cache patch, legacy compatibility and unexpected drift refusal')
