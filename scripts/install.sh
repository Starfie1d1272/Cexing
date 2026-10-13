#!/usr/bin/env bash
# 安装并启动 Cexing — 用法: bash scripts/install.sh [hap路径]
set -e
source "$(dirname "$0")/env.sh"
HAP="${1:-$PROJECT_ROOT/dist/cexing-signed.hap}"
$HDC list targets
$HDC install -r "$HAP"
$HDC shell aa start -b com.starfie1d.cexing -a EntryAbility
