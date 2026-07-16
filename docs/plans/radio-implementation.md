# Plan: radio-basecamp implementation

**Date:** 2026-06-09
**Status:** Specs resolved — ready to execute in priority order. Awaiting Alisher's go on Epic A.
**Brief:** [`../BRIEF.md`](../BRIEF.md) (feasibility insights binding)
**Architecture:** `radio_module` (core) + `radio_ui` (QML-only) — tutorial-v3 canonical split.

> Fieldcraft: new-project setup ⇒ plan-first. This is that plan. Scope-freeze during execution;
> log follow-ups, don't fold in refactors. Each issue ships ≤~200 lines diff, audited before merge.

---

## Priorities

- **P0 — vertical slice that proves the thesis.** A host can broadcast and a *separate* listener
  can discover-and-play over LogosMessaging with no central index. Issues #1–#9.
- **P1 — makes it a usable radio.** Liveness/TTL, status polish, private topics, player controls. #10–#14.
- **P2 — hardening & ship.** Error UX, packaging/install, docs, security pass. #15–#18.

The bottleneck is **discovery correctness** (the differentiator) and **MediaMTX bundling**
(the one true unknown). Both are pulled early (#2 spike, #6).

---

## Epics → Issues

### Epic A — Scaffold & build skeleton  (P0)

**#1 — Scaffold both modules (core + QML UI), buildable.** ✅ **DONE (2026-06-10):** both
`nix build` green — `radio_module_plugin.so` (1.9 MB) + `radio_ui` (Main.qml/metadata bundled).
Two fixes needed beyond the skeleton: (a) pin `delivery_module` `/v0.1.1` + `follows` (see #2b);
(b) `initLogos(LogosAPI*)` must be **`Q_INVOKABLE`, NOT `override`** — `PluginInterface` (real
`interface.h`) declares only `name()`/`version()` pure-virtual; `initLogos` is a commented-out
TODO there, called via the meta-object system. The create-logos-module skill's `override` is wrong.
- `radio_module/`: `flake.nix` (`mkLogosModule`), `metadata.json` (`type: core`, dep `delivery_module`),
  `CMakeLists.txt` (`logos_module(...)`), `src/radio_interface.h` + `radio_plugin.{h,cpp}` (API contract stubbed).
- `radio_ui/`: `flake.nix` (`mkLogosQmlModule`), `metadata.json` (`type: ui_qml`, `view: Main.qml`, dep `radio_module`), `Main.qml`.
- Reuse: `logos-module-builder-scaffold`, `git-init-gitignore-first`, `builder-core-module-src-layout`.
- **Headless test:** `nix build` succeeds for both; `radio_module/tests/run-headless-tests.sh` loads
  the plugin under `logoscore` and calls a no-op `ping()` → asserts `{"ok":true}`.
- **Done when:** both `nix build` green; `logoscore` loads `radio_module`; `nix run .` shows the QML shell.

### Epic B — Origin: MediaMTX control  (P0)

**#2 — SPIKE: bundle + spawn MediaMTX.** ✅ **CONFIRMED (2026-06-10, hermetic — no AppImage).**
- **Provisioning:** `mediamtx` is in nixpkgs (**1.18.2**) → bundle via `metadata.json` →
  `nix.packages.runtime: ["mediamtx"]`. No vendoring/`external_libraries` needed.
- **Spawn:** `mediamtx <config.yml>` starts cleanly; RTMP/HLS/API listeners open. The module
  will `QProcess`-spawn it the same way and kill on `stopStream()`/teardown.
- **GOTCHA (binding spec for the config generator):** an **empty** MediaMTX config rejects
  arbitrary stream paths (`path '<x>' is not configured`). The generated config MUST include a
  catch-all `paths:\n  all_others:`. Minimal working config verified:
  ```yaml
  rtmpAddress: :<p1>   # OBS ingest
  hlsAddress:  :<p2>   # listener HLS out
  apiAddress:  :<p3>   # status polling (#4)
  api: yes
  hls: yes
  hlsVariant: lowLatency
  rtsp: no  srt: no  webrtc: no   # v1 audio-first; enable srt/webrtc later
  paths:
    all_others:
  ```
- **Full loop verified:** ffmpeg→RTMP push → API `/v3/paths/list` shows path **ready** (H264+AAC)
  → HLS `index.m3u8` serves **HTTP 200** (valid LL-HLS, audio+video renditions). Status polling
  (#4) reads `/v3/paths/list` `items[].ready`/`tracks`. ffplay can then GET the `.m3u8`.
- **Still to verify in #2 impl:** WHIP ingest endpoint (`:8889/<path>/whip`); MediaMTX surviving
  inside `logos_host` (QProcess parent-death handling); port-in-use handling (#15).
- **Headless test:** `tests/run-headless-tests.sh` calls `startStream` → asserts the spawned PID is
  alive and the HLS port answers HTTP 200/404 (not connection-refused); `stopStream` → PID gone.

**#3 — Ingest URL + stream-key minting.** ✅ **DONE (2026-06-10, runtime-proven).** `startStream(configJson)`
spawns MediaMTX (lands #2 impl) and returns `{ok, path, streamKey, whipUrl, rtmpUrl, srtUrl, hlsUrl}` with the
host LAN IP; `stopStream` tears it down. Random 16-hex `path` doubles as the OBS stream key in v1 (real
publish auth → #18). Ports overridable via `RADIO_*_PORT`; binary via `RADIO_MEDIAMTX_BIN`.
- **Proof:** `tests/run-direct-test.sh` (in-process, bypasses logoscore's gated returns) — ALL PASS:
  card has all fields, MediaMTX API up after start, down after stop, path unique across calls.

**#4 — MediaMTX status polling.** ✅ **DONE (2026-06-10, runtime-proven).** `getStreamStatus()` →
`{ok, state: idle|waiting|receiving|live, hlsUrl}` by querying MediaMTX `GET /v3/paths/get/<path>`.
Uses **`QTcpSocket`** (synchronous, no event-loop reentrancy — not `QNetworkAccessManager`/`QEventLoop`).
Mapping: no process→idle; 404→waiting; source+ready+tracks→live; source-only→receiving. Emits
`streamStatusChanged` on edge.
- **Proof:** direct-test ALL PASS — `waiting` with no publisher, `live` after an ffmpeg RTMP push.

### Epic C — Discovery: announce + subscribe  (P0)

**#5 — `delivery_module` init + topic plumbing.** ✅ **DONE (2026-06-10): wiring built + loads;
decode path runtime-proven. Live IPC round-trip deferred to AppImage.** `startDiscovery()` does
`getClient → createNode({mode:Core,relay:true,preset:logos.dev}) → requestObject → onEvent(messageReceived)
→ start → subscribe(directoryTopic)` (proven scorched-earth pattern). `addTopic(t)` subscribes extra
topics; `getStations()` returns the cache. `ingestAnnounce(b64)` does a SINGLE `fromBase64` decode,
validates, self-echo filters (skip own `path`), stores keyed by path with `_lastSeen`.
- Reuse applied: `delivery-module-messaging`, scorched-earth `game_plugin.cpp`, `logosapi-member-no-redeclare` (fixed).
- **Proof:** direct-test ALL PASS for `ingestAnnounce` (valid stored, malformed dropped). Module loads
  via logoscore. The live two-node send/receive round-trip needs real `delivery_module` + AppImage
  (can't test headlessly — logoscore gates returns; `logoscore-gates-method-returns`). Remaining headless
  gap is the ONLY unverified part of the origin+discovery slice.

**#6 — Announce schema + publish.** ✅ **DONE (2026-06-10): schema + gating runtime-proven; send → AppImage.**
`buildAnnouncePayload(seq)` → `{v, name, host, path, streamUrl, visibility, description, startedAt, seq}`.
`announceOnce()` gates on `streamState()` (only `live`/`receiving`), then publishes on the announce topic —
**public → directory topic; private → `/radio-basecamp/1/<path>/json`** (set in `startStream`). Delivery-node
init refactored into shared `ensureDeliveryNode()` (used by #5 + #6). The #10 heartbeat will call `announceOnce()` on a timer.
- **Proof:** direct-test ALL PASS — gated `not_live` before streaming; once live, the gate passes and the
  payload carries the full schema. Actual `delivery_module.send` needs the AppImage (same gap as #5's round-trip).

### Epic D — Stream tab UI  (P0→P1)

**#7 — Stream tab: setup card + start/stop.** ✅ **DONE (2026-06-10): UI built, QML loads + elements
instantiate.** Name field, Public/Private (`ButtonGroup`), description, Start (disabled until name set)
→ `startStream`; OBS card (WHIP/RTMP/Stream-Key + Copy via hidden-`TextEdit` clip helper, no
`Qt.openUrlExternally`) + Stop → `stopStream`. Renders from `streamCard` property.
- **Proof:** integration-test passes (QML loads, form elements instantiate). **Findings (2026-06-10):**
  (a) `logos.callModule` WORKS in the standalone app (real returns, unlike gated bare logoscore) — UI tests
  can drive the backend; (b) `mediamtx` is NOT on PATH in the standalone-app sandbox (`execve: No such file`),
  so the full Start→card flow can't run there — verified in the running app; (c) the framework's
  `expectTexts` matches by `text` property **regardless of visibility** → it proves elements EXIST, not
  visible render. So all `ui-tests.mjs` assertions = "QML loads + elements instantiate", not visual correctness.

**#8 — Live status light.** ✅ **DONE (2026-06-10).** A 1.5s `Timer` (running while streaming) polls
`getStreamStatus()` → `streamState`; a dot+label row in the OBS card maps idle/waiting→"Waiting for
OBS…" (grey), receiving→"Receiving stream…" (amber), live→"🔴 Live (announcing)" (red). Applies
`qml-timer-state-polling`.
- **Proof:** integration-test passes — status label instantiates with default-state text. Live
  transitions need a real stream (mediamtx not on PATH in the UI sandbox; backend mapping already proven in #4).

### Epic E — Listen tab + playback  (P0→P1)

**#9 — Listen tab: directory render + tap-to-play.** ✅ **DONE (2026-06-10).** Backend: `play(hlsUrl,name)`
spawns `ffplay -nodisp -autoexit` (skill `ffplay-subprocess-player`); `stop()`/`getPlayerStatus()`.
UI: Listen tab starts discovery on open, polls `getStations()` (2s `Timer`), renders a `ListView`
(name / host · uptime), tap → `play(streamUrl)`, now-playing bar + Stop, + add-topic field.
- **Proof:** direct-test ALL PASS — `play` → ffplay running, `stop` → stopped (SDL dummy audio for headless).
  integration-test passes — Listen-tab elements instantiate. Tap-to-play with live rows needs
  delivery_module announces (cross-machine demo).

### Epic F — Liveness  (P1)

**#10 — Heartbeat re-announce (15s).** ✅ **DONE (2026-06-10).** A `QTimer` (interval `RADIO_HEARTBEAT_MS`,
default 15000) started in `startStream`, stopped in `stopStream`, fires `announceOnce()`.
- **Proof:** direct-test ALL PASS — with a 150ms interval, `announceAttemptCount` grows ≥3 over a 1.2s event loop while live.

**#11 — TTL expiry (45s).** ✅ **DONE (2026-06-10).** `getStations()` lazily prunes stations whose
`_lastSeen` is older than `RADIO_TTL_MS` (default 45000 = 3 missed 15s beats); emits `stationsChanged` on prune.
- **Proof:** direct-test ALL PASS — with TTL 200ms, an ingested station is present then pruned after 350ms.

**#12 — `+ Add topic` (private streams).** Field subscribes to an arbitrary topic; unlisted stations
join the directory view; de-dupe across topics.
- **Headless UI test:** enter a topic → assert subscribe called with it; mocked station on that topic renders.

### Epic G — Player controls + polish  (P1)

**#13 — Player controls.** ✅ **DONE (2026-06-10).** **No pause** — for *live* radio, pausing is just
stop (the live edge moves on and MediaMTX rotates the HLS segments away). Controls are **Play / Stop /
Volume**. `setVolume(pct)` clamps 0–100 and restarts `ffplay -volume` (it has no runtime volume IPC);
now-playing bar has a volume slider + Stop.
- **Proof:** direct-test ALL PASS — setVolume reports 40 + still playing after the change, stop → stopped.

**#14 — Stream/Listen empty + transitional states.** ✅ **DONE (2026-06-10).** Listen empty state shows
a `BusyIndicator` + "Open to discover stations" / "Listening for stations…"; Stream uses the #8 status
light ("Waiting for OBS…").
- **Proof:** integration-test passes — both empty-state strings instantiate.

### Epic H — Hardening & ship  (P2)

**#15 — Error UX & silent-failure guards.** ✅ **DONE (2026-06-10, runtime-proven).** Backend returns
distinct codes — `mediamtx_not_found` (`QProcess::FailedToStart`) vs `mediamtx_port_or_config` (immediate
exit) vs `mediamtx_spawn_failed`; `ffplay_not_found` vs `ffplay_failed`; `no_delivery_client`;
`config_write_failed`; `name_required`; etc. UI: a checked `call()` helper maps every `{ok:false}` to
human copy and shows a dismissable error **banner** (`implicitHeight`, not `height`). Failing calls
routed through it: start/play/addTopic/startDiscovery.
- **Proof:** integration-test drives a real failed Start (mediamtx absent in the sandbox) → banner shows
  "Broadcast server (MediaMTX) isn't available on this system." — end-to-end error surfacing verified.
**#16 — LGX packaging + install.** ✅ **DONE (2026-06-10).** Both `.lgx` build via the **built-in
targets** — `radio_module#lgx-portable` (core, bundles boost/ssl/crypto + the `.so`, variant
`linux-amd64`) and `radio_ui#lgx` (QML, variant `linux-amd64-dev`). The external `#dual` bundler is
broken (`builder-lgx-install-recipe`) — not used. `scripts/install.sh` builds both + `lgpm`-installs to
**LogosBasecamp** (not LogosApp); `scripts/relaunch.sh` kills `logos_host` + restarts the AppImage.
- **Proof:** both `nix build .#lgx*` green; tarballs verified (bare paths `manifest.json` + `variants/…`).
  Install/relaunch not run here — they touch the shared Basecamp runtime (left for the cross-machine demo).
**#17 — README + user docs** (mirror beacon/stash README shape).
**#18 — Security pass.** ✅ **DONE (2026-06-10, runtime-proven).** Fixes:
  - **Stream-hijack (headline):** the public `path` and the **secret 128-bit publish key are now
    separate**. MediaMTX `authInternalUsers` makes HLS read public, **publish require the key**, and the
    API localhost-only (auth-config spike-verified). OBS URLs carry `?user=publisher&pass=<key>`; the
    **announce exposes only the public path** (no secret). Listeners can't republish/hijack.
  - **Player URL allowlist:** `play()` only opens `http`/`https` — a malicious announce can't make
    `ffplay` read `file:`/`pipe:`/`concat:`/a device.
  - **Topic-injection:** `addTopic()` validates `^/[A-Za-z0-9._/-]{1,128}$` before subscribe.
  - **No shell injection:** every subprocess (`mediamtx`/`ffplay`/`ffprobe`) is launched with a
    `QStringList` arg vector — no shell, no quoting bugs.
  - **Entropy:** path 64-bit, publish key 128-bit, `QRandomGenerator::system()`.
- **Proof:** direct-test ALL PASS (20) — auth'd push goes live, announce carries no secret, `play`
  rejects `/etc/passwd` + `file://`, `addTopic` rejects a malformed topic. OBS guide updated.

---

## Execution order (spikes-first)

1. **#1** scaffold → **#2 SPIKE** MediaMTX bundling (de-risk the unknown before UI work).
2. **#3 #4** origin minting + status → **#5 #6** discovery announce/subscribe.
3. **#7 #8** Stream tab → **#9** Listen tab + play. **← P0 vertical slice done: cross-machine demo.**
4. **#10 #11 #12** liveness + private topics → **#13 #14** controls/polish.
5. **#15–#18** harden, package, document, security.

**First demo milestone:** after #9 — Khidr (2nd machine) discovers and plays a stream broadcast
from the primary, over LogosMessaging, no central index. (Reuse cross-machine setup from the
scorched-earth P2P notes: distinct `SCORCHED_TCP_PORT`-style node separation if both run locally.)

---

## Phase 2 — Identity & Scaling roadmap (2026-06-23)

> Cross-module epic spanning **radio-basecamp** + **receiver-basecamp**. Anchored on a station
> **cryptographic identity** (a Keycard-derived signing key) which then unlocks two things: a
> trustworthy *follow/notify* experience, and a *restream mesh* that scales past the single-origin
> uplink limit (the Phase-2 path the BRIEF anticipated). Same plan-first / scope-freeze / spikes-first
> discipline as v1. receiver-basecamp has no plan doc of its own, so its issues are tracked here.

> **Status (2026-07-16):** the identity foundation **#24 shipped** — announces are now signed with a
> Keycard-derived secp256k1 key (v0.2.1, `feat/station-identity-sign`; assumption 7 verified). **#25**
> (signed media digests — the mesh linchpin) remains **open**. The receiver-side themes below
> (**#13–#16**) are **receiver-basecamp** issue numbers, tracked in that repo, not radio's #13–#16.

**Two themes, in dependency order:**

| Pri | Issue | Repo | Theme | Depends on | Risk | Value |
|-----|-------|------|-------|-----------|------|-------|
| **P2.0** | **#24 — sign announces with a Keycard-derived domain key** | radio | Identity (foundation) | — | Med (secp256k1 host-side sign; keycard optional) | Gates everything below |
| **P2.1a** | **#13 — verify station identity by pubkey, not name** | receiver | Identity | #24 | Low | Anti-spoof; "same host" anchor |
| **P2.1b** | **#14 — pin a station + background desktop notification** | receiver | Identity | #13, #24 | Med (needs platform background-lifetime check) | First headline UX (follow a host) |
| **P2.2** | **#25 — signed media digests (verify stream is identical)** | radio | Scaling (foundation) | #24 | **High — riskiest unknown** (sign rolling 1s mpegts segments) | Trust linchpin for the whole mesh |
| **P2.3a** | **#15 — restream on your own .onion + announce as a mirror** | receiver | Scaling | #25, #24 | Med-High | More endpoints; offloads origin uplink |
| **P2.3b** | **#16 — aggregate endpoints by identity + select best (failover)** | receiver | Scaling | #15, #25, #13 | Med | Listener picks best of N mirrors |

**Dependency graph**

```
#24 (sign announces) ──┬──▶ #13 (verify) ──▶ #14 (pin + bg notify)        ← Identity theme
                       │                         ▲
                       └──▶ #25 (sign media) ──▶ #15 (restream/mirror) ──▶ #16 (aggregate + select)
                                                                  ▲
                                                       #13 (verify) ┘   ← Scaling theme reuses verify
```

**Recommended execution order (spikes-first, ship-the-cheap-win-first)**

1. **#24** — the identity foundation. Nothing else is real without it. Keep Keycard a *soft* dependency
   (no card → unsigned/unverified, today's behavior).
2. **#13 → #14** — ship the **Identity theme as a unit**. Low-risk, high-value, no media-layer crypto;
   delivers "follow a host, get notified, can't be spoofed." `#14` carries a `trivial-experiment-first`
   gate: confirm Basecamp keeps the receiver relay/core module alive in the background *before* building
   the notifier.
3. **Pull the #25 spike early (in parallel with the identity theme)** — it is the riskiest unknown of
   Phase 2, exactly as MediaMTX bundling (#2) was for v1. Spike question: *can we hash MediaMTX's 1s
   mpegts segments as they land and publish a signed feed?* De-risk before committing to the mesh.
4. **#25 (full) → #15 → #16** — the **Scaling theme**, only after the #25 spike proves out and the
   identity theme has shipped. `#16`'s selection logic should also land in radio's own Listen tab.

**Why this order:** the identity theme is a cheap, self-contained win that also produces the `pubkey`
the mesh aggregates on — so shipping it first de-risks and de-scopes the harder scaling theme. The one
thing that can sink the mesh is content authenticity over a live segmented stream (#25), so its *spike*
is pulled forward even though its *build* comes later.

**New assumptions to verify (added to the register below):** #7 (host-side secp256k1 sign/verify is
feasible in-module, privkey wiped), #8 (Basecamp keeps a relay/core module alive with no panel focused),
#9 (MediaMTX 1s segments can be hashed+signed as they land without breaking the live edge).

---

## Content Station — Parallel Society Radio (2026-07-02)

> The v1 plumbing (Liquidsoap → RTMP → MediaMTX → HLS/onion → ffplay, discovery over LogosMessaging)
> is built and demo-proven, but has never carried a real curated program. This epic turns it into an
> actual station — **"Parallel Society Radio"** — fed by Parallel Society festival recordings (talks +
> DJ sets), running headless from **Sneg** (`ssh snezhok`), discoverable and playable in the **Receiver**.
> Directly feeds **#26** ("Wire to the Liquidsoap stream on Sneg" — Sasha's "lifestyle vibe" showcase).
> **Target: DWeb Camp (Jul 8–12)** → sequence spikes-first, launchable-core-first. Branch:
> `feat/parallel-society-radio`. Primary content anchor: **youtube.com/@Logos_network**.

> **Status (2026-07-16):** **launched live 2026-07-05** on Sneg — end-to-end verify (**#34**) closed
> (ahead of the DWeb Camp target). Remaining production issues **#28–#33 stay open** in the tracker;
> the live-state snapshot is archived in
> [`../halts/2026-07-05-parallel-society-radio-live.md`](../halts/2026-07-05-parallel-society-radio-live.md).
> **Durability is done** (superseding the halt's TODO): PSR runs as `systemd --user` units on Sneg —
> `logos-radio-xvfb` + `logos-radio-app` (headless Basecamp, station auto-resume) + `logos-radio-psr`
> (liquidsoap feed), with `logos-radio-feed` (old ffmpeg loop) disabled; the full setup is documented
> in [`../ZERO-TO-STREAMING.md`](../ZERO-TO-STREAMING.md). **Onion reachability (#38/#46) remains the
> open follow-up.**

| GH | Task | Title | Pri | Blocked by |
|----|------|-------|-----|-----------|
| **#28** | 1 | Content discovery: hunt YouTube + Discord → content table | P0 | anchor seed (have @Logos_network) |
| **#29** | 2 | Rip + transcode → optimised MP3/FLAC + EBU-R128 loudness pass | P0 | #28 |
| **#30** | 3 | Provision Liquidsoap on Sneg + pull docs + generate skills | P1 | — |
| **#31** | 4 | Station programming (`station.liq`: rotation, jingles, crossfade, loudness) | P1 | #29 |
| **#32** | 5 | Jingles: invite chair28980 + file jingle-request issue | P1 | — |
| **#33** | 6 | Assemble + launch (station.liq on Sneg → live + announcing) | P0 | #29, #31 (#32 soft) |
| **#34** | 7 | Verify end-to-end in Receiver (discover, play, quality, liveness) | P0 | #33 |

**Execution order (spikes-first):** `#30` (parallel, no deps) · critical path `#28 → #29 → #31 → #33 → #34` ·
`#32` (jingles) in parallel, grafts into #33 when ready — station launches without them if late.

**Loudness recommendation (talks vs DJ sets differ ~10 LUFS):** normalise **offline** at rip time —
`loudgain -a` ReplayGain tags (leaves audio untouched, best quality) or two-pass `ffmpeg loudnorm`
(talks -16 LUFS, music -14 LUFS) — then a **light Liquidsoap `enable_replaygain()` + `limit()`** at
playout as a safety net. Avoid Liquidsoap's adaptive `normalize()` as the primary tool (pumps on music).
Format: FLAC where lossless, else 320 k MP3 (playout re-encodes to AAC 128 k → avoid lossy-on-lossy).

**Kickoff inputs still open (defaults chosen, confirm at kickoff):** Discord anchor channel for the
#28 fan-out; skills home = module `docs/skills/` **+** standalone `liquidsoap-skills/` repo (#30).

---

## Assumptions Register

| # | Assumption | Verification | Break condition |
|---|------------|--------------|-----------------|
| 1 | MediaMTX can be bundled (nixpkgs or vendored) and spawned from `logos_host` | ✅ #2 spike: in nixpkgs 1.18.2, spawns + serves HLS | Not in nixpkgs AND vendored binary won't run under the AppImage's glibc |
| 2 | `delivery_module` is present in the target AppImage | `logoscore` load + `getNodeInfo` smoke | Absent (was ❌ in v173) → must install separately or bundle as dep |
| 2b | `delivery_module` builds as a flake dependency | ⏳ pin `/v0.1.1` + `follows logos-module-builder` (mirrors scorched-earth) so RLN/zerokit/rust resolve from cache | main (0.1.2) without `follows` → nixpkgs mismatch → tries to build rust-default/zerokit from source → FAILS (observed 2026-06-09) |
| 3 | `ffplay` plays HLS `.m3u8` headless with `-nodisp` | local: `ffplay -nodisp -autoexit <m3u8>` | ffplay build lacks HLS demuxer (unlikely; ffmpeg full) |
| 4 | QML sandbox allows copy-to-clipboard for the OBS card | trivial QML clip-helper test | clipboard blocked → fall back to C++ `openUrl`/clip invokable |
| 5 | Heartbeat-only discovery is acceptable UX (no instant directory on launch) | product call — accepted for v1 | users expect instant list → add Store/cache later |
| 6 | A single MediaMTX instance serves the small target audience | brief constraint (origin uplink limit) | audience exceeds uplink → Phase-2 swarm (now in scope — #15/#16) |
| 7 | Host-side secp256k1 sign/verify is feasible in-module, privkey wiped immediately after signing | spike: derive via keycard `deriveKey`, sign an announce, verify, zeroize | no usable secp256k1 in the build → vendor a lib or rethink the scheme (Phase-2 #24) |
| 8 | Basecamp keeps a relay/core module alive (delivery subscription live) with no panel focused | trivial-experiment-first: subscribe in `receiver_relay`, close panel, confirm messages still arrive | host suspends background modules → background notify (#14) not possible as designed; document limitation |
| 9 | MediaMTX 1s mpegts segments can be hashed + signed as they land without disturbing the live edge | spike: watch segment dir, SHA-256 each `.ts`, sign a rolling feed (Phase-2 #25) | segment churn too fast / no stable on-disk segment → sign the playlist instead, or per-segment detached sigs |

## Evidence Matrix (current state)

| Claim | Tested-local | Tested-public | Build-only | Inferred |
|-------|:-:|:-:|:-:|:-:|
| Qt Multimedia absent → ffplay required | ✅ (skill, FUSE mount) | | | |
| QML sandbox blocks network/fs | ✅ (skill) | | | |
| `delivery_module` API shape + base64 | ✅ (source + live smoke) | | | |
| delivery_module has no Store/query | ✅ (source: plugin header) | | | |
| ffplay plays HLS .m3u8 | | | | ⚠️ (verify in #9) |
| MediaMTX in nixpkgs (1.18.2), spawns, serves HLS | ✅ (#2 spike 2026-06-10) | | | |
| MediaMTX needs `paths: all_others` for arbitrary paths | ✅ (#2 spike) | | | |
| delivery_module builds as a dep (pinned v0.1.1 + follows) | | | ✅ (#1 build green) | |
| radio_module + radio_ui compile (nix build) | ✅ (#1 2026-06-10) | | | |
| radio_ui QML loads + tab/form elements instantiate (integration-test) | ✅ (#1/#7 2026-06-10; NB expectTexts proves existence, not visible render) | | | |
| logos.callModule works in standalone app (real returns) | ✅ (#7 probe 2026-06-10) | | | |
| startStream mints card + spawns MediaMTX, stopStream tears down, path unique | ✅ (#3 2026-06-10, direct-test ALL PASS) | | | |
| getStreamStatus: waiting (no pub) → live (after ffmpeg push) | ✅ (#4 2026-06-10, direct-test ALL PASS) | | | |
| ingestAnnounce: base64 decode + parse + self-echo/malformed filter | ✅ (#5 2026-06-10, direct-test) | | | |
| announce schema + gating (not_live → gate passes when live) | ✅ (#6 2026-06-10, direct-test) | | | |
| play (ffplay) → playing, stop → stopped | ✅ (#9 2026-06-10, direct-test) | | | |
| Listen-tab UI elements instantiate | ✅ (#9 2026-06-10, integration-test) | | | |
| error UX: failed Start surfaces a visible banner | ✅ (#15 2026-06-10, integration-test drives real failure) | | | |
| publish auth: keyed RTMP push goes live; announce leaks no secret | ✅ (#18 2026-06-10, direct-test + auth spike) | | | |
| player rejects non-http URLs; addTopic rejects bad topics | ✅ (#18 2026-06-10, direct-test) | | | |
| delivery_module wiring (createNode/subscribe/onEvent) | | | ✅ (#5 builds + module loads) | |
| live delivery_module send/receive round-trip | | | | ⚠️ needs AppImage (2 nodes; logoscore gates returns) |
| radio_module loads + dispatches ping (logoscore, isolated dir) | ✅ (#1 2026-06-10: registry connect + "Method call successful", same as canonical capability_module) | | | |
| Q_INVOKABLE JSON return value readback | | | | ⚠️ blocked in bare logoscore — capability handshake fails for ALL modules (capability_module.requestModule also returns `false`); needs AppImage |
| initLogos = Q_INVOKABLE not override | ✅ (loads in logoscore; canonical capability_module uses identical signature — capability_module_plugin.h:24) | | | |
| tutorial-v3 scaffold is current | ✅ (upstream, updated 2026-06-09) | | | |

## Silent failure modes to guard (enumerate before coding)
- Empty/invalid `metadata.json` → module silently not discovered. (#1)
- Missing `variant` file / wrong `view` path → UI silently blank. (#1, #7)
- `delivery_module` absent → `subscribe` no-ops; no error. (#5, #15)
- QML uses blocked import (`QtGraphicalEffects`, `FileDialog`, network URL) → blank screen, no log. (#7–#9)
- MediaMTX port already in use → start fails quietly. (#2, #15)
- `height:` binding inside a layout silently overridden (use `implicitHeight`). (#8)

## Reused patterns / skills (don't re-derive)
`logos-module-builder-scaffold` · `builder-core-module-src-layout` · `git-init-gitignore-first` ·
`delivery-module-messaging` · `delivery-module-mp-guard-resubscribe` · `ffplay-subprocess-player` ·
`qml-sandbox-restrictions` · `qml-callmodule-reentrancy-guard` · `qml-callmoduleparse-double-json` ·
`builder-lgx-install-recipe` · `basecamp-security-patterns` · scorched-earth `game_plugin.cpp` (delivery init) ·
soulseek `PlayerManager.h` / `PlayerBar.qml` (ffplay). Memory: QML layout `implicitHeight` bug.

## Headless-testing strategy (summary) — revised after 2026-06-10 trial
- **UI (`radio_ui`)** — ✅ **WORKING.** `tests/ui-tests.mjs` (v3 framework) → `nix build .#integration-test`
  loads the plugin in the standalone app and asserts rendered text. First test green (both tabs render).
  Extend per-issue (#7/#8/#9/#14) with mocked backend states.
- **Core (`radio_module`)** — **use `logoscore`, NOT the builder's `#unit-tests`.** Finding (2026-06-10):
  the builder's `logos_test()` framework (`LOGOS_ASSERT`/`mockCFunction`) targets the tutorial's
  **`_impl` module style** (plain class wrapping a C lib). Our module is **`_plugin`/QObject** style, so
  `#unit-tests` doesn't fit (the auto-detected `tests/CMakeLists.txt` fails the `logos_test` contract).
  - **Tier 2 (primary proof):** `tests/run-headless-tests.sh` installs the built `.so` into an **isolated
    temp `--modules-dir`** (never the shared Basecamp dir) with a `-dev` manifest variant + RPATH patch
    (`logoscore-headless-testing` skill), then `logoscore -c "radio_module.ping()"`. This loads the real
    plugin → fires `initLogos` → the meaningful runtime proof. Network tests (#5) XFAIL when
    `delivery_module` absent (logged, never silent-pass).
  - **Tier 1 (in-process, WORKING):** `tests/run-direct-test.sh` builds `tests/direct_test.cpp` against the
    plugin + `liblogos_sdk.a` and instantiates `RadioModulePlugin` directly — **no IPC/capability layer**, so
    it can read real return values and observe side effects (the only way to prove side-effectful methods
    headlessly). Auto-derives Qt/SDK/SSL paths (ldd + `nix develop` env). This is where #3 was proven and
    where #4/#9/#13 logic gets verified. The builder's `#unit-tests` is NOT used (it targets the `_impl`
    module style; raw Qt::Test scaffolding was removed).
