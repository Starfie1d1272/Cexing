#!/usr/bin/env python3
"""Apply the pinned tracker observer only in a private Go module cache."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

PIN = 'v1.19.10-0.20261012020909-daf3ad03021c'
SUM = 'h1:23XrQ5vZacJbpvuIadl9FNjak2VXIQbzwXx+xU/OtME='
PATHS = ['tunnel/statistic/tracker.go', 'adapter/outbound/base.go', 'constant/metadata.go', 'listener/sing/sing.go']
cache = Path(sys.argv[1]).resolve()
actual = Path(subprocess.check_output(['go', 'env', 'GOMODCACHE'], text=True).strip()).resolve()
if cache != actual or cache.is_symlink():
    raise SystemExit('Expected explicitly supplied private GOMODCACHE')
module = json.loads(subprocess.check_output(
    ['go', 'list', '-m', '-json', 'github.com/metacubex/mihomo'], text=True))['Replace']
if (module['Path'], module['Version'], module['Sum']) != ('github.com/vernesong/mihomo', PIN, SUM):
    raise SystemExit('App traffic patch upstream identity drift')
directory = Path(module['Dir'])
directory.resolve().relative_to(cache)
patch = Path(__file__).resolve().parents[2] / 'core/patches/app-traffic.patch'
download = json.loads(subprocess.check_output(
    ['go', 'mod', 'download', '-json', module['Path'] + '@' + PIN], text=True))
with zipfile.ZipFile(download['Zip']) as archive:
    prefix = module['Path'] + '@' + PIN + '/'
    originals = {name: archive.read(prefix + name) for name in PATHS}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

record_path = cache / '.app-traffic-source.json'
operation = sys.argv[2] if len(sys.argv) > 2 else 'apply'
if operation == 'record':
    record = json.loads(record_path.read_text())
    if record['patchSha256'] != digest(patch) or record['files'] != {
            name: digest(directory / name) for name in PATHS}:
        raise SystemExit('App traffic source changed after patch verification')
    library = Path(sys.argv[3])
    build = library.with_name('smart-build.pending.json')
    identity = json.loads(build.read_text())
    identity['appTraffic'] = record
    build.write_text(json.dumps(identity, indent=2) + '\n')
    print('Bound app traffic patch to fresh library')
    raise SystemExit(0)
if operation == 'restore':
    record = json.loads(record_path.read_text())
    if record['files'] != {name: digest(directory / name) for name in PATHS}:
        raise SystemExit('App traffic source changed before restore')
    for name, data in originals.items():
        file = directory / name
        file.chmod(file.stat().st_mode | 0o200)
        file.write_bytes(data)
    print('Restored pinned tracker module source')
    raise SystemExit(0)
if operation != 'apply':
    raise SystemExit('Unknown operation')
for name, data in originals.items():
    file = directory / name
    if file.read_bytes() != data:
        raise SystemExit('App traffic source is not pristine: ' + name)
    file.parent.chmod(file.parent.stat().st_mode | 0o200)
    file.chmod(file.stat().st_mode | 0o200)
subprocess.check_call(['patch', '--batch', '--fuzz=0', '--forward', '-d', str(directory), '-p1', '-i', str(patch)])
record_path.write_text(json.dumps({
    'patchSha256': digest(patch),
    'upstream': {'path': module['Path'], 'version': PIN, 'sum': SUM},
    'files': {name: digest(directory / name) for name in PATHS},
}, indent=2) + '\n')
print('App traffic snapshot patch ' + digest(patch))
