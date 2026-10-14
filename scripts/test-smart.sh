#!/usr/bin/env bash
# Quick may run without a model; Full supplies the verified bundled model path.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/test-smart-loader.sh
SMART_TEST_CACHE="$(mktemp -d)"
trap 'chmod -R u+w "$SMART_TEST_CACHE"; rm -rf "$SMART_TEST_CACHE"' EXIT
export GOMODCACHE="$SMART_TEST_CACHE/mod" GOFLAGS=-mod=readonly
source scripts/ci/go-download-cache.sh
ci_seed_go_download_cache
cd core
go mod download
go mod verify
ci_save_go_download_cache
python3 ../scripts/ci/patch-smart.py "$GOMODCACHE"
python3 ../scripts/ci/check-controller-contract.py
python3 ../scripts/ci/test-controller-contract.py
UPSTREAM="$(go list -m -f '{{.Replace.Dir}}' github.com/metacubex/mihomo)"
cp ../tests/smart/model_test.go.txt "$UPSTREAM/component/smart/lightgbm/ohos_beta_test.go"
cp ../tests/smart/api_test.go.txt "$UPSTREAM/hub/route/ohos_beta_test.go"
SMART_FIXTURE="$(pwd)/../experiments/smart-core/smart.yaml" go test github.com/metacubex/mihomo/component/smart/lightgbm github.com/metacubex/mihomo/hub/route -run '^TestOHOSBeta' -count=1 -v
go test -tags smartbeta ./... -count=1 -v
rm "$UPSTREAM/component/smart/lightgbm/ohos_beta_test.go" "$UPSTREAM/hub/route/ohos_beta_test.go"
python3 ../scripts/ci/patch-smart.py "$GOMODCACHE" restore
go mod verify
