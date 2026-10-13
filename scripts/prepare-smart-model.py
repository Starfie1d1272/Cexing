#!/usr/bin/env python3
"""Fetch the reviewed public Smart model into ignored rawfile resources."""
import hashlib
import json
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
PIN = ROOT / 'third_party/smart-model'
RAW = ROOT / 'cexing/entry/src/main/resources/rawfile/smart'
SOURCE = 'https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def identity():
    pin = json.loads((PIN / 'source.json').read_text())
    if pin['source'] != SOURCE or pin['assetSize'] != 9345218 or pin['assetSha256'] != '23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788':
        raise ValueError('unreviewed Smart model source or identity')
    license_data = (PIN / 'LICENSE').read_bytes()
    if sha(license_data) != pin['licenseSha256']:
        raise ValueError('Smart model GPL notice changed')
    return pin, license_data


def verify_model(model, pin):
    if not model.is_file() or model.is_symlink() or model.stat().st_size != pin['assetSize'] or sha(model.read_bytes()) != pin['assetSha256']:
        raise ValueError('bundled Smart model size or digest mismatch')


def verify():
    pin, license_data = identity()
    if not RAW.is_dir() or RAW.is_symlink() or {p.name for p in RAW.iterdir()} != {'Model.bin', 'LICENSE'}:
        raise ValueError('Smart model resource set changed')
    verify_model(RAW / 'Model.bin', pin)
    if (RAW / 'LICENSE').is_symlink() or (RAW / 'LICENSE').read_bytes() != license_data:
        raise ValueError('bundled Smart model notice changed')
    print(f'Verified official Smart model: {pin["assetSha256"]} ({pin["assetSize"]} bytes)')


def prepare():
    pin, license_data = identity()
    if RAW.is_symlink():
        raise ValueError('unsafe Smart model resource directory')
    RAW.mkdir(parents=True, exist_ok=True)
    model = RAW / 'Model.bin'
    try:
        verify_model(model, pin)
    except ValueError:
        with urllib.request.urlopen(SOURCE, timeout=60) as response:
            data = response.read(pin['assetSize'] + 1)
        if len(data) != pin['assetSize'] or sha(data) != pin['assetSha256']:
            raise ValueError('Smart model release asset size or digest mismatch')
        temp = RAW / 'Model.bin.tmp'
        if temp.is_symlink():
            raise ValueError('unsafe Smart model staging path')
        try:
            temp.write_bytes(data)
            temp.replace(model)
        finally:
            temp.unlink(missing_ok=True)
    (RAW / 'LICENSE').write_bytes(license_data)
    verify()


if __name__ == '__main__':
    verify() if sys.argv[1:] == ['--verify'] else prepare()
