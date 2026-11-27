#!/usr/bin/env python3
"""Propose newer stable runtimes in toolchain.json; report SDK/pnpm candidates in summary."""

import json
import os
import pathlib
import re
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
PIN = ROOT / "scripts/ci/toolchain.json"


def get(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)


def version(value):
    return tuple(int(x) for x in re.sub(r"^(go|v)", "", value).split("."))


pin = json.loads(PIN.read_text())
proposed = dict(pin)
go = [
    r["version"].removeprefix("go")
    for r in get("https://go.dev/dl/?mode=json")
    if r["stable"]
]
node = [
    r["version"].removeprefix("v")
    for r in get("https://nodejs.org/dist/index.json")
    if re.fullmatch(r"v\d+\.\d+\.\d+", r["version"])
]
java = pin["javaMajor"]
# Adoptium publishes stable releases in the official Temurin GitHub repositories.
# /releases/latest excludes prereleases; an unpublished next major returns 404.
for major in range(int(pin["javaMajor"]), int(pin["javaMajor"]) + 3):
    try:
        release = get(
            f"https://api.github.com/repos/adoptium/temurin{major}-binaries/releases/latest"
        )
    except urllib.error.HTTPError as error:
        if error.code == 404:
            continue
        raise
    if not release["prerelease"] and not release["draft"]:
        java = str(major)
for key, candidate in [
    ("go", max(go, key=version)),
    ("node", max(node, key=version)),
    ("javaMajor", java),
]:
    if version(candidate) > version(pin[key]):
        proposed[key] = candidate
# These need coordinated SDK API/plugin/wrapper or resource validation before
# changing the actual toolchain, so report them in the workflow summary without
# triggering candidate-only PRs.
sdk = get("https://api.github.com/repos/ErBWs/ohos-sdk/releases/latest")
pnpm = get("https://registry.npmjs.org/pnpm/latest")["version"]
summary_lines = [
    "### Toolchain update check",
    "",
    f"- Go: `{pin['go']}` -> `{proposed['go']}`",
    f"- Node: `{pin['node']}` -> `{proposed['node']}`",
    f"- JDK major: `{pin['javaMajor']}` -> `{proposed['javaMajor']}`",
    f"- SDK mirror latest (manual compatibility review): [{sdk['tag_name']}]({sdk['html_url']}) (pinned: `{pin['sdk']}`)",
    f"- pnpm latest (manual SDK/panel compatibility review): `{pnpm}` (pinned: `{pin['pnpm']}`)",
    "",
]
summary_text = "\n".join(summary_lines)
for env_name in ("GITHUB_STEP_SUMMARY", "CI_TOOLCHAIN_CANDIDATES_SUMMARY"):
    target = os.environ.get(env_name)
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(summary_text)
if proposed != pin:
    PIN.write_text(json.dumps(proposed, indent=2) + "\n")
print(summary_text)
print(
    "Checked stable runtime proposals and SDK/pnpm candidates; no downgrade, SDK replacement, workflow rewrite, or auto-merge"
)
