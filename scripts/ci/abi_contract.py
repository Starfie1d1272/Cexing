#!/usr/bin/env python3
"""The four compatibility exports plus three extensions required by production."""
from pathlib import Path
import re

PROTOTYPES = {
    'mihomoInit': 'extern char* mihomoInit(char* homeDir);',
    'mihomoStartTun': 'extern char* mihomoStartTun(int fd, char* configJson, char* overridesJson);',
    'mihomoStop': 'extern void mihomoStop(void);',
    'mihomoFree': 'extern void mihomoFree(char* p);',
    'mihomoValidateOffline': 'extern char* mihomoValidateOffline(char* home, char* config, char* overrides);',
    'mihomoPreviewMerge': 'extern char* mihomoPreviewMerge(char* home, char* original, char* overlay, char* overrides);',
    'mihomoVersionAction': 'extern char* mihomoVersionAction(char* home, char* action);',
}


def check_header(text):
    for declaration in PROTOTYPES.values():
        if declaration not in text:
            raise ValueError('generated C ABI prototype: ' + declaration.split('(')[0])


def check_source(root):
    go = (root / 'core/main.go').read_text()
    bridge = (root / 'cexing/entry/src/main/cpp/bridge.cpp').read_text()
    exports = set(re.findall(r'^//export (mihomo\w+)$', go, re.M))
    required = set(PROTOTYPES)
    if exports != required:
        raise ValueError('Go C ABI export set differs from reviewed contract')
    if set(re.findall(r'dlsym\(h, "(mihomo\w+)"\)', bridge)) != required:
        raise ValueError('bridge production C ABI symbol set differs from Go exports')
    for declaration in [
        'typedef char *(*MihomoInitFn)(const char *);',
        'typedef char *(*MihomoStartTunFn)(int, const char *, const char *);',
        'typedef void (*MihomoStopFn)();', 'typedef void (*MihomoFreeFn)(char *);',
        'typedef char *(*MihomoValidateFn)(const char *, const char *, const char *);',
        'typedef char *(*MihomoPreviewFn)(const char *, const char *, const char *, const char *);',
        'typedef char *(*MihomoVersionFn)(const char *, const char *);',
    ]:
        if declaration not in bridge:
            raise ValueError('bridge C ABI function type drift')
    return required


if __name__ == '__main__':
    try:
        names = check_source(Path(__file__).resolve().parents[2])
    except ValueError as error:
        raise SystemExit(str(error)) from error
    print('PASS: four compatibility and three production extension C ABI exports/bridge types')
