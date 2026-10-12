#!/usr/bin/env bash
# Isolated research build; never writes production core or entry/libs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASE=7f731d5c9c8d4eba7a1680bcb3981d7877232bcc
WORK="$HERE/.work"
export GOMODCACHE="$WORK/modcache"
export GOCACHE="$WORK/buildcache"
export GOFLAGS=-mod=readonly
mkdir -p "$WORK/stage/core" "$WORK/stage/scripts"
# Fixed host/worker baseline: unrelated concurrent work cannot enter this experiment.
git -C "$ROOT" archive "$BASE" core scripts clash-openharmony | tar -x -C "$WORK/stage"
cp "$HERE/go.mod" "$HERE/go.sum" "$WORK/stage/core/"
cd "$WORK/stage/core"
go mod download
python3 "$HERE/restore-gvisor.py"
go mod verify
go mod download -json github.com/metacubex/mihomo > "$WORK/upstream-module.json"
UPSTREAM="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Dir"])' "$WORK/upstream-module.json")"
# Preserve verified module cache; patch a private source copy instead.
mkdir -p "$WORK/upstream"
cp -a "$UPSTREAM/." "$WORK/upstream/"
chmod -R u+w "$WORK/upstream"
patch --batch --forward -d "$WORK/upstream" -p1 < "$HERE/offline-model.patch"
go mod edit -replace "github.com/metacubex/mihomo=$WORK/upstream"
# env.sh requires the toolchain under its staged root unless overridden.
export HARMONYOS_CLT_ROOT="${HARMONYOS_CLT_ROOT:-$ROOT/command-line-tools}"
bash "$WORK/stage/scripts/build-core.sh"
go version -m "$WORK/stage/clash-openharmony/entry/libs/arm64-v8a/libmihomo.so" > "$WORK/build-info.txt"
python3 "$HERE/verify.py" "$ROOT" "$WORK"
if [[ "${1:-}" == hap ]]; then
  source "$WORK/stage/scripts/env.sh"
  (cd "$PROJECT_ROOT" && "$CLT_ROOT/ohpm/bin/ohpm" install)
  bash "$WORK/stage/scripts/prepare-geodata.sh"
  (cd "$PROJECT_ROOT" && hvigorw clean --no-daemon)
  bash "$WORK/stage/scripts/build-hap.sh"
  python3 "$HERE/verify.py" "$ROOT" "$WORK" hap
fi
