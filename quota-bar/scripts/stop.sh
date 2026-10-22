#!/bin/zsh
set -euo pipefail

osascript -e 'tell application "Cursor额度条" to quit' >/dev/null 2>&1 || true
if [[ -f /tmp/cursor-quota-bar.pid ]]; then
  pid="$(cat /tmp/cursor-quota-bar.pid)"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
  rm -f /tmp/cursor-quota-bar.pid
fi

pkill -f "/quota-bar/build/Cursor额度条.app/Contents/MacOS/QuotaBar" 2>/dev/null || true
pkill -f "Cursor额度条.app/Contents/MacOS/QuotaBar" 2>/dev/null || true
echo "stopped"
