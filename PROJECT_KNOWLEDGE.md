# radio-basecamp — Project Knowledge

Accumulated wisdom. Patterns, pitfalls, proven facts. (Raw captures live in `docs/retro-log.md`
and get reshuffled here.)

---

## Platform / architecture

### A `type: core` module cannot consume `delivery_module` (the defining blocker)
Constructing the generated typed SDK in a core module — `m_logos = new LogosModules(api)` — crashes
at load: `std::length_error` / `basic_string::_M_create` inside `LogosAPI::getClient` →
`CoreManager` ctor, **before any of our code runs**. Independent of timing (deferring doesn't help),
delivery tag (v0.1.1 *and* v0.1.2 crash), builder rev, or SDK pin. It works on the older AppImage
`pre-release-1dc1c08-268` and under `logoscore`; it crashes on `0.1.2`/`269`/`295`.
- Upstream: **delivery-module#31** (identical stack, fryorcraken), **basecamp#150** (core plugins
  have no IPC token-bootstrap), **basecamp#169** (UI→core→delivery dev-`.lgx` handshake timeout → spinner).
- **Supported path:** consume delivery from a **`ui_qml` module with a C++ backend** (runs in `ui-host`,
  where `getClient` works) — the shape `logos-delivery-demo` uses. WIP on the `ui-qml-backend` branch.
