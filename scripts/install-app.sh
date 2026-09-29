#!/bin/sh
set -eu

PROJECT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILT_APP=$("$PROJECT_DIRECTORY/scripts/build-app.sh")
INSTALL_DIRECTORY=${MACHINEPULSE_INSTALL_DIRECTORY:-"$HOME/Applications"}
INSTALLED_APP="$INSTALL_DIRECTORY/MachinePulse.app"

mkdir -p "$INSTALL_DIRECTORY"
if pgrep -x MachinePulse >/dev/null 2>&1; then
    osascript -e 'tell application id "com.davidweiszfeld.MachinePulse" to quit' >/dev/null 2>&1 || true
    for _wait_step in 1 2 3 4 5; do
        pgrep -x MachinePulse >/dev/null 2>&1 || break
        sleep 1
    done
    if pgrep -x MachinePulse >/dev/null 2>&1; then
        pkill -TERM -x MachinePulse
    fi
fi
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"
open "$INSTALLED_APP"

echo "$INSTALLED_APP"
