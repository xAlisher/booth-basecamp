#!/usr/bin/env bash
# Upgrade a headless Booth station to delivery_module 0.3.3 + radio_module 0.2.0 (#91/#92).
# Usage: upgrade-station.sh <systemd-user-unit> <radio_module.lgx> <delivery_module-installed.tgz>
# Run ON the station host. Stops the unit (never overwrite .so files a running process has mapped), backs up
# both modules OUTSIDE the profile, installs delivery (whole dir) + overlays radio_module, drops the old
# RADIO_DELIVERY_PRESET=logos.dev export, moves an ensure-modules.sh pin, starts the unit.
# If the station's tor then sticks below 100% ("no usable consensus"), its cache in
# /tmp/radio_module/torhost-*/data predates the bundled tor: stop the unit, move that data/ aside, start.
set -euo pipefail
UNIT="$1"; LGX="$2"; DTGZ="$3"
PROF="$HOME/.local/share/Logos-radio/Logos/LogosBasecamp"
RUNAPP="$HOME/radio-station/run-app.sh"
TS="$(date +%Y%m%d-%H%M%S)"
BK="$HOME/radio-backups/upgrade-$TS"   # OUTSIDE the profile (a copy inside modules/ can get loaded)

echo "[upgrade] stopping $UNIT"
systemctl --user stop "$UNIT"
sleep 3

mkdir -p "$BK"
cp -a "$PROF/modules/radio_module" "$BK/" 2>/dev/null || true
cp -a "$PROF/modules/delivery_module" "$BK/" 2>/dev/null || true
cp -a "$RUNAPP" "$BK/run-app.sh"
echo "[upgrade] backup in $BK"

# delivery_module: replace whole dir (no runtime bin/ to keep)
rm -rf "$PROF/modules/delivery_module"
tar -xzf "$DTGZ" -C "$PROF/modules/"
echo "[upgrade] delivery_module -> $(python3 -c "import json;print(json.load(open('$PROF/modules/delivery_module/manifest.json'))['version'])")"

# radio_module: overlay from the .lgx (bundled helpers land in bin/, replacing old symlinks)
TMP="$(mktemp -d)"
tar -xzf "$LGX" -C "$TMP"
mkdir -p "$PROF/modules/radio_module"
# --remove-destination: an old bin/tor is a SYMLINK to a system/user tor; plain cp -f writes THROUGH it
# (overwrote Miner's ~/.local/opt/radio-x tor; on Sneg it would hit root-owned /usr/bin/tor and abort)
cp -a --remove-destination "$TMP/variants/linux-amd64/." "$PROF/modules/radio_module/"
cp -f "$TMP/manifest.json" "$PROF/modules/radio_module/manifest.json"
printf 'linux-amd64' > "$PROF/modules/radio_module/variant"
rm -rf "$TMP"
echo "[upgrade] radio_module -> $(python3 -c "import json;print(json.load(open('$PROF/modules/radio_module/manifest.json'))['version'])")"
ls -la "$PROF/modules/radio_module/bin" | awk '{print $5, $9}' | grep -E "ffmpeg|tor$|mediamtx" || true

# The old logos.dev override would defeat the new delivery config
sed -i 's/^export RADIO_DELIVERY_PRESET=logos.dev/# export RADIO_DELIVERY_PRESET=logos.dev   # removed #92: radio_module 0.2.0 uses the logos.test settings with no preset name/' "$RUNAPP"
grep -n "RADIO_DELIVERY_PRESET" "$RUNAPP" || true

# Sneg pins module versions on every launch: move the radio_module pin to 0.2.0 or it rolls back
if [ -f "$HOME/radio-deploy/ensure-modules.sh" ]; then
  cp -a "$HOME/radio-deploy/ensure-modules.sh" "$BK/ensure-modules.sh"
  PIN="$HOME/radio-deploy/booth-radio_module-0.2.0-linux-amd64.lgx"
  [ "$(readlink -f "$LGX")" = "$(readlink -f "$PIN")" ] || cp -f "$LGX" "$PIN"
  sed -i 's#^ensure "$DEPLOY/radio_module-0.1.3-linux-amd64.lgx" "$PROF/modules/radio_module" 0.1.3 radio_module#ensure "$DEPLOY/booth-radio_module-0.2.0-linux-amd64.lgx" "$PROF/modules/radio_module" 0.2.0 radio_module#' "$HOME/radio-deploy/ensure-modules.sh"
  grep -n "radio_module" "$HOME/radio-deploy/ensure-modules.sh" | tail -2
fi

echo "[upgrade] starting $UNIT"
systemctl --user start "$UNIT"
sleep 5
systemctl --user is-active "$UNIT"
