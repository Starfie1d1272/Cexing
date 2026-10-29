#!/usr/bin/env python3
"""Build fixed GeoIP and GeoSite inputs and record their exact identities."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
DIST = ROOT / 'cexing/dist'
OUT = ROOT / 'cexing/entry/src/main/resources/rawfile/geodata'
GEOSITE_URL = 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/be456e5c402c4a9c98519e73f09256c96914cefd/geosite.dat'
GEOSITE_UPSTREAM_SHA = '38aac2a107485a3818501106292efbbc92214588aa1d62ac5fb5d8a1d1a335f7'
GEOSITE_SOURCE_SHA = 'ea5bc44cf6d2baba4167a906243c28907de8277d8f141db1548cd79732aadf13'
GEOSITE_SHA = '093823995ff4472ca2d39bde192de8ce993c3ed6626847f1e769592c43562465'
GEOIP_SOURCE_SHA = '02ec4566b23662b3508b481c4a35136fa9d2b56436775dd87a0c11860f89b001'
GEOIP_SHA = '378a5083bde959a7c487f2c8f2dcd439bad5a48a23142f1f1d4e194d511f67c5'
HTTPDNS_SOURCE_SHA = '1f22f942384e2f71ead423d3fbd02703734c17f93762975d74556ebcade89b86'


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def require(condition, message):
    if not condition:
        raise SystemExit(message)


(DIST / 'geodata-identity.json').unlink(missing_ok=True)
with tempfile.TemporaryDirectory() as temporary:
    work = pathlib.Path(temporary)
    base = ROOT / 'third_party/geodata-source/community/baseline.dat'
    require(sha(base) == GEOSITE_SOURCE_SHA, 'GeoSite baseline digest mismatch')
    require(sha(ROOT / 'third_party/geodata/sources/HTTPDNS.Block.list') == HTTPDNS_SOURCE_SHA,
            'HTTPDNS source digest mismatch')
    subprocess.run(['bash', str(ROOT / 'third_party/geodata-candidate/build.sh'), str(work / 'ip')], check=True)
    ip_input, ip = work / 'ip/geoip.dat', work / 'ip/geoip.metadb'
    require(sha(ip_input) == GEOIP_SOURCE_SHA and sha(ip) == GEOIP_SHA, 'GeoIP fixed build digest mismatch')
    generated = work / 'community.dat'
    subprocess.run(['python3', str(ROOT / 'scripts/ci/build-geosite-input.py'), str(generated)], check=True)
    local = work / 'local.dat'
    final = work / 'geosite.dat'
    subprocess.run(['go', 'run', '../scripts/ci/replace-geosite.go', str(base),
                    str(ROOT / 'third_party/geodata/categories.json'), str(local)], cwd=ROOT / 'core', check=True)
    subprocess.run(['go', 'run', '../scripts/ci/merge-geosite.go', str(local), str(generated), str(final)],
                   cwd=ROOT / 'core', check=True)
    require(sha(final) == GEOSITE_SHA, 'GeoSite fixed build digest mismatch')
    OUT.mkdir(parents=True, exist_ok=True)
    inputs = DIST / 'geodata-inputs'
    inputs.mkdir(parents=True, exist_ok=True)
    for src, dest in [(ip, OUT / 'geoip.metadb'), (final, OUT / 'geosite.dat'),
                      (ip_input, inputs / 'geoip.dat'), (base, inputs / 'geosite.dat')]:
        pending = dest.with_name(dest.name + '.pending')
        shutil.copyfile(src, pending)
        pending.replace(dest)
    identity = {
        'policy': 'fixed-source', 'repository': 'Cexing',
        'expectedSha256': GEOIP_SHA, 'downloadedSha256': sha(ip), 'bytes': ip.stat().st_size,
        'geoipSource': {'sha256': GEOIP_SOURCE_SHA, 'bytes': ip_input.stat().st_size},
        'geosite': {'sourceCommit': 'be456e5c402c4a9c98519e73f09256c96914cefd',
                    'upstreamSha256': GEOSITE_UPSTREAM_SHA, 'sourceSha256': GEOSITE_SOURCE_SHA, 'url': GEOSITE_URL,
                    'expectedSha256': GEOSITE_SHA, 'downloadedSha256': sha(final), 'bytes': final.stat().st_size},
    }
    (DIST / 'geodata-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
print('PASS: fixed GeoIP and GeoSite inputs built and verified')
