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

echo "Installing radio_ui → $PDIR/radio_ui"
rm -rf "$PDIR/radio_ui"
"$LGPM" --modules-dir "$MDIR" --ui-plugins-dir "$PDIR" --allow-unsigned install --file "$RU_LGX"

echo "Done. radio_module depends on delivery_module — ensure it is installed too."
echo "Then run ./scripts/relaunch.sh to restart Basecamp."
