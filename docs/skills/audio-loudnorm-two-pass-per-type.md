---
id: audio-loudnorm-two-pass-per-type
title: Normalise station content with two-pass EBU R128, per content type
phase: integration
type: pattern
severity: medium
severity_reason: Un-normalised talks vs music jump ~8 LUFS on air — jarring volume swings
modules: ["radio_module"]
basecamp_commit: "0285e29"
basecamp_commit_date: "2026-07-02"
basecamp_ref: "feat/parallel-society-radio"
source: extracted-local
upstream_url: "https://ffmpeg.org/ffmpeg-filters.html#loudnorm"
upstream_commit: ""
upstream_last_updated: "2026-07-02"
last_used: "2026-07-02"
created: "2026-07-02"
status: active
api_era: agnostic
---

## Problem
A radio station mixing **talks** (quiet, ~−21 LUFS) and **DJ/live sets** (loud, ~−13 LUFS) swings ~8
LUFS at every talk↔music transition. Playout-time compression flattens the music; the fix is offline
per-type loudness normalisation before the content ever reaches Liquidsoap.

## Recipe
Two-pass `ffmpeg loudnorm` (linear, accurate) — **talks → −16 LUFS / TP −1.5**, **music → −14 / TP −1.0**:
```bash
# pass 1: measure → JSON (input_i/tp/lra/thresh + target_offset)
ffmpeg -nostdin -i in.mp3 -af loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json -f null -
# pass 2: apply with measured values, re-encode 320k
ffmpeg -nostdin -i in.mp3 -af \
  loudnorm=I=-16:TP=-1.5:LRA=11:measured_I=..:measured_TP=..:measured_LRA=..:measured_thresh=..:offset=..:linear=true \
  -c:a libmp3lame -b:a 320k out.mp3
```
Verify: `ffmpeg -nostdin -i out.mp3 -af ebur128 -f null -` → integrated within ±1 LUFS of target.
Measured this session: talk −21.3→−16.1 ✓, DJ set −13.1→−14.0 ✓. Content is then already at target,
so `station.liq` needs no `enable_replaygain()` — just a gentle final `limit()`.

## Why
Batching gotcha (cost real debugging): in a `while read … done < manifest` loop, **ffmpeg/yt-dlp inherit
the loop's stdin and consume manifest lines** — items silently skipped, loudnorm JSON comes back empty.
Fix: read the manifest on a **dedicated FD** (`done 9< file; read … <&9`) and give inner tools
`-nostdin` (ffmpeg) / `</dev/null` (yt-dlp).

## See also
- liquidsoap-source-client-mediamtx
