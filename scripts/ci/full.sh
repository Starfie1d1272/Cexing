#!/usr/bin/env bash
# Run only in a trusted clean checkout with an authorized official SDK.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  echo 'Full requires a clean committed checkout so its recorded tree matches all inputs' >&2
  exit 1
fi
# Clear old success before any toolchain preflight; failure never inherits a HAP.
rm -rf clash-openharmony/dist/ci
rm -f clash-openharmony/entry/build/default/outputs/default/entry-default-unsigned.hap
source scripts/env.sh
python3 scripts/ci/check-toolchain.py
node scripts/ci/source-check.cjs
if [ -f third_party/zashboard/source.json ]; then
  python3 scripts/ci/timed.py zashboard bash scripts/ci/prepare-zashboard.sh
fi
CI_BUILD_ROOT="$(mktemp -d)"
trap 'chmod -R u+w "$CI_BUILD_ROOT"; rm -rf "$CI_BUILD_ROOT"' EXIT
export GOMODCACHE="$CI_BUILD_ROOT/mod" GOCACHE="$CI_BUILD_ROOT/go-build"
export GOTOOLCHAIN=local GOFLAGS=-mod=readonly
export HVIGOR_USER_HOME="$CI_BUILD_ROOT/hvigor"
export npm_config_cache="$CI_BUILD_ROOT/npm"
source scripts/ci/go-download-cache.sh
ci_seed_go_download_cache
# Optional seed is ONLY public wrapper/tools; never copy accounts or settings.
if [ -n "${CI_HVIGOR_WRAPPER_TOOLS:-}" ]; then
  mkdir -p "$HVIGOR_USER_HOME/wrapper"
  cp -R "$CI_HVIGOR_WRAPPER_TOOLS" "$HVIGOR_USER_HOME/wrapper/tools"
else
  # The vendor wrapper logs its pin but invokes floating `npm install pnpm`.
  # Seed that public tool with an integrity lock, without modifying the SDK.
  WRAPPER_PNPM="$(python3 -c 'import json; print(json.load(open("scripts/ci/toolchain.json"))["pnpm"])')"
  WRAPPER_TOOLS="$HVIGOR_USER_HOME/wrapper/tools/$WRAPPER_PNPM"
  mkdir -p "$WRAPPER_TOOLS"
  cp scripts/ci/hvigor-wrapper/package*.json "$WRAPPER_TOOLS/"
  python3 scripts/ci/timed.py wrapper-pnpm npm ci --prefix "$WRAPPER_TOOLS" --ignore-scripts --no-audit --no-fund
fi
python3 scripts/ci/timed.py go-download bash -c 'cd core && go mod download && go mod verify'
ci_save_go_download_cache
python3 scripts/ci/timed.py smart-tests bash scripts/test-smart.sh
python3 scripts/ci/license-inventory.py "$CI_BUILD_ROOT/GO-NOTICES.txt" > "$CI_BUILD_ROOT/licenses.json"
for test in scripts/test-*.cjs; do node "$test"; done
python3 scripts/ci/timed.py ohpm bash -c 'cd clash-openharmony && "$CLT_ROOT/ohpm/bin/ohpm" install'
python3 scripts/ci/timed.py mihomo-smart bash scripts/build-core.sh
(cd core && go mod verify)
python3 scripts/ci/timed.py geoip bash scripts/prepare-geodata.sh
python3 scripts/ci/timed.py hvigor-clean bash -c 'cd clash-openharmony && hvigorw clean --no-daemon'
python3 scripts/ci/timed.py napi-arkts-hap bash scripts/build-hap.sh
python3 scripts/ci/check-toolchain.py --after-build
HAP=clash-openharmony/entry/build/default/outputs/default/entry-default-unsigned.hap
REPORT=clash-openharmony/dist/ci
python3 scripts/ci/timed.py hap-validation python3 scripts/ci/verify-hap.py "$HAP" "$REPORT"
python3 tests/smart/hap_gate.py
python3 tests/smart/source_gate.py
cp "$CI_BUILD_ROOT/licenses.json" "$REPORT/module-notices.json"
cp "$CI_BUILD_ROOT/GO-NOTICES.txt" "$REPORT/GO-NOTICES.txt"
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  echo 'Full changed tracked inputs or generated untracked files; review before accepting identity' >&2
  exit 1
fi
echo "PASS: Full unsigned build; reports in $REPORT; no signing, publishing or device operations"
