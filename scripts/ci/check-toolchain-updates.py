#!/usr/bin/env python3
"""Propose newer stable runtimes; report SDK/pnpm candidates without guessing compatibility."""
import json
import pathlib
import re
import urllib.request
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parents[2]
PIN = ROOT / 'scripts/ci/toolchain.json'


def get(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)


def version(value):
    return tuple(int(x) for x in re.sub(r'^(go|v)', '', value).split('.'))


pin = json.loads(PIN.read_text())
proposed = dict(pin)
go = [r['version'].removeprefix('go') for r in get('https://go.dev/dl/?mode=json') if r['stable']]
node = [r['version'].removeprefix('v') for r in get('https://nodejs.org/dist/index.json')
        if re.fullmatch(r'v\d+\.\d+\.\d+', r['version'])]
java = pin['javaMajor']
# Adoptium publishes stable releases in the official Temurin GitHub repositories.
# /releases/latest excludes prereleases; an unpublished next major returns 404.
for major in range(int(pin['javaMajor']), int(pin['javaMajor']) + 3):
    try:
        release = get(f'https://api.github.com/repos/adoptium/temurin{major}-binaries/releases/latest')
    except urllib.error.HTTPError as error:
        if error.code == 404:
            continue
        raise
    if not release['prerelease'] and not release['draft']:
        java = str(major)
for key, candidate in [('go', max(go, key=version)), ('node', max(node, key=version)), ('javaMajor', java)]:
    if version(candidate) > version(pin[key]):
        proposed[key] = candidate
# These need coordinated SDK API/plugin/wrapper or resource validation before
# changing the actual toolchain, so open a reviewable candidate record with links.
sdk = get('https://api.github.com/repos/ErBWs/ohos-sdk/releases/latest')
pnpm = get('https://registry.npmjs.org/pnpm/latest')['version']
candidates = {
    'policy': 'prefer-latest-stable; validate-upgrade-before-merge',
    'runtimeProposals': {k: proposed[k] for k in ['go', 'node', 'javaMajor']},
    'sdkMirrorLatest': sdk['tag_name'], 'sdkSource': sdk['html_url'],
    'sdkRequiresCompatibilityReview': True,
    'pnpmLatest': pnpm, 'pnpmRequiresSdkAndPanelCompatibilityReview': True,
}
PIN.write_text(json.dumps(proposed, indent=2) + '\n')
for file in ['.github/workflows/full.yml', '.github/workflows/quick.yml']:
    path = ROOT / file
    text = path.read_text()
    for key, field in [('go', 'go-version'), ('node', 'node-version'), ('javaMajor', 'java-version')]:
        text = text.replace(f"{field}: '{pin[key]}'", f"{field}: '{proposed[key]}'")
    path.write_text(text)
(ROOT / 'scripts/ci/toolchain-update-candidates.json').write_text(json.dumps(candidates, indent=2) + '\n')
print('Stable runtime proposals and SDK/pnpm review candidates written; no downgrade, SDK replacement or auto-merge')
