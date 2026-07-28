#!/usr/bin/env bash
# Build + run the standalone private-stream crypto contract test (tests/crypto_selftest.cpp).
# Compiles station_crypto.cpp directly against libsodium + Qt Core — no Basecamp load, no full nix
# build. Proves derive→encrypt→decrypt round-trips, wrong-pass/tamper/wrong-topic fail closed, and
# the golden cross-impl vectors reproduce. This is the cheapest real proof (booth#66 / receiver#69)
# and it gates the UI work.
#
# Qt Core: nix qtbase from the store (override with QT_ROOT). libsodium: pkg-config libsodium.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

QT_ROOT="${QT_ROOT:-$(find /nix/store -maxdepth 1 -type d -name '*-qtbase-*' 2>/dev/null | sort | tail -1)}"
if [ -z "${QT_ROOT:-}" ] || [ ! -d "$QT_ROOT/include/QtCore" ]; then
  echo "ERROR: Qt6 Core not found. Set QT_ROOT to a qtbase prefix (has include/QtCore)." >&2
  exit 2
fi

SODIUM_CFLAGS="$(pkg-config --cflags libsodium 2>/dev/null || true)"
SODIUM_LIBS="$(pkg-config --libs libsodium 2>/dev/null || echo -lsodium)"

echo "QT_ROOT=$QT_ROOT"
echo "SODIUM: ${SODIUM_LIBS}"

OUT="$(mktemp -d)/crypto_selftest"
g++ -std=c++17 -fPIC \
  -isystem "$QT_ROOT/include" -isystem "$QT_ROOT/include/QtCore" \
  $SODIUM_CFLAGS \
  tests/crypto_selftest.cpp src/station_crypto.cpp \
  -L "$QT_ROOT/lib" -lQt6Core $SODIUM_LIBS \
  -Wl,-rpath,"$QT_ROOT/lib" \
  -o "$OUT"

echo "Built. Running..."
"$OUT"