- We chose core+QML at the start *without reading the dependency's open issues* — #31 was knowable on
  day one. Lesson now baked into the platform-state-check (read a dep's OPEN issues, not just its API).

### Diagnosing a load-time crash when stderr is swallowed
`logos_host` / `ui-host` child stderr is swallowed (basecamp#163), and `qDebug` can be filtered/buffered.
To locate a crash that happens before/around `initLogos`, bracket suspect lines with **unbuffered
markers**: `fprintf(stderr, "MARK\n"); fflush(stderr);`. These survive a `terminate()` and pinpoint the
exact throwing line (this is how we proved the crash was in `new LogosModules(api)`, not our logic).

### Running a module on a different AppImage release without disturbing the current one
wild keeps the 295 pre-release at `~/logos-basecamp-current.AppImage` (other agent uses it). To run
radio on the working older build, use a **separate binary + isolated profile**:
`XDG_DATA_HOME=~/.local/share/Logos-khidr <session-env> ~/logos-basecamp-khidr.AppImage`. The profile
holds its own `modules/` + `plugins/` (rsynced from a known-good machine). Modules must be
portable-built (`$ORIGIN` rpath) to run cross-machine.

It CAN run **alongside** an already-live Basecamp (e.g. a demo on a call you must not kill) — the only
true cross-profile collision is delivery's fixed **TCP 60000**, so coexistence is safe iff the live
instance does NOT use delivery (preflight `ss -tln | grep ':60000 '`). Add a separate `XDG_CACHE_HOME`
so you never rewrite the live instance's qmlcache, and do NOT `pkill`/`fusermount` (each AppImage
self-mounts at its own `/tmp/.mount_logos-XXXXXX`). Reusable launcher:
`receiver-basecamp/scripts/launch-khidr.sh`. Platform skill: `basecamp-nondestructive-coexist-launch`
(supersedes the "run only ONE instance" caution; `LOGOS_DATA_DIR` is suspect on current builds —
`XDG_DATA_HOME` is what actually separates profiles).

---

## Source clients — pushing audio into the station (OBS alternatives)

`buildCard()` (`radio_plugin.cpp:291`) mints the ingest endpoints from `m_path`/`m_streamKey`/ports;
MediaMTX `authInternalUsers` requires `user=publisher&pass=<streamKey>` to publish (HLS read is public).
Onion mode forces the ingest IP to loopback `127.0.0.1` (never `lanIp`). Endpoints (defaults):
`rtmp://<ip>:1935/<path>?user=publisher&pass=<key>` · WHIP `http://<ip>:8889/<path>/whip?…` ·
`srt://<ip>:8890?streamid=publish:<path>:publisher:<key>` · HLS out `http://<ip>:8888/<path>/index.m3u8`.

**Liquidsoap is a clean headless source client (OBS is overkill for a demo).** A `.liq` pushing a
watched playlist dir to the RTMP ingest as **AAC-in-FLV** (what MediaMTX expects) lights up the path —
verified end-to-end (Soulseek download → liquidsoap → RTMP → MediaMTX → HLS/onion → receiver):

```liquidsoap
settings.server.telnet.set(true)            # control surface on :1234 (skip/queue/metadata)
settings.server.telnet.port.set(1234)
radio = mksafe(playlist(mode="randomize", reload_mode="watch", "/path/to/music"))
output.url(url="rtmp://127.0.0.1:1935/<path>?user=publisher&pass=<key>",
           %ffmpeg(format="flv", %audio(codec="aac", b="128k", samplerate=44100, channels=2)), radio)
```

Confirm the publish via the MediaMTX API: `curl -s localhost:9997/v3/paths/list` → `online:true` +
`source.type:rtmpConn`. `mediamtx`/`liquidsoap` are nix system binaries (`nix profile install
nixpkgs#…`); **mediamtx is NOT provisioned by the AppImage** (radio#21) → hosting fails with
`mediamtx_not_found` until it's on PATH. Reusable script: `/tmp/station.liq`. `.liq` gotcha: don't wrap
`getenv` in a `"#{…}"` string interpolation (`Undefined variable home` at `--check`) — assign directly.

---

## Privacy

v1 = **sovereign discovery, NOT streamer anonymity.** `buildAnnouncePayload` puts `http://<lanIp()>…`
in the announce, and `ffplay` pulls directly from the origin — so any directory-topic subscriber learns
the host IP, and host↔listener IPs are mutually exposed on play. Today it's a LAN IP (LAN-scoped).
Hiding the streamer is mostly a *URL swap*: **Tor onion service** (recommended, audio-first fits Tor's
bandwidth) or **Tailscale mesh** (private streams). Full analysis: `docs/BRIEF.md §Privacy`.

---

## Tor onion mode (shipped — default privacy mode)

Host runs a tor HiddenService (`SocksPort 0`) mapping `:80 → MediaMTX HLS`; the announce carries the
`.onion` (never `lanIp`). Listener runs a separate tor (`SocksPort`) and plays via `torsocks ffplay`.
Proven end-to-end across two machines. Hard-won fixes (each was a silent failure):

- **Spawned system binaries must drop `LD_LIBRARY_PATH`/`LD_PRELOAD`** (`cleanSpawnEnv()`). The AppImage
  poisons the child env → apt `/usr/sbin/tor` loaded the AppImage's libevent → `undefined symbol:
  evutil_secure_rng_add_bytes` → instant exit (mislabeled `tor_port_in_use`). nix binaries are immune.
  Platform skill: `appimage-child-ld-library-path`.
- **MediaMTX gates HLS with a `Secure` cookieCheck cookie.** ffmpeg won't return a Secure cookie over
  the `http://` onion → 302 loop → silent no-audio. Fix: `ffplay -cookies "cookieCheck=1; path=/"`.
  Not variant-specific (both `lowLatency` and `mpegts` set it). Local playback hides it (localhost is a
  secure context).
- **The hidden-service keys live in a PERSISTENT per-profile dir** (`GenericDataLocation/radio_module/hs`)
  so the `.onion` survives restarts; `regenerateOnion()` wipes it for a fresh address. **Whoever reads the
  hostname must read it from THAT dir** — `pollOnionStatus` reading the old temp path left `m_onion`
  empty → false `publish_timeout` + a bad announce.
- **Onion-ready detection:** tor logs the descriptor upload at INFO in the `[rend]` domain (not `notice`)
  → torrc `Log [rend]info file hs.log`; `pollOnionStatus` greps `hs.log` for `upload`+`descriptor`, with
  a bootstrap-100%+grace fallback. `logos_host` swallows child stderr (#163) — persist failures to a file.

### Persistence + buffering
- **Stream identity (path + key) is stable across stop/start/restart**: `startStream` REUSES the persisted
  path/key (mints only when absent); `stopStream` saves `running:false` (keeps the key, no auto-resume);
  resume re-spawns only if `running`. `regenerateKey()` (⟳ New) rotates the publish key on demand. Resume
  spawn failures must NOT clear `station.json` (transient port races would lose the key).
- **Listener jitter buffer:** MediaMTX `hlsVariant: mpegts` + deep playlist; ffplay `-infbuf
  -live_start_index -<bufferSec>` starts N seconds behind live and rides out Tor latency → no chops.
  Configurable via `setListenBuffer()` (2–20s slider). Streamer quality is untouched (buffer is
  listener-side only).

---

## Proven facts (don't re-derive)

- Cross-machine demo works on **`pre-release-1dc1c08-268`** (`ef6dca8b`, 270/274 MB). `0.1.2` and the
  `269` pre-release are a *different, newer* build (`1ddd5496`) that crashes radio.
- `no subscribed peers found` in delivery_module logs is **benign filter-protocol noise** — relay carries
  the announce. Cross-machine discovery confirmed by `received relay message … payloadSizeBytes=210`.
- The `play()` http/https allow-list (rejects `file:`/`pipe:`/`concat:`) is the security seam that makes
  an *attacker-controlled* `streamUrl` safe to hand to ffplay. A future `.onion` URL passes it unchanged.

---

## Operational gotchas (agent)

- `pkill -f 'LogosBasecamp.elf'` (or any `-f` pattern that also appears in *your own* command line)
  **kills the agent's shell** mid-script — the pattern matches the pkill invocation itself. Symptom:
  the command exits 1 after the first line with nothing else run. Fix: kill by PID excluding `$$`
  (`pgrep -f … | while read p; do [ "$p" != "$$" ] && kill -9 "$p"; done`), and never put the kill in
  the same command as anything you need to survive.
- fish shell on remote machines: bare `VAR=val cmd` and `$()` fail — use `ssh host 'bash -s' <<'EOF'`.

## Now-playing + private topics (broadcaster half, 2026-07-05) — #35, #49

**Now-playing (#35):** `readNowPlaying()` reads `RADIO_NOWPLAYING_FILE` (a file Liquidsoap's `on_metadata`
writes as `"artist — title"`), sanitizes (strip control chars, cap 120), and `buildAnnouncePayload` adds an
optional `nowPlaying`. Rides the 15s heartbeat. **Needs a meaningful name on the source tracks** — untagged files →
empty `m["title"]/m["artist"]` → empty file → no now-playing. Tag with `ffmpeg -c copy -metadata` (atomic
`mv`, safe mid-playback) when you control the source.

**EXCEPTION — junk tags (DJ-recorder defaults), refines the old "never filename-fallback" rule (2026-07-21):**
mixes from Pioneer/Rekordbox etc. carry auto-tags like `title=REC008`, `artist=PIONEER DJ REC` — *worse than
empty*. There the **filename IS the mix name**; write it directly in `on_metadata` instead of the ID3 title:
`mix = string.trim(path.remove_extension(path.basename(m["filename"])))` → `"Alisher Sherali — #{mix}"`. Shipped
for the Khidr "Alisher Sherali" station.

**GOTCHA — `RADIO_NOWPLAYING_FILE` is read at APP-process launch (`qgetenv`, `radio_plugin.cpp:734`), NOT
per-announce.** Setting it afterward, or restarting **just the radio module** in a running Basecamp, does NOT
take — the process keeps its launch environment (a user "restarted the core module" and it stayed off). Set it
in the launch context (headless: systemd `Environment=`; GUI: `~/.config/environment.d/`; one-off:
`env RADIO_NOWPLAYING_FILE=… ~/logos-basecamp-current.AppImage`), restart the **WHOLE AppImage process**, and
verify `tr '\0' '\n' < /proc/<pid>/environ | grep RADIO_NOWPLAY`. Cost several round-trips on Khidr.
→ skill `module-env-read-at-app-launch`.

**Private topics (#49):** `visibility=private` → announce on a per-stream/named topic instead of the public
directory. The broadcaster can NAME it (radio_ui field shown when Private; radio_module sanitizes it into
`/radio-basecamp/1/<name>/json`, falling back to the per-stream path). `buildCard` exposes
`announceTopic`+`visibility` so radio_ui shows a copyable "Private topic" row. The announce also carries
`announceTopic` so listeners can filter (receiver #44).

**GOTCHA that shipped a "still public" station (user caught it):** the `visibility → announceTopic` derivation
runs only in `startStream`. **Auto-resume (`resumeStreamIfPersisted`) reads `announceTopic` VERBATIM from
`station.json`** (line ~399). So flipping `visibility` in `station.json` alone leaves a running/resumed station
announcing on the OLD topic. To move a persisted station's announce you must set `announceTopic` in
`station.json` too (or restart via `startStream`, not resume). General rule: **a persisted DERIVED field isn't
re-derived on resume — mutate the stored value, not just its source input.**

## UI/QML rules (DS + reactive gates) — hard-won 2026-07-05

- **Status indicators = `LogosBadge`, always.** Don't invent `StatusPill`/`ThemedField`/`ThemedRadio`. Find
  the DS component (`LogosComboBox` choices, `LogosTextField` fields, `LogosButton`/`LogosText`) by reading a
  proven reference — **grep `~/basecamp/refs/logos-delivery-demo` (NOT just `modules/`)**; it uses `LogosComboBox`.
- **Gate `enabled:`/`visible:` on a reactive signal, never a no-notify function call.**
  `logos.isViewModuleReady("x")` evaluates ONCE at load (false) and never re-runs → Start stuck disabled.
  Use `onViewModuleReadyChanged` → set a property (skill: `qml-to-universal-module-qtro-backend`).
- **Change ONE variable when diagnosing a crash** so the fix is attributable. Changing ComboBox→Switch AND
  readOnly/echoMode→LogosText in one rebuild hid which fix mattered → guessed wrong. (The crash was the
  `readOnly`/`echoMode` props on `LogosTextField`, not `LogosComboBox` — which delivery-demo proves works.)

## Liquidsoap station.liq (PSR playout, 2026-07-06)

### A custom `cross` transition EATS the new track's metadata → frozen now-playing
Replacing the built-in `crossfade(...)` with a hand-rolled `cross(duration, trans, src)` where `trans`
returns `add([fade.out(old.source), fade.in(new.source)])` **broke `nowplaying.txt`** — it froze on the
first (startup) track. `cross` reads the incoming track's start-of-track metadata to build `new.metadata`,
**consuming** it, so `on_metadata` downstream never sees it (and `insert_metadata(new.metadata)` didn't
reliably re-emit). The built-in `crossfade` re-inserts it correctly. **Fix: keep the built-in `crossfade`.**
Diagnosed headless: `output.dummy` + `on_metadata(print)` over a `rotate([1,1],[jingles,talks])` — built-in
printed jingle→talk, custom printed jingle→jingle. Verify metadata flow this way BEFORE deploying to a live
stream.

### `liq_cross_duration` controls a track's OUTGOING transition, not incoming
Proven with a tone test (two 5s sines, first stamped `liq_cross_duration=0`, `crossfade duration=3` →
output = 10s = **hard cut**, so the override shortened the cross AFTER the stamped track). So you **cannot**
hard-cut *into* a jingle by stamping the jingle — you'd have to stamp the (unknown) preceding track. To get
"clean voice intro" without a custom transition: give the ident a **3s+ music intro** so the built-in 3s
crossfade completes before the voice.

### Announce/discovery vs stream is intentional (booth-android too)
The node announces continuously (heartbeat), independent of audio being live — that's how a station shows
in Receiver before/without broadcasting. To gate it ("announce only while on air"), stop the native
heartbeat on stop. Stamp jingle metadata via `metadata.map(update=true, insert_missing=true, …)` — `update`
MERGES (keeps the real title/artist), doesn't replace.

### Reload requires a process restart; watched dirs don't
`playlist(reload_mode="watch")` auto-picks-up files dropped into the dir, but a `station.liq` **structure**
change needs killing + relaunching liquidsoap (interrupts listeners — check MediaMTX `readers=` first).

### Rotation weights must match content LENGTH, not track count (2026-07-16)
`rotate(weights=[1,5], [idents, base])` = 1 ident per 5 base *items*. Fine for song-length base, but PSR's
base tracks are FULL talks/DJ sets (**45–90 min each**) → an ident fired only once per ~5 blocks ≈ **4 hours**;
a listener heard neither Chair nor Sterlin for a couple hours (user caught it). For long-form content weight
idents **1:1** with base (`rotate([1,1], [idents, base])`) = one ident between every block (~hourly) — the
densest track-boundary cadence possible (you don't cut a DJ set mid-track). **Check base durations first**
(timestamp gaps between `Prepared` log lines) before trusting an inherited weight.

### Durability: systemd --user + the single-feeder rule (orphan holds telnet :1234) (2026-07-21)
Run the liquidsoap feed as a `systemd --user` service (NOT `nohup`) + `loginctl enable-linger` so it survives
reboot. **Single-feeder rule:** only ONE liquidsoap may push a given RTMP path AND bind the telnet port. A
stray old feeder (a pre-systemd `nohup` liquidsoap, PPID 1) holding `settings.server.telnet.port` (1234) makes
the systemd instance **crash-loop on `Address already in use`** — and the broadcast keeps running on the orphan
(old programme), *masking* the failure. Fix: `ps -eo pid,ppid,etime,args | grep '[l]iquidsoap'` → kill the
PPID-1 orphan → restart the service. Full headless setup (units + `run-app.sh`) is in `docs/ZERO-TO-STREAMING.md`.
