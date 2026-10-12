#!/usr/bin/env python3
"""Inspect the fresh unsigned HAP; emit hashes and public identity only."""
import hashlib
import json
import os
import pathlib
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

hap, report = map(pathlib.Path, sys.argv[1:3])
root = pathlib.Path.cwd()
sdk = pathlib.Path(os.environ['OHOS_SDK_HOME'])
readelf = sdk / 'native/llvm/bin/llvm-readelf'
def require(condition, message):
    if not condition:
        raise SystemExit('HAP validation failed: ' + message)
def sha(data):
    return hashlib.sha256(data).hexdigest()
def metadata(file):
    return json.loads(subprocess.check_output(['go', 'version', '-m', '-json', str(file)], text=True))
def modules(info):
    require(all(not dep.get('Replace') for dep in info['Deps']), 'unexpected Go replacement')
    return {d['Path']: (d['Version'], d.get('Sum')) for d in info['Deps']}
def elf(data, file):
    require(data[:6] == b'\x7fELF\x02\x01' and struct.unpack_from('<HH', data, 16) == (3, 183), str(file) + ' is not ARM64 little-endian ELF DYN')
    symbols = subprocess.check_output([str(readelf), '--dyn-syms', str(file)], text=True)
    return {line.split()[-1].split('@')[0] for line in symbols.splitlines()
            if re.match(r'\s*\d+:', line) and ' UND ' not in line and re.search(r'\bGLOBAL\b', line)}
source = metadata(root / 'clash-openharmony/entry/libs/arm64-v8a/libmihomo.so')
# Compare all embedded dependency versions AND sums with the selected module graph.
stream = subprocess.check_output(['go', 'list', '-m', '-json', 'all'], cwd='core', text=True)
expected, decoder = {}, json.JSONDecoder()
while stream.strip():
    item, end = decoder.raw_decode(stream.lstrip())
    stream = stream.lstrip()[end:]
    require(not item.get('Replace'), 'module replacements need review')
    if not item.get('Main'):
        expected[item['Path']] = (item['Version'], item.get('Sum'))
for name, identity in modules(source).items():
    require(expected.get(name) == identity, 'source module mismatch: ' + name)
pin = json.loads((root / 'scripts/ci/toolchain.json').read_text())
require(source['GoVersion'] == 'go' + pin['go'], 'Go compiler version')
settings = {s['Key']: s['Value'] for s in source['Settings']}
for key, value in {'GOOS': 'android', 'GOARCH': 'arm64', 'CGO_ENABLED': '1', '-buildmode': 'c-shared', '-trimpath': 'true'}.items():
    require(settings.get(key) == value, 'Go build setting ' + key)
require(set(settings.get('-tags', '').split(',')) == {'netgo', 'ohos', 'cmfa', 'with_gvisor'}, 'platform tags')
entries = []
with zipfile.ZipFile(hap) as archive, tempfile.TemporaryDirectory() as directory:
    names = archive.namelist()
    require(len(names) == len(set(names)), 'duplicate ZIP paths')
    require(archive.testzip() is None, 'ZIP CRC')
    for entry in archive.infolist():
        p = pathlib.PurePosixPath(entry.filename)
        require(not p.is_absolute() and '..' not in p.parts and '\\' not in entry.filename, 'unsafe ZIP path')
        require(not entry.flag_bits & 1, 'encrypted ZIP entry')
        require((entry.external_attr >> 16) & 0o170000 != 0o120000, 'ZIP symlink')
        require(not re.search(r'\.(p12|pfx|p7b|cer|pem|key|jks)$', entry.filename, re.I), 'credential-shaped ZIP entry')
        data = archive.read(entry)
        if data.startswith(b'-----BEGIN ') and b'PRIVATE KEY-----' in data[:100]:
            raise SystemExit('HAP validation failed: private key (value withheld)')
        entries.append({'path': entry.filename, 'bytes': len(data), 'sha256': sha(data)})
    module = json.loads(archive.read('module.json'))
    app = json.loads((root / 'clash-openharmony/AppScope/app.json5').read_text())['app']
    for field in ['bundleName', 'versionCode', 'versionName', 'buildVersion']:
        require(module['app'][field] == app[field], 'app identity: ' + field)
    require(module['app']['compileSdkVersion'] == pin['sdk'], 'packaged SDK identity')
    for name in ['libmihomo.so', 'libentry.so', 'libc++_shared.so']:
        data = archive.read('libs/arm64-v8a/' + name)
        file = pathlib.Path(directory) / name
        file.write_bytes(data)
        symbols = elf(data, file)
        if name == 'libmihomo.so':
            require({'mihomoInit', 'mihomoStartTun', 'mihomoStop', 'mihomoFree'} <= symbols, 'four C ABI exports')
            packaged = metadata(file)
            require(packaged == source, 'packaged Go identity differs from fresh core')
            # Hvigor strips the native library. Compare the complete ELF after the same strip operation.
            stripped = pathlib.Path(directory) / 'fresh.so'
            stripped.write_bytes((root / 'clash-openharmony/entry/libs/arm64-v8a/libmihomo.so').read_bytes())
            subprocess.check_call([str(sdk / 'native/llvm/bin/llvm-strip'), '--strip-unneeded', str(stripped)])
            require(sha(stripped.read_bytes()) == sha(data), 'packaged core is not the freshly built/stripped ELF')
    # Every rawfile is checked, including future offline panel/model assets.
    raw = root / 'clash-openharmony/entry/src/main/resources/rawfile'
    for file in sorted(raw.rglob('*')):
        if file.is_file():
            name = 'resources/rawfile/' + file.relative_to(raw).as_posix()
            require(sha(archive.read(name)) == sha(file.read_bytes()), 'raw resource mismatch: ' + name)
    resource_script = (root / 'scripts/prepare-geodata.sh').read_text()
    digest = re.search(r'^SHA=([a-f0-9]{64})$', resource_script, re.M).group(1)
    require(sha(archive.read('resources/rawfile/geodata/geoip.metadb')) == digest, 'GeoIP pin')
    require('resources/rawfile/override.yaml' in names, 'default configuration')
report.mkdir(parents=True, exist_ok=True)
identity = {
    'schemaVersion': 1,
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'tree': subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], text=True).strip(),
    'toolchain': pin,
    'app': {k: app[k] for k in ['bundleName', 'versionCode', 'versionName', 'buildVersion']},
    'hapSha256': sha(hap.read_bytes()),
    'freshCoreSha256': sha((root / 'clash-openharmony/entry/libs/arm64-v8a/libmihomo.so').read_bytes()),
    'core': source,
    'inputs': {file: sha((root / file).read_bytes()) for file in [
        'core/go.mod', 'core/go.sum', 'scripts/build-core.sh', 'scripts/ci/gvisor-overlay.py',
        'scripts/prepare-geodata.sh', 'scripts/ci/package-lock.json', 'scripts/ci/toolchain.json']},
    'entries': entries,
    'signed': False,
    'deviceValidated': False,
    'distributionApproved': False
}
# Overlay contains a temporary host path; keep the public report path-independent.
identity['core']['Settings'] = [s for s in source['Settings'] if s['Key'] != '-overlay']
(report / 'build-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
print('PASS: unsigned HAP CRC, fresh native identity, ARM64/C ABI, app versions and all raw resource hashes')
