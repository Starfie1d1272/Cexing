#!/usr/bin/env bash
# 首次连接用的 GeoIP 快照；更新时同步来源日期与摘要。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"
URL=https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/4a2afc7ba1b88bff15c3f8f54a45fc6f9ed4bab3/geoip.metadb
SHA=b8f447617c3f6d8ef0f7528c23dfba695bca16a31a396bc4c1fca49e9f038ae3
OUT="$PROJECT_ROOT/entry/src/main/resources/rawfile/geodata/geoip.metadb"
if [ -f "$OUT" ] && [ "$(shasum -a 256 "$OUT" | awk '{print $1}')" = "$SHA" ]; then
  echo '[geodata] verified existing GeoIP snapshot'
  exit 0
fi
GEO_TEMP="$(mktemp)"
trap '[ ! -e "$GEO_TEMP" ] || rm "$GEO_TEMP"' EXIT
curl --fail --location --max-time 120 "$URL" -o "$GEO_TEMP"
[ "$(shasum -a 256 "$GEO_TEMP" | awk '{print $1}')" = "$SHA" ] || {
  echo '[geodata] SHA-256 mismatch; review the upstream snapshot before updating the pinned digest' >&2
  exit 1
}
mkdir -p "$(dirname "$OUT")"
mv "$GEO_TEMP" "$OUT"
echo '[geodata] GeoIP snapshot verified and staged'
