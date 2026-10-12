#!/usr/bin/env python3
"""Inventory available module notices; existence does not establish distribution compliance."""
import hashlib
import json
import pathlib
import subprocess

text = subprocess.check_output(['go', 'list', '-m', '-json', 'all'], cwd='core', text=True)
decoder = json.JSONDecoder()
modules, missing, not_downloaded, nested_only = [], [], [], []
while text.strip():
    obj, end = decoder.raw_decode(text.lstrip())
    text = text.lstrip()[end:]
    if obj.get('Main'):
        continue
    if obj.get('Replace'):
        replacement = obj['Replace']
        if (obj['Path'], replacement['Path'], replacement['Version'], replacement.get('Sum')) != (
            'github.com/metacubex/mihomo', 'github.com/vernesong/mihomo',
            'v1.19.10-0.20261012020909-daf3ad03021c', 'h1:23XrQ5vZacJbpvuIadl9FNjak2VXIQbzwXx+xU/OtME='):
            raise SystemExit('Unreviewed module replacement: ' + obj['Path'])
        obj = replacement
    if not obj.get('Dir'):
        not_downloaded.append({'path': obj['Path'], 'version': obj['Version']})
        continue
    directory = pathlib.Path(obj['Dir'])
    notices = []
    for file in sorted(directory.rglob("*")):
        if file.is_file() and file.name.lower().startswith(('license', 'licence', 'copying', 'notice')):
            notices.append({'name': file.relative_to(directory).as_posix(), 'sha256': hashlib.sha256(file.read_bytes()).hexdigest()})
    if not notices:
        missing.append(obj['Path'])
    elif all('/' in n['name'] for n in notices):
        nested_only.append(obj['Path'])
    modules.append({'path': obj['Path'], 'version': obj['Version'], 'sum': obj.get('Sum'), 'notices': notices})
print(json.dumps({'modules': modules, 'missingNotice': missing, 'nestedNoticesOnly': nested_only,
                  'graphModulesNotDownloaded': not_downloaded,
                  'distributionApproval': False}, indent=2))
if missing:
    raise SystemExit('Missing module notices: ' + ', '.join(missing))
