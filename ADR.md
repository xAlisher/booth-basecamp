# Architecture Decision Records — Booth (Logos Radio, broadcaster)

> **App:** Booth — broadcast-only Logos Basecamp module (module IDs `radio_module` core +
> `radio_ui` ui_qml; internal IDs kept as `radio_*` for API compatibility).
> **Version:** v0.2.1 (broadcast-only · universal API · design-system UI).
> **Sibling:** [Receiver](https://github.com/xAlisher/receiver-basecamp) — the listen-only half.
> **Scope of these ADRs:** what Booth *is* today, and why. Discovery is Logos-Messaging-native;
> delivery is a direct HTTP pull of HLS from the host's origin, optionally fronted by Tor.
> There is **no blockchain and no central directory** anywhere in the design.

---

## ADR-1: Discovery over Logos Messaging topics, not a central directory

**Decision:** A station is found by publishing a small JSON *announce* over `delivery_module`
(Logos Messaging, ex-Waku) to a content topic — the well-known public directory topic
`/radio-basecamp/1/directory/json`, or an unguessable private per-stream topic. Receivers
subscribe to the topic and render live stations. There is no index server, no account, and no
directory anyone runs or trusts.

**Alternatives considered:** A central index/directory server or account system (the obvious
build); the older `logos-waku-module` (direct nim-libp2p, March 2026, now superseded by
`delivery_module`).

**Rationale:** The differentiator here is *discovery, not delivery* — anyone can run an HLS
server; what is sovereign is that streams are found over Logos Messaging with no platform in the
middle. A directory server would reintroduce exactly the trust point the project exists to
remove.

**Known limitation:** `delivery_module` exposes no Store/history query, so discovery is
heartbeat-only (see ADR-2) — a station cannot be back-queried on launch, only heard once it
next announces.

---

## ADR-2: Heartbeat + TTL liveness, because there is no history to fall back on

**Decision:** The host re-announces every **15 s** (`RADIO_HEARTBEAT_MS`); a listener drops a
station after **45 s** of silence (`RADIO_TTL_MS`) — three missed beats. A station appears
within one heartbeat and disappears within three. The announce is gated on the origin actually
receiving a stream (it returns `not_live` unless the MediaMTX state is `receiving`/`live`).

**Alternatives considered:** Longer or shorter intervals; announce-always vs announce-on-live.

**Rationale:** With no Store to query, liveness has to be *inferred* from repeated presence.
Announces are tiny, so 15 s is cheap, and TTL-based membership is self-healing — a crashed or
restarted station simply republishes and reappears with no cleanup step.

**Known limitation:** A freshly-opened Receiver is blind to a silent-but-existing station until
its next beat; there is no "what was on earlier" view.

---

## ADR-3: Public directory topic vs unguessable private topic as the reach model

**Decision:** `startStream` takes `visibility: "public" | "private"`. Public announces to the
well-known directory topic. Private announces to an **unguessable per-stream topic**
(`/radio-basecamp/1/<random-or-sanitized-name>/json`) shared out-of-band — the topic string *is*
the invite. Access control is topic-secrecy only; no server enforces it.

**Alternatives considered:** Auth/ACLs on streams — impossible without a server to enforce them.
Per-community sub-directory topics (`/radio-basecamp/1/dir-<community>/json`) noted as a variant.

**Rationale:** Unlisted-by-unguessable-topic gives invite-only broadcast with zero infrastructure,
which is the sovereign substitute for an access list.

**Known limitation:** Anyone who learns the topic can listen indefinitely — there is no
revocation. The `visibility → announceTopic` derivation runs only in `startStream`; auto-resume
(ADR-8) reads `announceTopic` verbatim, so changing `visibility` alone on a persisted station
does not move it off its old topic.

---

## ADR-4: Streamer-IP privacy via a Tor hidden service — `.onion` is the default

**Decision:** By default Booth runs a **Tor hidden service** in front of its MediaMTX HLS origin
and announces `http://<hash>.onion/<path>/index.m3u8` — no IP on the wire and NAT-traversing
with no port-forwarding. `startStream` privacy is `"onion" | "lan"`, defaulting to `onion`; LAN
(direct, IP-exposing) is the labelled opt-in. Two independent `tor` processes are used (a host
tor publishing the hidden service, a separate listener tor for playback over `torsocks`) so the
two lifecycles cannot tear each other down. The announce is gated on descriptor publish and, in
onion mode, **never falls back to the LAN IP** even if that gate is bypassed — defense in depth.

**Alternatives considered:** *(from the design's own trade study)*
- **Tailscale/WireGuard mesh** — rejected as the default (centralized control plane, not for open
  discovery); kept as the pragmatic pick for among-friends private streams.
- **Cloudflare Tunnel / CDN** — rejected: Cloudflare discourages media streaming over tunnels and
  becomes a trust point that sees everything, against the sovereignty goal.

**Rationale:** Onion mode was the smallest change that fit the "no platform" ethos — discovery is
already just a URL on Logos Messaging, so it is mostly a URL swap plus a SOCKS-routed player. No
account, no domain, no CDN. Audio's low bitrate fits Tor's bandwidth.

**Known limitation:** Hides the IP, not the fact that you are using Booth — not anonymity against
a global passive adversary. Added latency and lower bandwidth (fine for audio, not video); first
connect is slow (descriptor publish + rendezvous). Tor HS descriptors can go dark on flaky HSDir
uploads; a station restart republishes (tracked #38/#46). Onion mode is implemented and has been
run across two machines; the fully-integrated in-AppImage GUI flow carries the HS-descriptor
reliability caveat above.

---

## ADR-5: Station identity is a secp256k1 key, not a name — signed announces, 3-word fingerprint, 3 tiers

**Decision:** When an identity is set, every announce is **signed with secp256k1 ECDSA over
SHA-256 of the canonical compact-JSON announce bytes**; the 33-byte compressed public key is
embedded in the signed object and the 64-byte compact signature accompanies it (signed announces
are `v:2`, unsigned `v:1`). A station "is its public key, not its name," so copying a station's
name cannot impersonate it. Humans verify via a **3-word PGP-wordlist fingerprint** of
`SHA-256(pubkey)` (e.g. `newborn vocalist uncut`), shared out-of-band. Three identity tiers:
**Anonymous** (unsigned), **Autogenerated** (device-local persisted key, pseudonymous), and
**Keycard** (hardware-backed via `deriveKey("bc:radio")` — same identity on any device holding
the card, private key never leaves it).

**Alternatives considered:** Name-based identity (impersonable — rejected). Default-Anonymous vs
default-Autogenerated (leaning Autogenerated so pinning works out of the box).

**Rationale:** Impersonation-resistant, rename-invariant identity with no nameserver. Signing
lives in C++ because the QML sandbox cannot do crypto. The signed-bytes contract is a shared
byte-for-byte spec that Booth and Receiver must implement identically.

**Known limitation:** This is pseudonymity, not anonymity — a persistent fingerprint is pinnable
(hence the honest "IP hidden by Tor" framing rather than "anonymous"). First pin is
trust-on-first-use. Keycard stations cannot auto-resume (ADR-8).

---

## ADR-6: Two-module split — `radio_module` (core) + `radio_ui` (ui_qml); all I/O in C++

**Decision:** Booth ships as a core module (`radio_module`, owns MediaMTX/tor spawning, ffplay,
secp256k1 signing, `delivery_module` IPC, heartbeat/TTL, status polling) plus a `ui_qml` panel
(`radio_ui`) that drives it. Every operation the QML sandbox forbids — network, subprocess,
filesystem outside the module dir, base64 — lives in the C++ core.

**Alternatives considered:** A single monolithic module; QML doing its own I/O (impossible in the
sandbox); the original four-package layout (origin / discovery / player / ui), collapsed to two.

**Rationale:** The QML sandbox blocks network and subprocess access, so HLS playback, MediaMTX
status polling, process control and crypto must be C++. Splitting core from UI also lets the core
be exercised headlessly via `logoscore`.

**Known limitation:** A cross-module IPC contract (`radio_interface.h` `Q_INVOKABLE` surface) to
keep stable. Partly superseded by ADR-7, where the UI gained its own QtRO backend for the
universal migration.

---

## ADR-7: Universal-API migration — keep the legacy core, reach it from a universal UI (Option A)

**Decision:** For the v0.2 "universal API" platform migration, a universal `radio_ui` reaches the
legacy `radio_module` via `modules().radio_module.*` through a thin Qt Remote Objects backend
(`radio_ui.rep` + `radio_ui_backend.cpp`), forwarding actions and mirroring core state into
QML properties via a ~1.5 s async poll. Getters are async; **mutators that spawn subprocesses
(`startStream` → MediaMTX, `regenerateOnion` → tor) are fire-and-forget async** so they cannot
deadlock the ui-host event loop.

**Alternatives considered:** **Option B — migrate `radio_module` itself to universal
(`LogosModuleContext`)** — rejected as larger, touching the broadcaster core, with no payoff for
a single consumer; deferred unless Option A hit a wall (it did not). Synchronous mutator calls —
rejected (would deadlock the ui-host loop).

**Rationale:** Smallest change; one module migrates; mirrors the path the Receiver proved first.

**Known limitation:** State reaches the UI by poll, not push. `startStream` being
fire-and-forget means MediaMTX spin-up is not verifiable headlessly — it needs a GUI run (a
"wetware" gap). Two build walls surfaced and were fixed (the `"main"` metadata field gates
backend compilation; the core's async callback signature is `std::function<void(QString)>`).

---

## ADR-8: Persist the station and auto-resume on launch — except Keycard identities

**Decision:** Booth persists the station to `$XDG_DATA_HOME/radio_module/station.json` with
`running: true`; on launch `resumeStreamIfPersisted()` re-spawns MediaMTX + tor and
re-announces. Stream identity (path + key) is stable across stop/start/restart — minted only when
absent, rotated only on explicit `regenerateKey()`/`regenerateOnion()`. `stopStream` writes
`running: false` (keeps the identity, no auto-resume).

**Alternatives considered / by design:** A **Keycard** station **must not auto-resume** — the key
cannot be re-derived at boot with no card present, and resuming would broadcast a wrong/unsigned
identity, so it refuses. Clearing `station.json` on a transient spawn failure — rejected (a port
race would lose the key).

**Rationale:** For unattended headless stations (e.g. Parallel Society Radio on an always-on box),
"survive a reboot" reduces to "keep the app alive under systemd" — the station rides along.

**Known limitation:** Unattended boxes must use Autogenerated identity (Keycard is human-attended
only). Derived fields like `announceTopic` are read verbatim on resume, not re-derived (see ADR-3).

---

## ADR-9: Capture stays external (OBS/Liquidsoap); MediaMTX origin; HLS to listeners; ffplay not Qt Multimedia

**Decision:** Booth never captures media. A host points **OBS Studio** (live) or **Liquidsoap**
(headless automated DJ) at a Booth-minted ingest URL over **WHIP (8889) / RTMP (1935) / SRT
(8890)**; Booth spawns a **MediaMTX** origin that re-serves the stream as **HLS `.m3u8` (8888)**,
status on 9997. Publishing requires the stream key (`user=publisher&pass=<streamKey>`); HLS read
is public. Local listen-back is `ffplay -nodisp -autoexit <m3u8>` via `QProcess` (pause/resume
via SIGSTOP/SIGCONT) — **not** Qt Multimedia.

**Alternatives considered:** Qt Multimedia / `QMediaPlayer` — rejected: `libQt6Multimedia.so` is
not bundled in the Basecamp AppImage and importing it fails *silently* at runtime. In-module
mic/cam capture — non-goal (OBS does it). WHEP per-listener output — deferred (adds origin state);
v1 uses plain HLS.

**Rationale:** No media stack to embed, broad ingest compatibility, and audio plays fully
in-sandbox via a subprocess.

**Known limitation:** ~10 s HLS latency (fine for broadcast radio). **Audio-first only** in
v0.2.x — a QML view cannot embed video, so even when OBS pushes A/V, listeners hear audio.

---

## ADR-10: Direct origin delivery in v1; peer-assisted swarm deferred to Phase 2

**Decision:** Every listener pulls HLS directly from the host's single MediaMTX origin (optionally
Tor-tunnelled). The design is explicit: **decentralized discovery, direct per-host delivery** —
there is no P2P media swarm in v1.

**Alternatives considered:** A peer-assisted swarm to remove the origin-uplink limit — deferred to
Phase 2 ("don't pre-optimize").

**Rationale:** Simplicity — a swarm is real complexity with no payoff until an audience actually
strains a host's uplink.

**Known limitation:** The origin uplink is the scaling ceiling — the host's bandwidth caps the
audience. Tor mode helps with NAT but not with the uplink cap.

---

## ADR-11: Runtime binaries are not bundled — first-launch dependency preflight instead

**Decision:** MediaMTX, tor, ffmpeg and torsocks are **not** shipped inside the `.lgx`; they
resolve via `RADIO_*_BIN` env override → `<module-dir>[/bin]/<tool>` → `PATH`. v0.2.1 adds a
first-launch **dependency preflight** (#53) that checks for them and shows a copy-able install
command rather than failing opaquely.

**Alternatives considered:** Bundling the binaries in the LGX — blocked upstream on
`logos-module-builder#114`.

**Rationale:** Given the packaging limitation, an explicit preflight is the honest fallback — it
turns a silent `mediamtx_not_found` into an actionable prompt.

**Known limitation:** The operator still installs the binaries themselves; the preflight surfaces
the gap but does not close it. `delivery_module` is likewise a hard, **version-pinned (v0.1.1),
non-bundled** dependency — a newer build drifts the `Q_INVOKABLE` signatures and crashes the load,
so the exact pinned LGX must be installed.
