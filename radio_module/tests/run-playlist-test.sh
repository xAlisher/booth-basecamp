#!/usr/bin/env bash
# Build + run the standalone playlist-source / child-guard test (tests/playlist_test.cpp).
# Needs: cmake, a C++17 compiler, Qt 6 (Core + Network), ffmpeg + ffprobe on PATH.
#   Linux: system Qt (qt6-base-dev).  macOS: nix shell nixpkgs#qt6.qtbase nixpkgs#cmake (scripts/mac.sh test).
# mediamtx on PATH (or RADIO_MEDIAMTX_BIN) also runs the live MediaMTX path test (ports 21935/28888/29997).
#
# Usage:  ./tests/run-playlist-test.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TEST_TMP:-${TMPDIR:-/tmp}}/radio-playlist-test"
mkdir -p "$OUT"

if [ -z "${RADIO_MEDIAMTX_BIN:-}" ] && command -v mediamtx >/dev/null; then
  RADIO_MEDIAMTX_BIN="$(command -v mediamtx)"; export RADIO_MEDIAMTX_BIN
fi

cmake -S "$HERE/tests/playlist" -B "$OUT/build" -DCMAKE_BUILD_TYPE=Debug >/dev/null
cmake --build "$OUT/build" -j 4 >/dev/null
echo "Built $OUT/build/playlist_test. Running…"
TEST_TMP="$OUT" "$OUT/build/playlist_test"
