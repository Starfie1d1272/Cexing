#!/usr/bin/env bash
# Fetch only the reviewed panel identity into disposable source; never use user checkouts.
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
export PATH="$ROOT/scripts/ci/node_modules/.bin:$PATH"
PIN="$ROOT/third_party/zashboard/source.json"
SOURCE="$(mktemp -d)"
export XDG_DATA_HOME="$SOURCE/data" XDG_CACHE_HOME="$SOURCE/cache" XDG_CONFIG_HOME="$SOURCE/config"
trap 'rm -rf "$SOURCE"' EXIT
REPOSITORY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repository"])' "$PIN")"
SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha"])' "$PIN")"
CHECKOUT="$SOURCE/upstream"
mkdir "$CHECKOUT"
git -C "$CHECKOUT" init --quiet
git -C "$CHECKOUT" fetch --depth 1 "$REPOSITORY" "$SHA"
git -C "$CHECKOUT" checkout --quiet --detach FETCH_HEAD
bash scripts/build-zashboard.sh "$CHECKOUT"
# Generated identity must equal reviewed input; reject rather than accept a new bundle pin.
git diff --exit-code -- third_party/zashboard/manifest.json clash-openharmony/entry/src/main/ets/lib/ZashboardPin.ets
python3 scripts/zashboard-assets.py verify
