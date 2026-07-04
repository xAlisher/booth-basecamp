# Radio upgrade (#26) — fork-tree log

Red-team log of the radio-basecamp upgrade: **broadcasting-only (#39) → Universal API (#40) → design-system (#41)**.
Methodology: `~/fieldcraft/protocols/red-team-fork-tree.md`. Reuses the receiver-basecamp v0.2.0 playbook
(receiver#20 universal fire-and-forget, receiver#17/#19 design-system). Branch `feat/radio-broadcast-universal-ds`
(git worktree off `main`, so the `feat/parallel-society-radio` branch is untouched).

Baseline: `radio_ui` is **pure-QML** (`logos.callModule("radio_module", …)`), legacy, bespoke dark theme,
Stream+Listen tabs. `radio_module` is a legacy **core** (deps: delivery_module). Per-module flakes.

---

## Phase 1 — Broadcasting-only (#39)
- **Move:** strip the Listen tab + listener machinery from `radio_ui/Main.qml`. Single-view (Stream) body,
  no TabBar. Keep header/pills, Stream form, credentials card, activity log. radio_module's listener
  methods left in place for now (unused) — removed/trimmed during the universal pass (Phase 2) to avoid a
  risky core change here.
- **Result:** ✅ `nix build .#lgx-portable` → `Done: logos-radio_ui-module.lgx`. qmllint clean (only cosmetic layout warnings matching existing style), braces balanced, zero leftover listen refs. radio_module listener methods (startDiscovery/play/stop/setVolume/setListenBuffer/addTopic/getStations) left in radio_interface.h — trim in Phase 2.

## Phase 2 — Universal API (#40) — options
Two live options for how `radio_module` (legacy core) is reached from a universal `radio_ui`:
- **(A) Keep radio_module legacy; universal radio_ui → `modules().radio_module.*`.** Proven on receiver
  (universal receiver_ui → legacy delivery_module). Smallest change, one module migrates. Sync-deadlock
  risk on long/blocking calls (startStream spawns MediaMTX) → fire-and-forget per receiver#20.
- **(B) Migrate radio_module to universal too** (LogosModuleContext). Larger, touches the broadcaster core;
  no clear payoff for a single consumer. Deferred unless (A) hits a wall.
- **Chosen:** (A) — mirrors the proven receiver path. Documented; revisit if it walls.

## Phase 3 — Design-system (#41)
- Replace bespoke `Dark*`/`StatusPill` + hand-rolled palette with `import Logos.Theme`/`Logos.Controls`.
  Reuse receiver's `logos-design-system-adoption` + `delivery-connection-state-pill` skills.

## Headless test plan
`nix build .#lgx-portable` (radio_ui + radio_module) green; standalone `nix run` brings up the broadcaster
(MediaMTX spawns, stream key mints, delivery announces) without the Listen path. Diag to a file trail.

## Phase 2 — concrete scaffold plan (turnkey, from receiver templates)
radio_ui is pure-QML today (no src/). Add the universal QtRO backend (thin forwarder → modules().radio_module):
- **metadata.json:** add `"interface":"universal"`, `"codegen":{"rep":"src/radio_ui.rep"}` (keep `view:"Main.qml"`, deps `["radio_module"]`).
- **src/radio_ui.rep:** PROPs the QML binds (streamState, streamPrivacy, onionAddr, onionReady, onionError, deliveryState, streamCardJson, lastError) + SIGNAL(activity) + SLOTs (startStream(QString), stopStream(), regenerateKey(), regenerateOnion()).
- **src/radio_ui_backend.{h,cpp}:** `RadioUiBackend : RadioUiSimpleSource, LogosUiPluginContext`. `onContextReady()` → 1.5s poll timer.
  - **Getters** (getStreamStatus/getDeliveryStatus/getStreamCard) → **async** (`*Async` + callback updates PROPs). radio_module is an already-running core with quick getters, so the async reply should fire (unlike receiver's gated createNode) — but this is the headless bet to verify first (trivial-experiment).
  - **Mutators that spawn subprocesses** (startStream→MediaMTX, regenerateOnion→tor) → **fire-and-forget async** (receiver#20 lesson: sync would deadlock the ui-host loop). stopStream/regenerateKey likely safe but keep async for consistency.
- **CMakeLists.txt:** SOURCES src/radio_ui_backend.{h,cpp}; INCLUDE_DIRS src.
- **flake.nix:** already newest builder + radio_module path input — no change (radio_module's radio_interface.h Q_INVOKABLE surface is what codegen reads for modules().radio_module).
- **Main.qml:** `logos.callModule("radio_module",m,a)` → `logos.module("radio_ui")` backend: bind PROPs (streamState etc.) instead of the getStreamStatus/getDeliveryStatus poll Timers; call SLOTs via `logos.watch(backend.startStream(cfg), ok, err)`. Drop callParse/call; keep the activity log fed by the `activity` SIGNAL + PROP-change handlers.
- **radio_module trim (optional, Phase 2b):** remove the listener Q_INVOKABLEs (startDiscovery/play/stop/setVolume/setListenBuffer/addTopic/getStations) from radio_interface.h + radio_plugin — pure broadcaster core. Risky (core rebuild) → separate commit, headless-verify.

### Headless test gate (must be green before merge)
1. `nix build .#lgx-portable` (radio_ui) — backend compiles + codegen emits modules().radio_module. 
2. Standalone `nix run` (or install+launch) — backend onContextReady wires; getStreamStatus async reply updates streamState PROP (diag trail); startStream fire-and-forget brings MediaMTX up server-side (radio_module logs "mediamtx"), streamCardJson PROP populates. No ui-host freeze (State: S, /proc/wchan not do_wait-stuck).
3. If async getter reply doesn't fire (receiver Node-6 wall) → fire-and-forget + poll radio_module via a side channel, OR reconsider option (B).

_Status 2026-07-04: Phase 1 shipped (green, committed 1st commit). Phase 2 scaffold specified; not yet written/built — it's the receiver-scale headless push (deadlock investigation)._

## Phase 2 — build gate: ✅ GREEN (2026-07-04)
- **Two walls cleared:**
  1. **`"main"` field gates the backend.** `mkLogosQmlModule.nix` line 53: `hasBackend = config.main != null`.
     Without `"main": "radio_ui_plugin"` in metadata.json, the builder goes QML-only ("Copied QML entry
     file") and never compiles the backend/codegen — regardless of `.rep`/CMakeLists/`interface`. Added it.
  2. **radio_module's async callback is `std::function<void(QString)>`** (the return value directly), NOT
     `void(LogosResult)` like delivery_module. Fixed all 5 callbacks: `[this](QString s){ applyX(s); }`.
- **Result:** `Linking radio_ui_plugin.so`, codegen `Generated: radio_module_api.h/.cpp` from
  radio_module's `radio_interface.h`, `rep_radio_ui_source.h` generated, `Done: logos-radio_ui-module.lgx`.
  So a universal ui_qml reaching a **legacy core we own** works (codegen reads the dep's Q_INVOKABLE header).
- **Next:** rewrite Main.qml (callModule → logos.module + PROPs), then standalone headless test (async
  getter reply fires? startStream fire-and-forget brings MediaMTX up?).
