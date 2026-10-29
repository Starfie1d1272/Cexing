#!/usr/bin/env python3
"""Verify latest GeoIP and reconstruct GeoSite from a fixed baseline."""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile

REPO = 'MetaCubeX/meta-rules-dat'
GEOSITE_COMMIT = 'be456e5c402c4a9c98519e73f09256c96914cefd'
GEOSITE_SOURCE_SHA = '38aac2a107485a3818501106292efbbc92214588aa1d62ac5fb5d8a1d1a335f7'
GEOSITE_RESULT_SHA = '871a8ba2177f28721230021f1641e2c6fc4b2f3953b0a0881fa4c5396f3d1e0d'
ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'cexing/entry/src/main/resources/rawfile/geodata/geoip.metadb'
RECORD = ROOT / 'cexing/dist/geodata-identity.json'
INPUTS = ROOT / 'cexing/dist/geodata-inputs'


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def fetch(url, destination, token=None):
    config = 'url = ' + json.dumps(url) + '\n'
    if token:
        config += 'header = ' + json.dumps('Authorization: Bearer ' + token) + '\n'
    result = subprocess.run(['curl', '--config', '-', '--fail', '--silent', '--location',
                             '--proto', '=https', '--proto-redir', '=https', '--retry', '3',
                             '--connect-timeout', '30', '--max-time', '120', '-o', str(destination)],
                            input=config, text=True, capture_output=True)
    require(result.returncode == 0, 'GeoIP latest download failed; no historical snapshot substituted')


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


RECORD.unlink(missing_ok=True)
with tempfile.TemporaryDirectory() as work:
    metadata = pathlib.Path(work) / 'release.json'
    fetch(f'https://api.github.com/repos/{REPO}/releases/tags/latest', metadata,
          os.environ.get('GH_TOKEN'))
    release = json.loads(metadata.read_text())
    require(not release['draft'] and not release['prerelease'], 'GeoIP latest must be a published stable release')
    matches = [a for a in release['assets'] if a['name'] == 'geoip.metadb']
    require(len(matches) == 1, 'Expected one latest GeoIP asset')
    asset = matches[0]
    digest = asset.get('digest', '') or ''
    require(digest.startswith('sha256:') and len(digest) == 71
            and all(c in '0123456789abcdef' for c in digest[7:]), 'Upstream GeoIP asset has no valid published SHA-256')
    expected = digest[7:]
    url = asset['browser_download_url']
    require(url == f'https://github.com/{REPO}/releases/download/latest/geoip.metadb', 'Unexpected GeoIP upstream URL')
    if not OUT.is_file() or sha(OUT) != expected:
        downloaded = pathlib.Path(work) / 'geoip.metadb'
        fetch(url, downloaded)
        require(downloaded.stat().st_size == asset['size'] and sha(downloaded) == expected,
                'GeoIP latest size/SHA-256 mismatch; do not bypass integrity checks')
        OUT.parent.mkdir(parents=True, exist_ok=True)
        # Move through the destination filesystem so cross-filesystem rename works.
        shutil.copyfile(downloaded, OUT.with_suffix('.pending'))
        OUT.with_suffix('.pending').replace(OUT)
    # The upstream workflow converts this release's geoip.dat into geoip.metadb.
    # Preserve that exact published input, independently of the packaged output.
    input_matches = [a for a in release['assets'] if a['name'] == 'geoip.dat']
    require(len(input_matches) == 1, 'Expected one GeoIP source asset')
    ip_input = input_matches[0]
    input_digest = ip_input.get('digest', '') or ''
    require(input_digest.startswith('sha256:') and len(input_digest) == 71
            and all(c in '0123456789abcdef' for c in input_digest[7:]),
            'Upstream GeoIP source has no valid published SHA-256')
    input_url = ip_input['browser_download_url']
    require(input_url == f'https://github.com/{REPO}/releases/download/latest/geoip.dat',
            'Unexpected GeoIP source URL')
    ip_source = pathlib.Path(work) / 'geoip.dat'
    fetch(input_url, ip_source)
    require(ip_source.stat().st_size == ip_input['size'] and sha(ip_source) == input_digest[7:],
            'GeoIP source size/SHA-256 mismatch')
    # A fixed baseline permits independent comparison while the full input chain
    # is being reconstructed. It does not resolve that baseline's source licenses.
    geosite_url = f'https://raw.githubusercontent.com/{REPO}/{GEOSITE_COMMIT}/geosite.dat'
    geosite_source = pathlib.Path(work) / 'geosite-source.dat'
    fetch(geosite_url, geosite_source)
    require(sha(geosite_source) == GEOSITE_SOURCE_SHA, 'Fixed GeoSite baseline digest mismatch')
    built = pathlib.Path(work) / 'geosite.dat'
    result = subprocess.run(['go', 'run', '../scripts/ci/replace-geosite.go', str(geosite_source),
                             str(ROOT / 'third_party/geodata/categories.json'), str(built)],
                            cwd=ROOT / 'core', capture_output=True)
    require(result.returncode == 0 and sha(built) == GEOSITE_RESULT_SHA,
            'GeoSite category reconstruction or digest failed')
    geosite_out = OUT.parent / 'geosite.dat'
    shutil.copyfile(built, geosite_out.with_suffix('.pending'))
    geosite_out.with_suffix('.pending').replace(geosite_out)
    INPUTS.mkdir(parents=True, exist_ok=True)
    for source, name in [(ip_source, 'geoip.dat'), (geosite_source, 'geosite.dat')]:
        shutil.copyfile(source, INPUTS / (name + '.pending'))
        (INPUTS / (name + '.pending')).replace(INPUTS / name)
    RECORD.parent.mkdir(parents=True, exist_ok=True)
    RECORD.write_text(json.dumps({
        'policy': 'latest-stable', 'repository': REPO, 'releaseId': release['id'],
        'publishedAt': release['published_at'], 'assetId': asset['id'],
        'url': url, 'expectedSha256': expected, 'downloadedSha256': sha(OUT),
        'bytes': OUT.stat().st_size,
        'geoipSource': {'assetId': ip_input['id'], 'url': input_url,
                        'sha256': input_digest[7:], 'bytes': ip_source.stat().st_size},
        'geosite': {'sourceCommit': GEOSITE_COMMIT, 'sourceSha256': GEOSITE_SOURCE_SHA,
                    'url': geosite_url, 'expectedSha256': GEOSITE_RESULT_SHA, 'downloadedSha256': sha(geosite_out),
                    'bytes': geosite_out.stat().st_size},
    }, indent=2) + '\n')
print('PASS: GeoIP latest verified; fixed GeoSite baseline and rebuilt categories verified')
