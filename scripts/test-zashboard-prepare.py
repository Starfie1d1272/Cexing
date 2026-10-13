#!/usr/bin/env python3
"""Exercise the production prepare and wrapper with real staged bytes and failed writes."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('assets', ROOT / 'scripts/zashboard-assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


def snapshot(host):
    paths = [host / 'cexing/entry/src/main/resources/rawfile/zashboard',
             host / 'third_party/zashboard/manifest.json',
             host / 'cexing/entry/src/main/ets/lib/ZashboardPin.ets']
    result = {}
    for path in paths:
        if path.is_dir():
            result.update({p.relative_to(host).as_posix(): p.read_bytes()
                           for p in path.rglob('*') if p.is_file()})
        elif path.exists():
            result[path.relative_to(host).as_posix()] = path.read_bytes()
    return result


with tempfile.TemporaryDirectory(prefix='real-zashboard-prepare-') as temporary:
    host = Path(temporary)
    pin = host / 'third_party/zashboard'
    shutil.copytree(ROOT / 'third_party/zashboard', pin)
    raw = host / 'cexing/entry/src/main/resources/rawfile/zashboard'
    ets = host / 'cexing/entry/src/main/ets/lib/ZashboardPin.ets'
    ets.parent.mkdir(parents=True)
    source = host / 'source'
    (source / 'dist/assets').mkdir(parents=True)
    for name in ['pnpm-lock.yaml', 'package.json']:
        shutil.copyfile(pin / name, source / name)
    font = source / 'node_modules/@fontsource/fira-sans'
    font.mkdir(parents=True)
    (font / 'LICENSE').write_text('synthetic font license fixture')
    (source / 'dist/index.html').write_text('<html>synthetic panel A</html>')
    (source / 'dist/assets/font.woff2').write_bytes(b'synthetic local font')
    with patch.multiple(assets, ROOT=host, PIN=pin, RAW=raw):
        assets.prepare(source)
        assets.verify()
        original = snapshot(host)
        assets.prepare(source, reviewed=True)
        assert snapshot(host) == original
        (source / 'dist/index.html').write_text('<html>synthetic panel B</html>')
        try:
            assets.prepare(source, reviewed=True)
        except ValueError as error:
            assert 'reviewed manifest/pin' in str(error)
        else:
            raise AssertionError('final reviewed identity mismatch was accepted')
        assert snapshot(host) == original
        (source / 'dist/index.html').write_text('<html>synthetic panel A</html>')
        ets.write_text('synthetic reviewed Pin mismatch')
        pin_mismatch = snapshot(host)
        try:
            assets.prepare(source, reviewed=True)
        except ValueError as error:
            assert 'reviewed manifest/pin' in str(error)
        else:
            raise AssertionError('Pin-only mismatch was accepted')
        assert snapshot(host) == pin_mismatch
        ets.write_bytes(original[ets.relative_to(host).as_posix()])
        (source / 'dist/index.html').write_text('<html>synthetic panel B</html>')
        # Fail every staged identity write before any live path is changed.
        write_bytes = Path.write_bytes
        for basename in ['dependency-notices.json', 'manifest.json', 'ZashboardPin.ets']:
            def fail_write(path, data):
                if path.name == basename and '.zashboard-prepare-' in str(path):
                    raise OSError('synthetic staged write failure')
                return write_bytes(path, data)
            with patch.object(Path, 'write_bytes', fail_write):
                try:
                    assets.prepare(source)
                except OSError:
                    pass
                else:
                    raise AssertionError('staged write failure was swallowed')
            assert snapshot(host) == original, basename
        # Fail each live replacement after its old path has been backed up.
        rename = Path.rename
        for target in [raw, pin / 'manifest.json', ets]:
            failed = []
            def fail_replace(path, destination):
                if Path(destination) == target and '.zashboard-prepare-' in str(path) and not failed:
                    failed.append(True)
                    raise OSError('synthetic replacement failure')
                return rename(path, destination)
            with patch.object(Path, 'rename', fail_replace):
                try:
                    assets.prepare(source)
                except OSError:
                    pass
                else:
                    raise AssertionError('replacement failure was swallowed')
            assert failed and snapshot(host) == original, target
        # An old-path backup failure after earlier replacements must also restore all bytes.
        for target in [raw, pin / 'manifest.json', ets]:
            failed = []
            def fail_backup(path, destination):
                if path == target and Path(destination).name == 'previous' and not failed:
                    failed.append(True)
                    raise OSError('synthetic backup failure')
                return rename(path, destination)
            with patch.object(Path, 'rename', fail_backup):
                try:
                    assets.prepare(source)
                except OSError:
                    pass
                else:
                    raise AssertionError('backup failure was swallowed')
            assert failed and snapshot(host) == original, target
        assert not list(host.rglob('.zashboard-backup-*'))
        assert not list(host.rglob('.zashboard-prepare-*'))
        assets.prepare(source)
        assets.verify()
        assert snapshot(host) != original
        updated = snapshot(host)
        assets.prepare(source, reviewed=True)
        assert snapshot(host) == updated
        # Also run the actual cache-refresh shell and production CLI together.
        scripts = host / 'scripts'
        (scripts / 'ci').mkdir(parents=True)
        for name in ['zashboard-assets.py', 'zashboard_notices.py']:
            shutil.copyfile(ROOT / 'scripts' / name, scripts / name)
        shutil.copyfile(ROOT / 'scripts/ci/prepare-zashboard.sh', scripts / 'ci/prepare-zashboard.sh')
        (scripts / 'build-zashboard.sh').write_text('''#!/bin/bash
set -eu
touch build-called
python3 scripts/zashboard-assets.py prepare source "$2"
''')
        tools = host / 'tools'
        tools.mkdir()
        git = tools / 'git'
        git.write_text('#!/bin/bash\nexit 0\n')
        git.chmod(0o755)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'])
        def run_wrapper():
            return subprocess.run(['bash', str(scripts / 'ci/prepare-zashboard.sh')],
                                  cwd=host, env=env, text=True, capture_output=True)
        result = run_wrapper()
        assert result.returncode == 0, result.stdout + result.stderr
        assert not (host / 'build-called').exists(), 'valid cache must not build'
        # Exact reviewed output repairs a stale cache without changing either tracked identity.
        (raw / 'index.html').write_text('synthetic damaged cache')
        result = run_wrapper()
        assert result.returncode == 0, result.stdout + result.stderr
        assert snapshot(host) == updated
        (raw / 'index.html').write_text('last available cache bytes')
        (source / 'dist/index.html').write_text('<html>synthetic unreviewed panel C</html>')
        before = snapshot(host)
        result = run_wrapper()
        assert result.returncode != 0 and 'reviewed manifest/pin' in result.stderr, result.stdout + result.stderr
        assert snapshot(host) == before, 'real wrapper final identity failure changed live bytes'
        # First preparation failure creates no RAW or tracked identity replacement.
        shutil.rmtree(raw)
        before = snapshot(host)
        result = run_wrapper()
        assert result.returncode != 0 and not raw.exists()
        assert snapshot(host) == before
print('PASS: production staging/identity validation, real wrapper valid/stale/missing cache, final identity failure, staged write failures and rollback at all three live replacements')
