---
id: liquidsoap-source-client-mediamtx
title: Drive the station from a headless Liquidsoap source client into MediaMTX
phase: integration
type: pattern
severity: high
severity_reason: Wrong encoder/URL/env-API and the station never ingests — silent no-stream
modules: ["radio_module"]
basecamp_commit: "0285e29"
basecamp_commit_date: "2026-07-02"
basecamp_ref: "feat/parallel-society-radio"
source: extracted-local
upstream_url: "https://www.liquidsoap.info/doc-2.2.5/"
upstream_commit: ""
upstream_last_updated: "2026-07-02"
last_used: "2026-07-02"
created: "2026-07-02"
status: active
api_era: agnostic
---

## Problem
Feed a radio_module station headlessly from pre-recorded audio (no OBS). Liquidsoap must push
**AAC-in-FLV over RTMP** to the module's MediaMTX ingest, or the path never goes `ready:true`.

## Recipe
`station.liq` (verified `--check` clean on Sneg, apt liquidsoap **2.2.4**):
```liquidsoap
settings.server.telnet.set(true)           # control surface on :1234 (skip/queue/metadata)
settings.server.telnet.port.set(1234)
radio = mksafe(playlist(mode="randomize", reload_mode="watch", "/path/to/music"))
# assign env FIRST — do NOT wrap the lookup in a "#{…}" interpolation (it errors at --check):
path = environment.get(default="", "PSR_RTMP_PATH")   # 2.2 API: environment.get, NOT getenv
pass = environment.get(default="", "PSR_RTMP_PASS")
output.url(
  url = "rtmp://127.0.0.1:1935/#{path}?user=publisher&pass=#{pass}",
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", samplerate=44100, channels=2)),
  radio)
```
Launch: `PSR_RTMP_PATH=<path> PSR_RTMP_PASS=<pass> liquidsoap station.liq`
(path + pass come from the Stream-tab OBS card / MediaMTX; **the pass rotates per session** — re-pull
and restart on rekey). Verify ingest: `curl -s localhost:9997/v3/paths/get/<path>` → `ready:true`,
`source.type:rtmpConn`, inbound climbing.

## Why
Two load-bearing gotchas cost real time: (1) liquidsoap 2.2 renamed `getenv` → `environment.get` —
`getenv(...)` fails `--check` with *"Missing arguments in function application: string"*; (2) wrapping
the env lookup inside `"#{environment.get(...)}"` also errors — assign to a var, then interpolate the var.
The apt (Ubuntu) liquidsoap build **does** include the `%ffmpeg` AAC encoder (verified) — no plugin pkg needed.

## See also
- audio-loudnorm-two-pass-per-type
