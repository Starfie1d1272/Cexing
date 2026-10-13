#!/usr/bin/env bash
# Public dependencies only. ArkTS results are host mocks, not SDK compilation.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 scripts/test-zashboard-cache.py
python3 scripts/test-zashboard-prepare.py
python3 scripts/test-hap-clean.py
node scripts/ci/source-check.cjs
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
(cd core && go mod download && go mod verify)
bash scripts/test-smart.sh
python3 scripts/ci/license-inventory.py > "$CI_GO_ROOT/licenses.json"
python3 - "$CI_GO_ROOT/licenses.json" <<'PYCODE'
import json, sys
print('PASS: notice inventory for', len(json.load(open(sys.argv[1]))['modules']), 'Go modules (not a legal review)')
PYCODE
echo 'PASS: Quick checks; no SDK/HAP or device validation was performed'
