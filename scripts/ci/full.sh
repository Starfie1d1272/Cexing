#!/usr/bin/env bash
# Run only in a trusted clean checkout with an authorized official SDK.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  echo 'Full requires a clean committed checkout so its recorded tree matches all inputs' >&2
  exit 1
fi
source scripts/env.sh
python3 scripts/ci/check-toolchain.py
node scripts/ci/source-check.cjs
if [ -f third_party/zashboard/source.json ]; then
  bash scripts/ci/prepare-zashboard.sh
fi
CI_BUILD_ROOT="$(mktemp -d)"
trap 'chmod -R u+w "$CI_BUILD_ROOT"; rm -rf "$CI_BUILD_ROOT"' EXIT
export GOMODCACHE="$CI_BUILD_ROOT/mod" GOCACHE="$CI_BUILD_ROOT/go-build"
export GOTOOLCHAIN=local GOFLAGS=-mod=readonly
export HVIGOR_USER_HOME="$CI_BUILD_ROOT/hvigor"
export npm_config_cache="$CI_BUILD_ROOT/npm"
# Optional seed is ONLY public wrapper/tools; never copy accounts or settings.
if [ -n "${CI_HVIGOR_WRAPPER_TOOLS:-}" ]; then
  mkdir -p "$HVIGOR_USER_HOME/wrapper"
  cp -R "$CI_HVIGOR_WRAPPER_TOOLS" "$HVIGOR_USER_HOME/wrapper/tools"
fi
(cd core && go mod download && go mod verify)
bash scripts/test-smart.sh
python3 scripts/ci/license-inventory.py > "$CI_BUILD_ROOT/licenses.json"
for test in scripts/test-*.cjs; do node "$test"; done
(cd clash-openharmony && "$CLT_ROOT/ohpm/bin/ohpm" install)
bash scripts/build-core.sh
(cd core && go mod verify)
bash scripts/prepare-geodata.sh
(cd clash-openharmony && hvigorw clean --no-daemon)
bash scripts/build-hap.sh
python3 scripts/ci/check-toolchain.py --after-build
HAP=clash-openharmony/entry/build/default/outputs/default/entry-default-unsigned.hap
REPORT=clash-openharmony/dist/ci
python3 scripts/ci/verify-hap.py "$HAP" "$REPORT"
python3 tests/smart/hap_gate.py
python3 tests/smart/source_gate.py
cp "$CI_BUILD_ROOT/licenses.json" "$REPORT/module-notices.json"
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  echo 'Full changed tracked inputs or generated untracked files; review before accepting identity' >&2
  exit 1
fi
echo "PASS: Full unsigned build; reports in $REPORT; no signing, publishing or device operations"
