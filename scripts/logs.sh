#!/usr/bin/env bash
# 看 Cexing 日志 — 用法: bash scripts/logs.sh [额外grep]
source "$(dirname "$0")/env.sh"
FILTER="${1:-Cexing\|vpn\|vpnCtrl\|entry\|C1A5}"
$HDC shell "hilog -r" 2>/dev/null
$HDC shell hilog | grep --line-buffered -E "$FILTER"
