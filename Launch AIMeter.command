#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"
./run.sh "$@"
# 少し表示してウィンドウを閉じる案内
sleep 1
osascript -e 'tell application "Terminal" to close (every window whose name contains "Launch AIMeter")' 2>/dev/null || true
exit 0
