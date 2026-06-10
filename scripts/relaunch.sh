#!/usr/bin/env bash
# Restart Logos Basecamp cleanly. Kills ALL logos_host processes first — stale ones
# (e.g. from a logoscore run) make IPC reach the wrong plugin binary.
#
# Usage:  ./scripts/relaunch.sh
set -uo pipefail

APPIMAGE="${LOGOS_APPIMAGE:-$HOME/logos-basecamp-current.AppImage}"

kill -9 $(pgrep -f logos_host) 2>/dev/null || true
kill -9 $(pgrep -f "LogosBasecamp\.elf") 2>/dev/null || true
sleep 1
# Verify nothing stale remains before relaunch.
if pgrep -a logos_host >/dev/null 2>&1; then
    echo "WARNING: logos_host still running — kill it before relaunch:"; pgrep -a logos_host
fi

[[ -x "$APPIMAGE" ]] || { echo "AppImage not found at $APPIMAGE (set LOGOS_APPIMAGE)"; exit 1; }
echo "Launching $APPIMAGE …"
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
  nohup "$APPIMAGE" > /tmp/radio-basecamp-launch.log 2>&1 &
echo "Launched (pid $!). Logs: /tmp/radio-basecamp-launch.log"
