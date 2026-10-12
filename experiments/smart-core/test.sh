#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export GOMODCACHE="$HERE/.work/modcache"
export GOCACHE="$HERE/.work/buildcache"
export GOFLAGS=-mod=readonly
cp "$HERE/tests/offline_model_test.go.txt" "$HERE/.work/upstream/component/smart/lightgbm/ohos_offline_model_test.go"
cd "$HERE/.work/stage/core"
go test github.com/metacubex/mihomo/component/smart/lightgbm -run '^TestOHOSOfflineModel$' -count=1 -v
cp "$HERE/tests/smart_api_test.go.txt" "$HERE/.work/upstream/hub/route/ohos_smart_api_test.go"
SMART_FIXTURE="$HERE/smart.yaml" go test github.com/metacubex/mihomo/hub/route -run '^TestOHOSSmartAPI$' -count=1 -v
