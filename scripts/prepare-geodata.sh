#!/usr/bin/env bash
# Always resolve latest stable data; retain per-build integrity and identity.
set -euo pipefail
source "$(dirname "$0")/env.sh"
python3 "$REPO_ROOT/scripts/ci/prepare-geodata.py"
