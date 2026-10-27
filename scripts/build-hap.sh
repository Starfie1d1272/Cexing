#!/usr/bin/env bash
# 构建 HAP(未签名) — 用法: bash scripts/build-hap.sh [release]
set -e
source "$(dirname "$0")/env.sh"
python3 "$REPO_ROOT/scripts/update-routing-rules.py" --verify --prepare-notices
bash "$REPO_ROOT/scripts/ci/prepare-zashboard.sh"
python3 "$REPO_ROOT/scripts/prepare-smart-model.py" --verify
[ -f "$PROJECT_ROOT/entry/src/main/resources/rawfile/geodata/geoip.metadb" ] || {
  echo '[build-hap] Missing GeoIP snapshot; run bash scripts/prepare-geodata.sh first' >&2
  exit 1
}
[ -f "$PROJECT_ROOT/entry/src/main/resources/rawfile/geodata/geosite.dat" ] || {
  echo '[build-hap] Missing GeoSite snapshot; run bash scripts/prepare-geodata.sh first' >&2
  exit 1
}
cd "$PROJECT_ROOT"
# This entry owns the single required clean for both direct builds and Full.
python3 "$REPO_ROOT/scripts/ci/timed.py" hvigor-clean hvigorw clean --no-daemon
MODE="${1:-debug}"
if [ "$MODE" = "release" ]; then
  hvigorw assembleHap -p buildMode=release --no-daemon
else
  hvigorw assembleHap --no-daemon
fi
echo "--- 产物 ---"
ls -lh "$PROJECT_ROOT"/entry/build/default/outputs/default/*.hap
python3 "$REPO_ROOT/scripts/zashboard-assets.py" verify "$PROJECT_ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"
