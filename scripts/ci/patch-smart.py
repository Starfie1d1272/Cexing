#!/usr/bin/env python3
"""Apply the reviewed Smart patch only inside an explicitly private module cache."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

PIN = 'v1.19.10-0.20261012020909-daf3ad03021c'
SUM = 'h1:23XrQ5vZacJbpvuIadl9FNjak2VXIQbzwXx+xU/OtME='
cache = Path(sys.argv[1]).resolve()
actual = Path(subprocess.check_output(['go', 'env', 'GOMODCACHE'], text=True).strip()).resolve()
if cache != actual or cache.is_symlink():
    raise SystemExit('Expected explicitly supplied private GOMODCACHE')
module = json.loads(subprocess.check_output(['go', 'list', '-m', '-json', 'github.com/metacubex/mihomo'], text=True))['Replace']
if (module['Path'], module['Version'], module['Sum']) != ('github.com/vernesong/mihomo', PIN, SUM):
    raise SystemExit('Smart upstream identity drift')
directory = Path(module['Dir'])
directory.resolve().relative_to(cache)
patch = Path(__file__).resolve().parents[2] / 'core/patches/smart-offline.patch'
paths = ['component/smart/lightgbm/lightgbm.go', 'component/updater/update_lgbm.go', 'hub/route/ohos_smart.go', 'hub/route/server.go']
download = json.loads(subprocess.check_output(['go', 'mod', 'download', '-json', module['Path'] + '@' + PIN], text=True))
with zipfile.ZipFile(download['Zip']) as archive:
    prefix = module['Path'] + '@' + PIN + '/'
    originals = {path: archive.read(prefix + path) if prefix + path in archive.namelist() else None for path in paths}
source_record = cache / '.smart-source.json'
def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()
operation = sys.argv[2] if len(sys.argv) > 2 else 'apply'
if operation == 'record':
    recorded = json.loads(source_record.read_text())
    if recorded['patchSha256'] != digest(patch) or recorded['files'] != {path: digest(directory / path) for path in paths}:
        raise SystemExit('Smart source changed after patch verification')
    library = Path(sys.argv[3])
    root = patch.parents[2]
    recorded['librarySha256'] = digest(library)
    recorded['headerSha256'] = digest(library.with_suffix('.h'))
    recorded['inputs'] = {name: digest(root / name) for name in [
        'core/go.mod', 'core/go.sum', 'core/patches/smart-offline.patch',
        'scripts/build-core.sh', 'scripts/ci/patch-smart.py', 'scripts/ci/patch-gvisor.py']}
    library.with_name('smart-build.pending.json').write_text(json.dumps(recorded, indent=2) + '\n')
    print('Bound fresh Smart library to verified patched source')
    raise SystemExit(0)
if operation == 'restore':
    for path, data in originals.items():
        file = directory / path
        if data is None:
            file.unlink(missing_ok=True)
        else:
            file.chmod(file.stat().st_mode | 0o200)
            file.write_bytes(data)
else:
    for path, data in originals.items():
        file = directory / path
        if (file.read_bytes() if file.exists() else None) != data:
            raise SystemExit('Smart source is not pristine: ' + path)
        file.parent.chmod(file.parent.stat().st_mode | 0o200)
        if file.exists():
            file.chmod(file.stat().st_mode | 0o200)
    (directory / 'hub/route').chmod((directory / 'hub/route').stat().st_mode | 0o200)
    subprocess.check_call(['patch', '--batch', '--fuzz=0', '--forward', '-d', str(directory), '-p1', '-i', str(patch)])
    source_record.write_text(json.dumps({'patchSha256': digest(patch), 'upstream': {'path': module['Path'], 'version': PIN, 'sum': SUM}, 'files': {path: digest(directory / path) for path in paths}}, indent=2) + '\n')
print('Smart patch ' + hashlib.sha256(patch.read_bytes()).hexdigest())
