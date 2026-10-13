#!/usr/bin/env python3
"""Resolve upstream latest for this build and check its published asset digest."""
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

REPO = 'MetaCubeX/meta-rules-dat'
ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'clash-openharmony/entry/src/main/resources/rawfile/geodata/geoip.metadb'
RECORD = ROOT / 'clash-openharmony/dist/geodata-identity.json'


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
        import shutil
        shutil.copyfile(downloaded, OUT.with_suffix('.pending'))
        OUT.with_suffix('.pending').replace(OUT)
    RECORD.parent.mkdir(parents=True, exist_ok=True)
    RECORD.write_text(json.dumps({
        'policy': 'latest-stable', 'repository': REPO, 'releaseId': release['id'],
        'publishedAt': release['published_at'], 'assetId': asset['id'],
        'url': url, 'expectedSha256': expected, 'downloadedSha256': sha(OUT),
        'bytes': OUT.stat().st_size,
    }, indent=2) + '\n')
print('PASS: latest stable GeoIP resolved, upstream size/digest verified and actual identity recorded')
