#!/usr/bin/env python3
"""Negative upgrade fixtures against the downloaded, patched real core."""
import importlib.util
import json
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('contract', Path(__file__).with_name('check-controller-contract.py'))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
module = json.loads(subprocess.check_output(
    ['go', 'list', '-m', '-json', 'github.com/metacubex/mihomo'], text=True))['Replace']
source = (Path(module['Dir']) / 'hub/route/server.go').read_bytes()
binding = Path('controller_listener.go').read_text()
contract.check(module, source, binding)
for name, candidate, text, wrapper in [
    ('upstream pin', dict(module, Version='v0.0.0'), source, binding),
    ('router parameter', module, source.replace(b'isDebug bool', b'isDebug int'), binding),
    ('Cors layout', module, source.replace(b'AllowPrivateNetwork bool', b'AllowPrivateNetwork int'), binding),
    ('missing patch', module, source.replace(b'\t\taddOHOSSmartRoutes(r, secret)\n', b''), binding),
    ('wrapper ABI', module, source, binding.replace('func newMihomoControllerRouter(bool,', 'func newMihomoControllerRouter(int,')),
]:
    try:
        contract.check(candidate, text, wrapper)
    except ValueError:
        print('PASS: rejected ' + name + ' drift')
    else:
        raise SystemExit('FAIL: accepted ' + name + ' drift')
