# Halt — 2026-07-05  ·  ARCHIVED (PSR launched)

> Archived 2026-07-16. **Parallel Society Radio went live 2026-07-05** and end-to-end
> verify (**#34**) is now closed. This is the live-state snapshot, kept for reference; the
> roadmap summary lives in [`../plans/radio-implementation.md`](../plans/radio-implementation.md)
> (PSR section). Fate of the Next-steps below: **#34 verify ✅ closed** · liveness durability
> (systemd `--user` service) — a Sneg ops task, not filed as an issue · onion flakiness →
> **#38** (reachability, open) + **#46** (descriptor monitor + auto-republish, open) · the
> plan doc was reconciled with reality on 2026-07-16. Next-steps here are historical.

## ▶ Resume
```bash
cd /home/alisher/basecamp/modules/radio-basecamp   # branch: feat/parallel-society-radio
```

## Where we are
**Parallel Society Radio (#33) is LIVE** on Sneg — festival content (talks + DJ sets) streaming via
liquidsoap → radio_module MediaMTX, announced as "Parallel Society Radio" over the onion. Driven headless.

Also since the last halt: the **v0.2.0 radio upgrade shipped** (separate branch, merged to main + released) —
broadcast-only + universal API + design-system. This PSR branch does NOT touch radio code (docs/liquidsoap/
content only) and is **~11 commits behind main** (the upgrade + docs + inventory). It still works as-is.

## PSR live state (Sneg — `ssh snezhok`, user `sher`)
- **Station:** name "Parallel Society Radio", path `33a5971eeba1d06a`, streamKey `7fe13705bdcd7e710e1843e5818df574`,
  privacy onion. `station.json` at `~/.local/share/Logos-radio/radio_module/` (backup `.bak-psr`; renamed from
  "Logos manifesto").
- **Host:** `logos-radio-app.service` (headless Basecamp + Xvfb :99) runs radio_module + MediaMTX + Tor.
- **Feed:** liquidsoap `PSR_RTMP_PATH=33a5971eeba1d06a PSR_RTMP_PASS=7fe1…574 liquidsoap
  /mnt/music/parallel-society-radio/station.liq` — running as **nohup** (pid varies; log `/tmp/psr-liquidsoap.log`).
  The old `logos-radio-feed.service` (ffmpeg loop) is **stopped** (would compete on the same path).
- Content: 13 EBU-R128 tracks (`/mnt/music/parallel-society-radio/{dj,talks,jingles}`).

## Next steps (in order)
1. **#34 VERIFY (wetware/driveable):** open **Receiver** (installed v0.2.0) → find "Parallel Society Radio"
   → play; check loudness across a talk→DJ transition, survives 45s TTL. (I can drive a headless reachability
   check via the receiver's tor; the actual audible listen is wetware.)
2. **Durability:** liquidsoap is a bare nohup — no auto-restart. Make it a systemd `--user` service (mirror
   `logos-radio-feed`, ExecStart = the liquidsoap line above) so PSR survives a reboot / process death, and
   **disable** `logos-radio-feed` so the ffmpeg loop can't fight it.
3. **Onion flakiness (#38):** the descriptor has gone dark before (Sneg HSDir uploads are flaky) → receivers
   get silence. Monitor; a station restart republishes (`status 200`). Tracked in #38.
4. `docs/plans/radio-implementation.md` still **intentionally uncommitted** (PSR epic append tangled with the
   Phase-2 roadmap — decide how to split before committing).

## Issues (xAlisher/radio-basecamp)
- Upgrade epic **#26 CLOSED** (v0.2.0 released): #39/#40/#41 done. #36 UI strings done (docs remain).
- PSR: #28–#32 ✅ · **#33 launch ✅ (live 2026-07-05)** · #34 verify 🧫 · #35 now-playing (module side deferred) ·
  #37 Sterlin interstitials · **#44** (new) radio_module core legacy→universal + listener-trim (filed, not built).
- #38 broadcaster reachability (onion descriptor monitor + MediaMTX hlsAlwaysRemux).

## Reference
Radio v0.2.0 release: https://github.com/xAlisher/radio-basecamp/releases/tag/v0.2.0 ·
Fork-tree of the upgrade: `docs/radio-upgrade-fork-tree.md` (on main) · Inventory: basecamp-skills/MODULE-INVENTORY.md
