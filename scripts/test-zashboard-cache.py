#!/usr/bin/env python3
"""Check asset-cache refresh and failure preservation with isolated build tools."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def check(initial, failure=None):
    with tempfile.TemporaryDirectory(prefix='zashboard-cache-') as temporary:
        host = Path(temporary)
        scripts = host / 'scripts'
        (scripts / 'ci').mkdir(parents=True)
        shutil.copyfile(ROOT / 'scripts/ci/prepare-zashboard.sh', scripts / 'ci/prepare-zashboard.sh')
        pin = host / 'third_party/zashboard'
        pin.mkdir(parents=True)
        (pin / 'source.json').write_text(json.dumps({'repository': 'synthetic:panel', 'sha': 'synthetic-sha'}))
        raw = host / 'cexing/entry/src/main/resources/rawfile/zashboard'
        raw.mkdir(parents=True)
        (raw / initial).touch()
        if failure:
            (host / failure).touch()
        (scripts / 'zashboard-assets.py').write_text(
            'from pathlib import Path\nimport sys\n'
            "sys.exit(0 if Path('cexing/entry/src/main/resources/rawfile/zashboard/valid').exists() else 1)\n")
        (scripts / 'build-zashboard.sh').write_text('''#!/bin/bash
set -eu
touch build-called
[ -e cexing/entry/src/main/resources/rawfile/zashboard/stale ]
[ ! -e build-failure ] || exit 86
rm cexing/entry/src/main/resources/rawfile/zashboard/stale
touch cexing/entry/src/main/resources/rawfile/zashboard/valid
''')
        tools = host / 'tools'
        tools.mkdir()
        git = tools / 'git'
        git.write_text('''#!/bin/bash
set -eu
if [[ "$*" == *fetch* && -e fetch-failure ]]; then exit 85; fi
''')
        git.chmod(0o755)
        result = subprocess.run(['bash', str(scripts / 'ci/prepare-zashboard.sh')], cwd=host,
                                env=dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH']),
                                text=True, capture_output=True)
        if failure:
            assert result.returncode != 0, result.stdout
            assert (raw / 'stale').exists() and not (raw / 'valid').exists()
        else:
            assert result.returncode == 0, result.stdout + result.stderr
            assert (raw / 'valid').exists()
            assert (host / 'build-called').exists() == (initial == 'stale')


check('valid')
check('stale')
check('stale', 'fetch-failure')
check('stale', 'build-failure')
print('PASS: valid cache reuse, stale cache refresh, fetch/build failure propagation and cache preservation')
