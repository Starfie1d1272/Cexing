#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SMART_LOADER_DIR="$(mktemp -d)"
trap 'rm -rf "$SMART_LOADER_DIR"' EXIT
c++ -std=c++17 -pthread -Itests/smart -Icexing/entry/src/main/cpp \
 tests/smart/bridge-loader.cpp cexing/entry/src/main/cpp/bridge.cpp \
 -Wl,--wrap=dlopen -Wl,--wrap=dlsym -Wl,--wrap=dlclose -ldl -o "$SMART_LOADER_DIR/loader"
for symbol in mihomoInit mihomoStartTun mihomoStop mihomoFree complete; do
 "$SMART_LOADER_DIR/loader" "$symbol"
done
