#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_SRC="$ROOT/launchd/com.yanan.cursor-quota-bar.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.yanan.cursor-quota-bar.plist"

"$ROOT/scripts/build.sh"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__QUOTA_BAR_BIN__#$ROOT/build/Cursor额度条.app/Contents/MacOS/QuotaBar#g" "$PLIST_SRC" > "$PLIST_DST"
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "installed $PLIST_DST"
echo "登录后会自动启动屏幕顶端额度条。"
