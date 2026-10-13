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
(report / 'build-identity.json').unlink(missing_ok=True)
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
def selected(dep):
    replacement = dep.get('Replace')
    if replacement:
        require(dep['Path'] == 'github.com/metacubex/mihomo' and
                (replacement['Path'], replacement['Version'], replacement.get('Sum')) ==
                ('github.com/vernesong/mihomo', 'v1.19.10-0.20261012020909-daf3ad03021c',
                 'h1:23XrQ5vZacJbpvuIadl9FNjak2VXIQbzwXx+xU/OtME='),
                'unexpected Go replacement')
        return (replacement['Path'], replacement['Version'], replacement.get('Sum'))
    return (dep['Path'], dep['Version'], dep.get('Sum'))
def modules(info):
    return {d['Path']: selected(d) for d in info['Deps']}
def elf(data, file):
    require(data[:6] == b'\x7fELF\x02\x01' and struct.unpack_from('<HH', data, 16) == (3, 183), str(file) + ' is not ARM64 little-endian ELF DYN')
    symbols = subprocess.check_output([str(readelf), '--dyn-syms', str(file)], text=True)
    return {line.split()[-1].split('@')[0] for line in symbols.splitlines()
            if re.match(r'\s*\d+:', line) and ' UND ' not in line and re.search(r'\bGLOBAL\b', line)}
header = (root / 'clash-openharmony/entry/libs/arm64-v8a/libmihomo.h').read_text()
for declaration in [
    'extern char* mihomoInit(char* homeDir);',
    'extern char* mihomoStartTun(int fd, char* configJson, char* overridesJson);',
    'extern void mihomoStop(void);',
    'extern void mihomoFree(char* p);'
]:
    require(declaration in header, 'generated C ABI prototype: ' + declaration.split('(')[0])
source = metadata(root / 'clash-openharmony/entry/libs/arm64-v8a/libmihomo.so')
# Compare all embedded dependency versions AND sums with the selected module graph.
stream = subprocess.check_output(['go', 'list', '-m', '-json', 'all'], cwd='core', text=True)
expected, decoder = {}, json.JSONDecoder()
while stream.strip():
    item, end = decoder.raw_decode(stream.lstrip())
    stream = stream.lstrip()[end:]
    if not item.get('Main'):
        expected[item['Path']] = selected(item)
for name, identity in modules(source).items():
    require(expected.get(name) == identity, 'source module mismatch: ' + name)
pin = json.loads((root / 'scripts/ci/toolchain.json').read_text())
require(source['GoVersion'] == 'go' + pin['go'], 'Go compiler version')
settings = {s['Key']: s['Value'] for s in source['Settings']}
for key, value in {'GOOS': 'android', 'GOARCH': 'arm64', 'CGO_ENABLED': '1', '-buildmode': 'c-shared', '-trimpath': 'true'}.items():
    require(settings.get(key) == value, 'Go build setting ' + key)
