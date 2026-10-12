#!/usr/bin/env python3
"""Fail closed on the reviewed full-build tool combination; print no credentials."""
import json
import os
import pathlib
import re
import subprocess
import sys

pin = json.loads(pathlib.Path('scripts/ci/toolchain.json').read_text())
clt = pathlib.Path(os.environ['CLT_ROOT'])
sdk = pathlib.Path(os.environ['OHOS_SDK_HOME'])
def require(condition, message):
    if not condition:
        raise SystemExit('Toolchain mismatch: ' + message)
def package(file, version):
    require(json.loads(file.read_text())['version'] == version, file.name)
require(subprocess.check_output(['go', 'version'], text=True).split()[2] == 'go' + pin['go'], 'Go')
require(subprocess.check_output(['node', '--version'], text=True).strip() == 'v' + pin['node'], 'Node')
for variable in ['NODE_HOME', 'DEVECO_NODE_HOME']:
    if os.environ.get(variable):
        selected = pathlib.Path(os.environ[variable]) / 'bin/node'
        require(subprocess.check_output([str(selected), '--version'], text=True).strip() == 'v' + pin['node'], variable)
java = subprocess.check_output(['java', '-version'], stderr=subprocess.STDOUT, text=True)
require(re.search(r'version "' + pin['javaMajor'] + r'(?:[."]|$)', java), 'JDK')
require('Version: ' + pin['clt'] in (clt / 'version.txt').read_text(), 'official CLT')
for component in ['native', 'ets', 'toolchains']:
    data = json.loads((sdk / component / 'oh-uni-package.json').read_text())
    require(data['version'] == pin['sdk'] and str(data['apiVersion']) == pin['api'], component)
package(clt / 'ohpm/package.json', pin['ohpm'])
for component in ['hvigor', 'hvigor-ohos-plugin']:
    package(clt / 'hvigor' / component / 'package.json', pin['hvigor'])
require(not pathlib.Path('.signing').exists(), 'signing material must remain outside CI checkout')
if '--after-build' in sys.argv:
    home = pathlib.Path(os.environ['HVIGOR_USER_HOME'])
    packages = list((home / 'wrapper/tools').glob('*/node_modules/pnpm/package.json'))
    require(bool(packages), 'no wrapper pnpm inventory found')
    for file in packages:
        package(file, pin['pnpm'])
print('PASS: pinned ' + ('toolchain and wrapper' if '--after-build' in sys.argv else 'official toolchain'))
