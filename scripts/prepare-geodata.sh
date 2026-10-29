#!/usr/bin/env bash
# Verify latest GeoIP and the fixed GeoSite reconstruction.
set -euo pipefail
source "$(dirname "$0")/env.sh"
python3 "$REPO_ROOT/scripts/ci/prepare-geodata.py"