require(set(settings.get('-tags', '').split(',')) == {'netgo', 'ohos', 'cmfa', 'with_gvisor'}, 'platform tags')
smart_record = json.loads((root / 'clash-openharmony/entry/libs/arm64-v8a/smart-build.json').read_text())
require(smart_record['patchSha256'] == sha((root / 'core/patches/smart-offline.patch').read_bytes()), 'reviewed Smart patch identity')
require(smart_record['librarySha256'] == sha((root / 'clash-openharmony/entry/libs/arm64-v8a/libmihomo.so').read_bytes()), 'Smart build record fresh library identity')
require(smart_record['headerSha256'] == sha((root / 'clash-openharmony/entry/libs/arm64-v8a/libmihomo.h').read_bytes()), 'Smart build record ABI header identity')
go_inputs = {file.relative_to(root).as_posix() for file in (root / 'core').rglob('*.go') if not file.name.endswith('_test.go') and 'third_party' not in file.relative_to(root / 'core').parts}
require(go_inputs == {name for name in smart_record['inputs'] if name.startswith('core/') and name.endswith('.go')}, 'Smart production Go source set changed; rebuild core')
require(all(digest == sha((root / name).read_bytes()) for name, digest in smart_record['inputs'].items()), 'Smart build inputs changed; rebuild core')
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
        if name != 'libmihomo.so':
            native = root / 'clash-openharmony/entry/build/default/intermediates/cmake/default/obj/arm64-v8a' / name
            stripped_native = pathlib.Path(directory) / ('fresh-' + name)
            subprocess.check_call([str(sdk / 'native/llvm/bin/llvm-strip'), '--strip-all', '-o', str(stripped_native), str(native)])
            require(stripped_native.read_bytes() == data, 'packaged native library differs from fresh CMake output: ' + name)
        if name == 'libmihomo.so':
            require({'mihomoInit', 'mihomoStartTun', 'mihomoStop', 'mihomoFree'} <= symbols, 'four C ABI exports')
            packaged = metadata(file)
            require(packaged == source, 'packaged Go identity differs from fresh core')
            # Hvigor strips the native library. Compare the complete ELF after the same strip operation.
            stripped = pathlib.Path(directory) / 'fresh.so'
            stripped.write_bytes((root / 'clash-openharmony/entry/libs/arm64-v8a/libmihomo.so').read_bytes())
            subprocess.check_call([str(sdk / 'native/llvm/bin/llvm-strip'), '--strip-all', str(stripped)])
            require(sha(stripped.read_bytes()) == sha(data), 'packaged core is not the freshly built/stripped ELF')
    # Every rawfile is checked, including future offline panel/model assets.
    raw = root / 'clash-openharmony/entry/src/main/resources/rawfile'
    for file in sorted(raw.rglob('*')):
        if file.is_file():
            name = 'resources/rawfile/' + file.relative_to(raw).as_posix()
            require(sha(archive.read(name)) == sha(file.read_bytes()), 'raw resource mismatch: ' + name)
    geodata = json.loads((root / 'clash-openharmony/dist/geodata-identity.json').read_text())
    require(geodata['policy'] == 'latest-stable', 'GeoIP latest selection policy')
    digest = sha(archive.read('resources/rawfile/geodata/geoip.metadb'))
    require(digest == geodata['expectedSha256'] == geodata['downloadedSha256'], 'GeoIP upstream/actual/package identity')
    require(bool(archive.read('resources/rawfile/override.yaml')), 'nonempty default configuration')
    require(not any(pathlib.PurePosixPath(n).name.casefold() == 'model.bin' for n in names), 'unlicensed bundled Model.bin')
report.mkdir(parents=True, exist_ok=True)
identity = {
    'schemaVersion': 1,
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'tree': subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'], text=True).strip(),
    'toolchain': pin,
    'nativeTools': {name: sha((sdk / 'native/llvm/bin' / name).read_bytes()) for name in [
        'aarch64-unknown-linux-ohos-clang', 'llvm-strip', 'llvm-readelf']},
    'app': {k: app[k] for k in ['bundleName', 'versionCode', 'versionName', 'buildVersion']},
    'hapSha256': sha(hap.read_bytes()),
    'freshCoreSha256': sha((root / 'clash-openharmony/entry/libs/arm64-v8a/libmihomo.so').read_bytes()),
    'core': source,
    'smartSource': smart_record,
    'geodata': geodata,
    'inputs': {file: sha((root / file).read_bytes()) for file in [
        'core/go.mod', 'core/go.sum', 'core/patches/smart-offline.patch', 'scripts/ci/patch-smart.py', 'scripts/build-core.sh', 'scripts/ci/patch-gvisor.py',
        'scripts/prepare-geodata.sh', 'scripts/build-hap.sh', 'scripts/env.sh',
        'clash-openharmony/entry/oh-package-lock.json5', 'scripts/ci/package-lock.json', 'scripts/ci/toolchain.json',
        'scripts/ci/sdk-download.json', 'scripts/ci/setup-clt.py', 'scripts/ci/go-download-cache.sh',
        'scripts/ci/prepare-geodata.py',
        'scripts/ci/hvigor-wrapper/package-lock.json', '.github/workflows/full.yml']},
    'entries': entries,
    'signed': False,
    'deviceValidated': False,
    'distributionApproved': False
}
if os.environ.get('GITHUB_ACTIONS') == 'true':
    require(identity['commit'] == os.environ['GITHUB_SHA'], 'GitHub build commit differs from checkout')
    identity['github'] = {key: os.environ[key] for key in [
        'GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_SHA']}
if os.environ.get('CI_SDK_PROVENANCE'):
    identity['sdkProvenance'] = json.loads(pathlib.Path(os.environ['CI_SDK_PROVENANCE']).read_text())
# Keep optional host overlay paths out of public build evidence.
identity['core']['Settings'] = [s for s in source['Settings'] if s['Key'] != '-overlay']
(report / 'build-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
print('PASS: unsigned HAP CRC, fresh native identity, ARM64/C ABI, app versions and all raw resource hashes')
