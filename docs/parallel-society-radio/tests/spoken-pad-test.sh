#!/usr/bin/env bash
# #65 regression test (headless) — spoken interstitials must carry a TRAILING SILENCE PAD >= the
# station crossfade duration, so the global crossfade overlaps silence, not Lujan's last words.
# Without the pad, the next track rises while he's mid-sentence (the #65 bug).
#
# Usage:  ./spoken-pad-test.sh [SPOKEN_DIR]
#   default SPOKEN_DIR = /mnt/music/parallel-society-radio/spoken  (run on the content host, e.g. Sneg)
# Requires: ffprobe, ffmpeg, python3.
set -uo pipefail
DIR="${1:-/mnt/music/parallel-society-radio/spoken}"
CROSS="${CROSS:-3.0}"     # station.liq crossfade duration (radio = crossfade(... duration=3. ...))
THRESH="${THRESH:--50}"   # dB; the last CROSS seconds must be quieter than this to count as a silent pad

[ -d "$DIR" ] || { echo "SKIP: spoken dir not found: $DIR"; exit 0; }

pass=0; fail=0
shopt -s nullglob
files=("$DIR"/*.flac "$DIR"/*.mp3 "$DIR"/*.wav "$DIR"/*.m4a "$DIR"/*.ogg)
[ ${#files[@]} -gt 0 ] || { echo "SKIP: no audio in $DIR"; exit 0; }

for f in "${files[@]}"; do
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
  start=$(python3 -c "print(max(0.0, $dur - $CROSS))")
  # input-seek (-ss before -i) is reliable; measure peak level of the trailing CROSS seconds.
  # NOTE: volumedetect prints stats at INFO level — do NOT pass -v error (it hides them).
  maxv=$(ffmpeg -hide_banner -ss "$start" -i "$f" -af volumedetect -f null - 2>&1 \
         | grep -oE 'max_volume: -?[0-9.]+' | grep -oE '\-?[0-9.]+' | head -1)
  ok=$(python3 -c "m=${maxv:-0.0}; print('PASS' if m <= $THRESH else 'FAIL')")
  printf "%-42s tail(-%ss) max=%s dB  %s\n" "$(basename "$f")" "$CROSS" "${maxv:-?}" "$ok"
  [ "$ok" = PASS ] && pass=$((pass+1)) || fail=$((fail+1))
done

echo "--- spoken-pad test: $pass passed, $fail failed (dir: $DIR) ---"
[ "$fail" -eq 0 ]
