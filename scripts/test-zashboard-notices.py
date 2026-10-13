#!/usr/bin/env python3
"""Check locked notice identity and fail-closed behavior with synthetic packages."""
import hashlib
import json
import tempfile
from pathlib import Path

import zashboard_notices


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


with tempfile.TemporaryDirectory() as temporary:
    pin = Path(temporary)
    lock = "packages:\n  'alpha@1.0.0':\n    resolution:\n      integrity: sha512-example\n  'beta@2.0.0':\n    resolution:\n      integrity: sha512-example\nsnapshots:\n"
    (pin / 'pnpm-lock.yaml').write_text(lock)
    corpus = {'schema': 1, 'scope': 'all-locked-packages', 'lockSha256': digest(lock), 'packages': [
        {'key': name, 'license': 'MIT', 'notices': [
            {'file': 'LICENSE', 'source': 'synthetic:LICENSE', 'sha256': digest(name), 'text': name}
        ]} for name in ('alpha@1.0.0', 'beta@2.0.0')
    ]}

    def check():
        (pin / 'dependency-notices.json').write_text(json.dumps(corpus))
        return zashboard_notices.reviewed_notices(pin)

    baseline = check()
    assert baseline == check(), 'notice bytes must not vary by installation platform'
    for changed in ({'notices': []}, {'key': 'unlisted@1.0.0'}):
        original = corpus['packages'][0].copy()
        corpus['packages'][0].update(changed)
        try:
            check()
        except ValueError:
            pass
        else:
            raise AssertionError('missing or unlisted license entry accepted')
        corpus['packages'][0] = original
    corpus['packages'][0]['notices'][0]['text'] = 'changed'
    try:
        check()
    except ValueError:
        pass
    else:
        raise AssertionError('changed license text accepted')

print('PASS: lock-scoped deterministic notices and missing/changed license rejection')
assert len(zashboard_notices.lock_packages((zashboard_notices.PIN / 'pnpm-lock.yaml').read_text())) == 702
assert zashboard_notices.reviewed_notices() == zashboard_notices.reviewed_notices()
corpus = json.loads((zashboard_notices.PIN / 'dependency-notices.json').read_text())
natural = next(item for item in corpus['packages'] if item['key'] == 'natural-compare@1.4.0')
notice = natural['notices'][0]
assert 'Copyright (c) 2012-2015 Lauri Rooden <lauri@rooden.ee>' in notice['text']
assert notice['attributionSource'] == 'npm:natural-compare@1.4.0:README.md'
assert notice['attributionSourceSha256'] == 'ced6cb1fe6ee15a32c63ea8c7e0425454e80456a890c6df3909429530566d40a'
print('PASS: complete reviewed Zashboard lock corpus (702 packages)')
