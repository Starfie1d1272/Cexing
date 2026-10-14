#!/usr/bin/env python3
"""Compile the production stderr capture on the host; no Go/OS VPN is started."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='cexing-stderr-') as tmp:
    binary = Path(tmp) / 'test'
    home = Path(tmp) / 'home'
    home.mkdir(mode=0o700)
    subprocess.run(['c++', '-std=c++14', '-Wall', '-Wextra', '-Werror', '-pthread',
                    '-I', str(root / 'cexing/entry/src/main/cpp'),
                    str(root / 'tests/privacy/stderr_capture_test.cpp'), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(home)], check=True, timeout=20)
print('PASS: native stderr privacy, flood/multiprocess bounds, aliases, expiry and real pipe capture')
