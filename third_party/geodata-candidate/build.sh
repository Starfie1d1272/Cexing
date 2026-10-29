#!/usr/bin/env bash
# Build GeoIP from fixed, verified inputs.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
[ "$#" -eq 1 ] || { echo 'usage: bash build.sh OUTPUT-DIRECTORY' >&2; exit 2; }
mkdir -p "$1"
out="$(cd "$1" && pwd)"
cd "$root"
sha256sum --check SHA256SUMS
python3 build.py "$out/geoip.dat" > "$out/category-counts.txt"
toolsrc="$(mktemp -d)"
trap 'rm -rf "$toolsrc"' EXIT
tar -xzf inputs/metacubex-geo.tar.gz -C "$toolsrc" --strip-components=1
(cd "$toolsrc" && patch -p1 < "$root/metadb-epoch.patch" && go build -mod=readonly -buildvcs=false -o "$out/geo-converter" ./cmd/geo)
"$out/geo-converter" -D "$out" convert ip -i v2ray -o meta -f "$out/geoip.metadb" "$out/geoip.dat"
sha256sum "$out/geoip.dat" "$out/geoip.metadb"
