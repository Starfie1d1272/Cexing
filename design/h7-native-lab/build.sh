#!/usr/bin/env bash
# Build variants in a disposable copy; never install or alter the product manifest.
set -euo pipefail
LAB_ROOT="$(cd "$(dirname "$0")" && pwd)"
REPOSITORY_ROOT="$(cd "$LAB_ROOT/../.." && pwd)"
STATE="${1:-default}"
case "$STATE" in default|enable|disable) ;; *) echo 'usage: build.sh [default|enable|disable]' >&2; exit 1;; esac
source "$REPOSITORY_ROOT/scripts/env.sh"
LAB_COPY="$(mktemp -d)"
trap 'rm -rf "$LAB_COPY"' EXIT
python3 - "$LAB_ROOT" "$LAB_COPY" "$STATE" <<'PY'
import pathlib, shutil, json, sys
src, dst, state = sys.argv[1:]
shutil.copytree(src, dst, dirs_exist_ok=True,
                ignore=shutil.ignore_patterns('oh_modules', '.hvigor', 'build', '*.log'))
p = pathlib.Path(dst)/'entry/src/main/module.json5'
d = json.loads(p.read_text())
d['module']['metadata'][0]['value'] = state
p.write_text(json.dumps(d, indent=2))
PY
cd "$LAB_COPY"
"$CLT_ROOT/ohpm/bin/ohpm" install
hvigorw assembleHap --no-daemon
mkdir -p "$REPOSITORY_ROOT/.h7-lab-output"
cp entry/build/default/outputs/default/entry-default-unsigned.hap "$REPOSITORY_ROOT/.h7-lab-output/$STATE.hap"
sha256sum "$REPOSITORY_ROOT/.h7-lab-output/$STATE.hap"
