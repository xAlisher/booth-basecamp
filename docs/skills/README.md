# radio-basecamp Skills

Platform-wide Basecamp knowledge lives in `~/basecamp/basecamp-skills/skills/`.
This directory holds **radio-module-specific** recipes — streaming/source-client and content-pipeline
knowledge that travels with the code. Atomic schema per `basecamp-skills/skills/contribution-guide.md`.

| Recipe | Phase | Type | Sev | What |
|--------|-------|------|-----|------|
| [liquidsoap-source-client-mediamtx](liquidsoap-source-client-mediamtx.md) | integration | pattern | high | Headless Liquidsoap → AAC-in-FLV RTMP → MediaMTX; `environment.get` (2.2) + `%ffmpeg` gotchas |
| [audio-loudnorm-two-pass-per-type](audio-loudnorm-two-pass-per-type.md) | integration | pattern | medium | Two-pass EBU R128 per content type (talks −16, music −14 LUFS); batch stdin gotcha |

See also the prose recipe in `../../PROJECT_KNOWLEDGE.md` §Source clients and the playout brain
`../parallel-society-radio/station.liq`.
