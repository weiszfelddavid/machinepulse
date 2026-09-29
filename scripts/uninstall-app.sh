#!/bin/sh
# Removes what install-app.sh put in place: the app bundle and the login item
# it may have registered. --purge also removes the database, preferences, and
# SSH control sockets.
set -eu

INSTALL_DIRECTORY=${MACHINEPULSE_INSTALL_DIRECTORY:-"$HOME/Applications"}
INSTALLED_APP="$INSTALL_DIRECTORY/MachinePulse.app"
BUNDLE_ID=com.davidweiszfeld.MachinePulse

if pgrep -x MachinePulse >/dev/null 2>&1; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _wait_step in 1 2 3 4 5; do
        pgrep -x MachinePulse >/dev/null 2>&1 || break
        sleep 1
    done
    pkill -TERM -x MachinePulse 2>/dev/null || true
fi

if [ -d "$INSTALLED_APP" ]; then
    open -W --env MACHINEPULSE_UNREGISTER_LOGIN_ITEM=1 "$INSTALLED_APP" 2>/dev/null || true
    rm -rf "$INSTALLED_APP"
    echo "removed $INSTALLED_APP and its login item"
else
    echo "nothing installed at $INSTALLED_APP"
fi

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$HOME/Library/Application Support/MachinePulse" "/tmp/machinepulse-ssh-$(id -u)"
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "removed the database, preferences, and SSH control sockets"
fi
