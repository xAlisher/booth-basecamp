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
holds its own `modules/` + `plugins/` (rsynced from a known-good machine). Run only ONE instance at a
time (shared ports). Modules must be portable-built (`$ORIGIN` rpath) to run cross-machine.

---

## Privacy

v1 = **sovereign discovery, NOT streamer anonymity.** `buildAnnouncePayload` puts `http://<lanIp()>…`
in the announce, and `ffplay` pulls directly from the origin — so any directory-topic subscriber learns
the host IP, and host↔listener IPs are mutually exposed on play. Today it's a LAN IP (LAN-scoped).
Hiding the streamer is mostly a *URL swap*: **Tor onion service** (recommended, audio-first fits Tor's
bandwidth) or **Tailscale mesh** (private streams). Full analysis: `docs/BRIEF.md §Privacy`.

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
