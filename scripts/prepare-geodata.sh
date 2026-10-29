#!/usr/bin/env bash
# Build fixed GeoIP and GeoSite data.
set -euo pipefail
source "$(dirname "$0")/env.sh"
python3 "$REPO_ROOT/scripts/ci/prepare-geodata.py"
