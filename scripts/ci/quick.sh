#!/usr/bin/env bash
# Public dependencies only. ArkTS results are host mocks, not SDK compilation.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/test-zashboard-cache.py
python3 scripts/test-zashboard-prepare.py
python3 scripts/test-hap-clean.py
python3 scripts/ci/test-private-stderr.py
python3 scripts/ci/test-release.py
python3 scripts/update-routing-rules.py --verify
node scripts/ci/source-check.cjs
python3 scripts/ci/abi_contract.py
while IFS= read -r script; do bash -n "$script"; done < <(git ls-files 'scripts/*.sh' 'scripts/ci/*.sh')
git diff --check
python3 scripts/ci/test-gvisor-patch.py
python3 scripts/test-zashboard-notices.py
for test in scripts/test-*.cjs; do
  node "$test"
done
export GOFLAGS=-mod=readonly GOTOOLCHAIN=local
# A separate cache also protects Quick from legacy patched developer caches.
CI_GO_ROOT="$(mktemp -d)"
trap 'chmod -R u+w "$CI_GO_ROOT"; rm -rf "$CI_GO_ROOT"' EXIT
export GOMODCACHE="$CI_GO_ROOT/mod" GOCACHE="$CI_GO_ROOT/build"
# Reuse verified public archives between the original and Smart-patched caches.
# Extraction, patching and compilation remain isolated for each run.
export CI_GO_DOWNLOAD_CACHE="${CI_GO_DOWNLOAD_CACHE:-$CI_GO_ROOT/download}"
source scripts/ci/go-download-cache.sh
ci_seed_go_download_cache
(cd core && go mod download && go mod verify &&
  go test ../scripts/ci/compare-geosite.go ../scripts/ci/compare-geosite_test.go &&
  go test ../scripts/ci/replace-geosite.go ../scripts/ci/replace-geosite_test.go)
ci_save_go_download_cache
bash scripts/test-smart.sh
python3 scripts/ci/license-inventory.py > "$CI_GO_ROOT/licenses.json"
python3 - "$CI_GO_ROOT/licenses.json" <<'PYCODE'
import json, sys
print('PASS: notice inventory for', len(json.load(open(sys.argv[1]))['modules']), 'Go modules (not a legal review)')
PYCODE
echo 'PASS: Quick checks; no SDK/HAP or device validation was performed'
