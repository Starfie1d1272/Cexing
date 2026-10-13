#!/usr/bin/env bash
# Source checkout must already be fetched. --offline uses an already populated pnpm store.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:?usage: build-zashboard.sh /path/to/zashboard-checkout [--offline|--reviewed]}"
SOURCE="$(cd "$SOURCE" && pwd)"
PIN="$ROOT/third_party/zashboard"
EXPECTED="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["sha"])' "$PIN/source.json")"
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$EXPECTED" ] || { echo 'Wrong Zashboard source SHA' >&2; exit 1; }
git -C "$SOURCE" diff --cached --quiet HEAD -- || {
  echo 'Staged Zashboard source changes are not allowed; use a separate clean checkout' >&2
  exit 1
}
cmp "$SOURCE/pnpm-lock.yaml" "$PIN/pnpm-lock.yaml"
cmp "$SOURCE/package.json" "$PIN/package.json"
if [ -n "$(git -C "$SOURCE" ls-files --others --exclude-standard)" ]; then
  echo 'Untracked source files could alter the bundle; use a separate clean checkout' >&2
  exit 1
fi
[ "$(pnpm --version)" = '11.20.0' ] || { echo 'Use locked pnpm 11.20.0' >&2; exit 1; }
# Only the reviewed host patch may differ from the pinned upstream source.
if git -C "$SOURCE" diff HEAD --quiet; then
  git -C "$SOURCE" apply --unidiff-zero "$PIN/host.patch"
fi
git -C "$SOURCE" diff HEAD --binary --unified=0 > "${TMPDIR:-/tmp}/zashboard-host-diff-$$"
trap 'rm -f "${TMPDIR:-/tmp}/zashboard-host-diff-$$"' EXIT
cmp "${TMPDIR:-/tmp}/zashboard-host-diff-$$" "$PIN/host.patch"
cd "$SOURCE"
ARGS=(install --frozen-lockfile)
PREPARE_ARGS=()
case "${2:-}" in
  --offline) ARGS+=(--offline) ;;
  --reviewed) PREPARE_ARGS+=(--reviewed) ;;
  '') ;;
  *) echo 'Unknown Zashboard build option' >&2; exit 1 ;;
esac
pnpm "${ARGS[@]}"
FONT=firasans pnpm run build
python3 "$ROOT/scripts/zashboard-assets.py" prepare "$SOURCE" "${PREPARE_ARGS[@]}"
