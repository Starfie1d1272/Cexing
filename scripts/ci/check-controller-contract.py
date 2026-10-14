#!/usr/bin/env python3
"""Fail closed before compiling an unchecked private router ABI. No source is copied."""
import hashlib
import json
from pathlib import Path
import subprocess

PIN = ('github.com/vernesong/mihomo', 'v1.19.10-0.20261012020909-daf3ad03021c',
       'h1:23XrQ5vZacJbpvuIadl9FNjak2VXIQbzwXx+xU/OtME=')
PRISTINE_SHA = '01724bd82002cf80b85448ef664ca53a7cb82f529ccf2b7f4a6383282768d256'
BINDING = ('//go:linkname newMihomoControllerRouter github.com/metacubex/mihomo/hub/route.router\n'
           'func newMihomoControllerRouter(bool, string, string, route.Cors) *chi.Mux')


def check(module, source, binding):
    if tuple(module.get(key) for key in ('Path', 'Version', 'Sum')) != PIN:
        raise ValueError('Controller private router upstream identity drift')
    # Accept only the pristine source plus the one reviewed Smart route insertion.
    # Checking the entire file covers router signature, Cors layout and auth wiring.
    insertion = b'\t\taddOHOSSmartRoutes(r, secret)\n'
    if source.count(insertion) != 1:
        raise ValueError('Controller Smart router patch missing or duplicated')
    if hashlib.sha256(source.replace(insertion, b'')).hexdigest() != PRISTINE_SHA:
        raise ValueError('Controller private router source/signature drift')
    if BINDING not in binding:
        raise ValueError('Controller private router wrapper signature drift')


if __name__ == '__main__':
    try:
        module = json.loads(subprocess.check_output(
            ['go', 'list', '-m', '-json', 'github.com/metacubex/mihomo'], text=True))['Replace']
        source = (Path(module['Dir']) / 'hub/route/server.go').read_bytes()
        binding = Path('controller_listener.go').read_text()
        check(module, source, binding)
    except (ValueError, KeyError) as error:
        raise SystemExit(str(error)) from error
    print('PASS: pinned Controller private router source, Smart insertion and wrapper ABI')
