#!/usr/bin/env python3
"""Exercise the real build gate against a staged source change, without running the build."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = Path(sys.argv[1]).resolve()


def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)


with tempfile.TemporaryDirectory(prefix='zashboard-source-gate-') as temporary:
    temp = Path(temporary)
    host = temp / 'host'
    (host / 'scripts').mkdir(parents=True)
    shutil.copytree(ROOT / 'third_party', host / 'third_party')
    checkout = temp / 'source'
    result = run(['git', 'clone', '--shared', '--no-hardlinks', str(SOURCE), str(checkout)])
    assert result.returncode == 0, result.stderr
    result = run(['git', '-C', str(checkout), 'apply', '--unidiff-zero', str(host / 'third_party/zashboard/host.patch')])
    assert result.returncode == 0, result.stderr
    main = checkout / 'src/main.ts'
    main.write_text(main.read_text() + '\n// synthetic staged source mutation\n')
    assert run(['git', '-C', str(checkout), 'add', 'src/main.ts']).returncode == 0
    before = run(['git', '-C', str(checkout), 'diff', 'HEAD', '--binary']).stdout
    binary = temp / 'bin'
    binary.mkdir()
    pnpm = binary / 'pnpm'
    pnpm.write_text('#!/bin/sh\nif [ "$1" = --version ]; then echo 11.20.0; exit 0; fi\necho PNPM_BUILD_GATE_REACHED\nexit 88\n')
    pnpm.chmod(0o755)
    env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'])
    script = host / 'scripts/build-zashboard.sh'
    original = run(['git', '-C', str(ROOT), 'show', '2c0c1ed95c06f65770445a82f5afd59adb43376c:scripts/build-zashboard.sh'])
    assert original.returncode == 0, original.stderr
    script.write_text(original.stdout)
    old = run(['bash', str(script), str(checkout), '--offline'], env=env)
    assert old.returncode == 88 and 'PNPM_BUILD_GATE_REACHED' in old.stdout, old.stderr
    script.write_bytes((ROOT / 'scripts/build-zashboard.sh').read_bytes())
    fixed = run(['bash', str(script), str(checkout), '--offline'], env=env)
    assert fixed.returncode != 0 and 'Staged Zashboard source changes' in fixed.stderr, fixed.stderr
    assert 'PNPM_BUILD_GATE_REACHED' not in fixed.stdout
    assert run(['git', '-C', str(checkout), 'diff', 'HEAD', '--binary']).stdout == before
    print('PASS: 2c0c1ed staged-source bypass reproduced; fixed gate rejects before pnpm, preserving index/worktree')
