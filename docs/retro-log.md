# Retro Log

Raw captures, reshuffled into PROJECT_KNOWLEDGE.md / skills at `/retro`.

## Week of 2026-06-10 — synthesized (no inline /log captures this run)

### Wins
- [process] Unbuffered `fprintf(stderr)+fflush` markers cracked a crash that `qDebug` + swallowed
  ui-host stderr hid — pinpointed the exact line (`new LogosModules(api)`). Reach for this on any
  load-time crash, not gdb first.
- [process] User's leads ("hackyguru / fryorcracken", "check upstream") routed straight to the
  canonical `logos-delivery-demo` + upstream #31, which was the root cause. Following named people →
  their repos/issues beat re-deriving.
- [process] Isolated dual-AppImage run (separate binary + `XDG_DATA_HOME`) let radio run on the
  working older release without touching the other agent's 295 setup. Reusable ops pattern.
- [project] Cross-machine thesis demo works on `pre-release-1dc1c08-268`: separate listener discovers
  + plays over LogosMessaging, no central index.

### Fails
- [process] Chose `core + QML` architecture without reading delivery_module's OPEN issues; #31
  (core-can't-consume-delivery) was knowable on day one. Root cause: platform-state-check read the
  dep's API/headers but never `gh issue list` on the dep. → fieldcraft: platform-state-check now must
  scan the dep's open issues. (memory: feedback_check_dependency_open_issues)
- [process] Recommended AGAINST the ui_qml-C++-backend at the start as "needless complexity" — it's
  the ONLY supported delivery-consumption path. Root cause: dismissed the heavier tutorial option
  without checking whether the lighter one was supported for the deps in play.
- [process] Long crash-spiral: tried builder pin → SDK → delivery tag → call-pattern → defer-timing
  before adding logging / checking upstream. The two moves that worked (stderr markers, `gh issue
  list`) came only after the user prompted them. Root cause: kept hypothesizing fixes instead of
  isolating first.
- [project] `pkill -f 'LogosBasecamp.elf'` self-matched the agent's own shell command line and killed
  the shell mid-script (repeated silent exit 1). Root cause: `-f` matches the pkill invocation itself.
  Fix: kill by PID excluding `$$`. (→ PROJECT_KNOWLEDGE Operational gotchas)

### Skills touched
- Extracted `delivery-core-consume-crash` (basecamp-skills, integration/critical).
- Applied `logos-cpp-generator-typed-calls` (typed LogosModules) — still correct; the core-vs-ui_qml
  host is the missing caveat, captured in the new recipe's `## See also`.
