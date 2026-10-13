#!/usr/bin/env python3
"""Validate and copy the reviewed, platform-independent pnpm license corpus."""
import ast
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PIN = ROOT / 'third_party/zashboard'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def lock_packages(lock):
    section = False
    names = []
    for line in lock.splitlines():
        if line == 'packages:':
            section = True
            continue
        if section and line and not line.startswith(' '):
            break
        if section and line.startswith('  ') and not line.startswith('    ') and line.endswith(':'):
            key = line[2:-1]
            if key.startswith(("'", '"')):
                key = ast.literal_eval(key)
            if not isinstance(key, str) or '@' not in key[1:]:
                raise ValueError('unrecognized pnpm package key')
            names.append(key)
    if not names or len(names) != len(set(names)):
        raise ValueError('missing or duplicate pnpm package keys')
    return set(names)


def reviewed_notices(pin=PIN):
    lock = (pin / 'pnpm-lock.yaml').read_bytes()
    corpus = json.loads((pin / 'dependency-notices.json').read_bytes())
    expected = lock_packages(lock.decode())
    actual = set()
    if corpus.get('schema') != 1 or corpus.get('lockSha256') != sha(lock) or corpus.get('scope') != 'all-locked-packages':
        raise ValueError('Zashboard license corpus does not match the locked dependency scope')
    for item in corpus.get('packages', []):
        key = item.get('key')
        if key in actual or key not in expected:
            raise ValueError('duplicate or unlisted Zashboard license package')
        actual.add(key)
        if not item.get('notices'):
            raise ValueError(f'missing license text for {key}')
        for notice in item['notices']:
            value = notice.get('text')
            if not isinstance(value, str) or not value.strip() or sha(value.encode()) != notice.get('sha256'):
                raise ValueError(f'missing or changed license text for {key}')
            if not notice.get('source'):
                raise ValueError(f'missing license source for {key}')
    if actual != expected:
        raise ValueError(f'license corpus does not cover locked packages: {sorted(expected - actual)}')
    return (json.dumps(corpus, ensure_ascii=False, indent=2) + '\n').encode()
