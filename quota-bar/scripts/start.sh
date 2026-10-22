#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Cursor额度条.app"
BIN="$APP/Contents/MacOS/QuotaBar"
REFRESH="${QUOTA_BAR_REFRESH_SECONDS:-60}"

"$ROOT/scripts/stop.sh" >/dev/null 2>&1 || true
"$ROOT/scripts/build.sh"

: > /tmp/cursor-quota-bar.log
open "$APP" --args --refresh-seconds "$REFRESH"
sleep 1
pid="$(pgrep -n -f "$BIN" || true)"
if [[ -n "$pid" ]]; then
  echo "$pid" > /tmp/cursor-quota-bar.pid
  echo "started pid=$pid refresh=${REFRESH}s"
else
  echo "started via LaunchServices refresh=${REFRESH}s"
fi
echo "log=/tmp/cursor-quota-bar.log"
echo "snapshot=$HOME/Library/Application Support/CursorQuotaBar/last-snapshot.json"
