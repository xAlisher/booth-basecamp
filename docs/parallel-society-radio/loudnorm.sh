#!/usr/bin/env bash
# Two-pass EBU R128 loudnorm. Usage: loudnorm.sh <in.mp3> <I> <TP> <out.mp3>
set -euo pipefail
IN="$1"; I="$2"; TP="$3"; OUT="$4"

measure() { # integrated loudness of $1
  ffmpeg -hide_banner -nostats -i "$1" -af ebur128 -f null - 2>&1 \
    | awk '/Integrated loudness:/{f=1} f&&/I:/{print $2" "$3; f=0}' | tail -1
}

echo "  before: $(measure "$IN") LUFS"

# pass 1 — measure, capture JSON
JSON=$(ffmpeg -hide_banner -nostats -i "$IN" \
  -af "loudnorm=I=$I:TP=$TP:LRA=11:print_format=json" -f null - 2>&1 \
  | awk '/^{/{p=1} p{print} /^}/{p=0}')
read -r MI MTP MLRA MTHRESH OFFSET < <(python3 -c "
import json,sys
d=json.loads('''$JSON''')
print(d['input_i'],d['input_tp'],d['input_lra'],d['input_thresh'],d['target_offset'])")

# pass 2 — apply linearly, re-encode mp3 320
ffmpeg -hide_banner -loglevel error -y -i "$IN" \
  -af "loudnorm=I=$I:TP=$TP:LRA=11:measured_I=$MI:measured_TP=$MTP:measured_LRA=$MLRA:measured_thresh=$MTHRESH:offset=$OFFSET:linear=true:print_format=summary" \
  -c:a libmp3lame -b:a 320k "$OUT"

echo "  after:  $(measure "$OUT") LUFS   (target $I)"
