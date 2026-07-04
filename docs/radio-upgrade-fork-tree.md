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
