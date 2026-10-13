#!/usr/bin/env python3
"""Download the reviewed CLT archive without logging its bearer query string."""
import hashlib
import json
import os
import pathlib
import posixpath
import subprocess
import tempfile
import urllib.parse
import zipfile


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def reviewed_url(value):
    parsed = urllib.parse.urlsplit(value)
    # Each host must be reviewed. Never accept arbitrary archives or auth cookies.
    return (parsed.scheme == 'https' and parsed.hostname in {
        'developer.huawei.com', 'update.dbankcdn.com', 'update.hicloud.com',
        'download.developer.huawei.com', 'box.nju.edu.cn',
    } and parsed.port in (None, 443) and not parsed.username and not parsed.password
        and not parsed.fragment and '\n' not in value and '\r' not in value)


def verify_archive(archive, expected):
    with archive.open('rb') as f:
        digest = hashlib.file_digest(f, 'sha256').hexdigest()
    require(digest == expected, 'Pinned CLT SHA-256 mismatch; no extraction performed')
    with zipfile.ZipFile(archive) as z:
        require(len(z.namelist()) == len(set(z.namelist())), 'Duplicate CLT ZIP paths')
        for entry in z.infolist():
            p = pathlib.PurePosixPath(entry.filename)
            require(not p.is_absolute() and '..' not in p.parts and '\\' not in entry.filename
                    and p.parts and p.parts[0] == 'command-line-tools', 'Unsafe CLT ZIP path')
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                target = z.read(entry).decode()
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(entry.filename), target))
                require(not target.startswith('/') and resolved.startswith('command-line-tools/')
                        and '\\' not in target, 'Unsafe CLT ZIP symlink')
        require(z.testzip() is None, 'CLT ZIP CRC mismatch')
    return digest


def main():
    pin = json.loads(pathlib.Path('scripts/ci/toolchain.json').read_text())
    download = json.loads(pathlib.Path('scripts/ci/sdk-download.json').read_text())
    require(download['clt'] == pin['clt'], 'Download pin differs from the build toolchain')
    url = os.environ.get('HARMONYOS_CLT_URL') or download['url']
    expected = download['sha256']
    require(os.environ.get('AUTHORIZED_SDK') == 'true', 'BLOCKED: official SDK license must be accepted for this build environment')
    require(reviewed_url(url), 'CLT URL must use an explicitly reviewed HTTPS host')
    require(len(expected) == 64 and all(c in '0123456789abcdef' for c in expected), 'Invalid pinned CLT SHA-256')
    destination = pathlib.Path(os.environ['RUNNER_TEMP']) / 'harmonyos-clt'
    require(not destination.exists(), 'Refusing to reuse an unverified installed CLT')
    with tempfile.TemporaryDirectory(dir=os.environ['RUNNER_TEMP']) as work:
        archive = pathlib.Path(work) / 'clt.zip'
        # stdin keeps the signed URL out of command arguments, process lists and logs.
        config = 'url = ' + json.dumps(url) + '\n'
        result = subprocess.run(['curl', '--config', '-', '--proto', '=https', '--silent', '--fail',
                                 '--retry', '3', '--connect-timeout', '30', '--max-time', '1200',
                                 '--output', str(archive)], input=config, text=True, capture_output=True)
        require(result.returncode == 0, 'Pinned CLT download failed (URL withheld); renew authorization/URL in the reviewed source')
        require(archive.stat().st_size == download['bytes'], 'CLT download is incomplete or redirected; expected archive size differs')
        # Do not follow redirects: they must be resolved through the authorized portal and reviewed.
        digest = verify_archive(archive, expected)
        destination.mkdir()
        subprocess.run(['unzip', '-q', str(archive), '-d', str(destination)], check=True)
    clt = destination / 'command-line-tools'
    require('Version: ' + pin['clt'] in (clt / 'version.txt').read_text(), 'Unexpected CLT release')
    provenance = pathlib.Path(os.environ['RUNNER_TEMP']) / 'sdk-provenance.json'
    provenance.write_text(json.dumps({
        'clt': pin['clt'], 'archiveSha256': digest,
        'originHost': urllib.parse.urlsplit(url).hostname,
        'checksumSource': download['checksumSource'],
        'licenseSha256': hashlib.sha256((clt / 'LICENSE.txt').read_bytes()).hexdigest(),
        'sdkCached': False,
        'sourceKind': 'community-mirror' if urllib.parse.urlsplit(url).hostname == 'box.nju.edu.cn' else 'vendor-download',
    }, indent=2) + '\n')
    with open(os.environ['GITHUB_ENV'], 'a') as f:
        f.write(f'HARMONYOS_CLT_ROOT={clt}\nCI_SDK_PROVENANCE={provenance}\n')
    print('PASS: pinned CLT archive SHA-256, ZIP paths/CRC and release; no SDK cache or redistribution')


if __name__ == '__main__':
    main()
