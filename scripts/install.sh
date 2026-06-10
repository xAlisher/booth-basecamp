#!/usr/bin/env bash
# Build both LGX packages and install them into Logos Basecamp via lgpm.
# Recipe: basecamp-skills/builder-lgx-install-recipe. Install target is LogosBasecamp
# (NOT LogosApp — Basecamp does not load from LogosApp).
#
# Usage:  ./scripts/install.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

MDIR="$HOME/.local/share/Logos/LogosBasecamp/modules"
PDIR="$HOME/.local/share/Logos/LogosBasecamp/plugins"
mkdir -p "$MDIR" "$PDIR"

LGPM="${LGPM:-$(find /nix/store -name lgpm -path '*logos-package-manager-cli*/bin/lgpm' 2>/dev/null | head -1)}"
[[ -x "$LGPM" ]] || { echo "lgpm not found — set LGPM=/path/to/lgpm"; exit 1; }

echo "Building radio_module (.lgx-portable) …"
nix build "$HERE/radio_module#lgx-portable" --out-link /tmp/rm-lgx
echo "Building radio_ui (.lgx) …"
nix build "$HERE/radio_ui#lgx" --out-link /tmp/ru-lgx

RM_LGX="$(find -L /tmp/rm-lgx -name '*.lgx' | head -1)"
RU_LGX="$(find -L /tmp/ru-lgx -name '*.lgx' | head -1)"

# Clean reinstall — lgpm skips files that already exist, so stale metadata would persist.
echo "Installing radio_module → $MDIR/radio_module"
rm -rf "$MDIR/radio_module"
"$LGPM" --modules-dir "$MDIR" --ui-plugins-dir "$PDIR" --allow-unsigned install --file "$RM_LGX"

# Self-contained MediaMTX: the .lgx bundler can't ship extra binaries, so drop the official STATIC
# MediaMTX (CGO-free Go binary → runs on any x86_64 Linux, no libs) next to the plugin. The module's
# resolveBin() finds it at <module-dir>/bin/mediamtx. tor/torsocks/ffplay stay system deps (apt).
MMTX_VER="${MEDIAMTX_VERSION:-v1.18.2}"
MMTX_BIN="$MDIR/radio_module/bin/mediamtx"
if [[ -n "${RADIO_MEDIAMTX_BIN:-}" ]]; then
  echo "Skipping MediaMTX bundle (RADIO_MEDIAMTX_BIN is set)."
else
  echo "Bundling MediaMTX $MMTX_VER (static) → $MMTX_BIN"
  mkdir -p "$(dirname "$MMTX_BIN")"
  TMP="$(mktemp -d)"
  URL="https://github.com/bluenviron/mediamtx/releases/download/${MMTX_VER}/mediamtx_${MMTX_VER}_linux_amd64.tar.gz"
  if curl -fsSL "$URL" -o "$TMP/m.tgz" && tar -xzf "$TMP/m.tgz" -C "$TMP" mediamtx; then
    install -m755 "$TMP/mediamtx" "$MMTX_BIN"
    echo "  ✓ MediaMTX bundled ($("$MMTX_BIN" --version 2>/dev/null || echo ok))"
  else
    echo "  ⚠ Could not fetch MediaMTX — install it system-wide or set RADIO_MEDIAMTX_BIN."
  fi
  rm -rf "$TMP"
fi

echo "Installing radio_ui → $PDIR/radio_ui"
rm -rf "$PDIR/radio_ui"
"$LGPM" --modules-dir "$MDIR" --ui-plugins-dir "$PDIR" --allow-unsigned install --file "$RU_LGX"

echo "Done. radio_module depends on delivery_module — ensure it is installed too."
echo "Then run ./scripts/relaunch.sh to restart Basecamp."
