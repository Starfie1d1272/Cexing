#!/usr/bin/env python3
"""Run both production entry scripts with tool boundaries mocked, count required clean."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='hap-clean-') as temporary:
    host = Path(temporary)
    scripts = host / 'scripts'
    ci = scripts / 'ci'
    ci.mkdir(parents=True)
    for name in ['build-hap.sh', 'ci/full.sh', 'ci/timed.py']:
        shutil.copyfile(ROOT / 'scripts' / name, scripts / name)
    project = host / 'cexing'
    (project / 'entry/src/main/resources/rawfile/geodata').mkdir(parents=True)
    (project / 'entry/src/main/resources/rawfile/geodata/geoip.metadb').touch()
    (host / 'core').mkdir()
    (host / 'third_party/zashboard').mkdir(parents=True)
    (host / 'third_party/zashboard/source.json').write_text('{}')
    (host / 'tests/smart').mkdir(parents=True)
    tools = host / 'tools'
    tools.mkdir()
    (scripts / 'env.sh').write_text('''export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT="$REPO_ROOT/cexing" CLT_ROOT="$REPO_ROOT/tools"
export PATH="$REPO_ROOT/tools:$PATH"
''')
    (ci / 'prepare-zashboard.sh').write_text('''echo prepare >> "$REPO_ROOT/events"
[ ! -f "$REPO_ROOT/reject-prepare" ]
''')
    (ci / 'go-download-cache.sh').write_text('ci_seed_go_download_cache() { :; }; ci_save_go_download_cache() { :; }\n')
    for name in ['test-smart.sh', 'build-core.sh', 'prepare-geodata.sh']:
        (scripts / name).write_text(':\n')
    for name in ['update-routing-rules.py', 'prepare-smart-model.py', 'zashboard-assets.py', 'ci/check-toolchain.py',
                 'ci/test-private-stderr.py', 'ci/test-release.py', '../tests/smart/hap_gate.py', '../tests/smart/source_gate.py']:
        (scripts / name).write_text('')
    (ci / 'toolchain.json').write_text('{"pnpm": "synthetic"}')
    (ci / 'hvigor-wrapper').mkdir()
    (ci / 'hvigor-wrapper/package.json').write_text('{}')
    (ci / 'license-inventory.py').write_text('import pathlib,sys\npathlib.Path(sys.argv[1]).write_text("synthetic notice")\nprint("{}")\n')
    (ci / 'verify-hap.py').write_text('import pathlib,sys\npathlib.Path(sys.argv[2]).mkdir(parents=True)\n')
    for name in ['git', 'node', 'go', 'npm']:
        path = tools / name
        path.write_text('#!/bin/bash\nexit 0\n')
        path.chmod(0o755)
    (tools / 'ohpm/bin').mkdir(parents=True)
    ohpm = tools / 'ohpm/bin/ohpm'
    ohpm.write_text('#!/bin/bash\nexit 0\n')
    ohpm.chmod(0o755)
    hvigor = tools / 'hvigorw'
    hvigor.write_text('''#!/bin/bash
set -eu
echo "$1" >> "$REPO_ROOT/events"
if [ "$1" = assembleHap ]; then
  mkdir -p entry/build/default/outputs/default
  touch entry/build/default/outputs/default/entry-default-unsigned.hap
fi
''')
    hvigor.chmod(0o755)
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'])
    for entry in ['build-hap.sh', 'ci/full.sh']:
        result = subprocess.run(['bash', str(scripts / entry)], cwd=host, env=env, text=True, capture_output=True)
        assert result.returncode == 0, result.stdout + result.stderr
        events = (host / 'events').read_text().splitlines()
        assert events.count('clean') == 1 and events.count('assembleHap') == 1, (entry, events)
        assert events.index('prepare') < events.index('clean') < events.index('assembleHap'), events
        assert '"phase": "hvigor-clean"' in result.stdout, result.stdout
        (host / 'events').unlink()
    (host / 'reject-prepare').touch()
    result = subprocess.run(['bash', str(scripts / 'build-hap.sh')], cwd=host, env=env, capture_output=True)
    assert result.returncode != 0
    assert (host / 'events').read_text().splitlines() == ['prepare']
print('PASS: real direct build-hap and Full each clean exactly once after prepare, timed logging and prepare failure stops packaging')
