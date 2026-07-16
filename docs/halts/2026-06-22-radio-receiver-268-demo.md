# Halt — 2026-06-22  ·  ARCHIVED (demo succeeded)

> Resolved: the radio/receiver live-stream demo on the genuine 268 AppImage was a
> **success**. Archived 2026-07-02. Next steps below are obsolete; kept for context only.
> The durable AppImage-identity nugget is saved to memory (`appimage-268-identity-trap`).


## Where we stopped

Brought up the **radio/receiver demo on the genuine 268 AppImage** and got a headless
**liquidsoap source-client streaming an mp3** into the live station. All running and verified.
Earlier in the session (carried over): surfaced `MODULE-INTERACTION-GUIDE.md` from the
basecamp-skills index + the auto-loaded `~/basecamp/CLAUDE.md`, and backed up the loose
`~/basecamp/{CLAUDE,CODEX}.md` into the skills repo. Those are committed/pushed (done).

## Current state

- **radio-basecamp**: branch `main`, last commit `7a524a7` "retro(2026-06-16): Liquidsoap
  source-client recipe + non-destructive coexist launch; mediamtx provisioning gap (#21)".
  Working tree clean. Build: untouched this session (used the prebuilt release lgxs).
- **basecamp-skills**: branch `opus-4.8/triggers-and-preview`. Pushed commits this session:
  `5f6a7d4` (index → guide pointer), `afd80b7` (CLAUDE/CODEX backup in `basecamp-root-config/`).
- **Live runtime (all UP, verified):**
  - AppImage: `~/logos-basecamp-radio-only.AppImage` = genuine `pre-release-1dc1c08-268`
    (274422264 B, md5 `9c471d2`). Running.
  - Installed (profile `~/.local/share/Logos/LogosBasecamp/`): `delivery_module` v0.1.1
    (`1.1.0`, rev `0c346c0c`), `radio_module` 0.1.0, plugins `radio_ui` + `receiver_ui`.
    Both core modules loaded clean — NO crash.
  - `liquidsoap /tmp/station.liq` streaming the Cypherwave mp3 ("Living Within the
    Truth / Jarrad Hope") → `rtmp://127.0.0.1:1935/795e17453bd45944` (AAC 128k/FLV).
    MediaMTX path `795e17453bd45944` = `ready:true`, source `rtmpConn`, inbound climbing
    (~128 kbps). Verify: `curl -s http://127.0.0.1:9997/v3/paths/get/795e17453bd45944`.
- **Open review:** none.

## Next steps (in order)

1. **Test the GUI** (Alisher, hands-on): open **Radio → Listen** tab — the station should
   appear and play via `ffplay`; open **Receiver** panel to confirm discovery.
2. When done demoing: stop the stream — `pkill -f '[l]iquidsoap /tmp/station.liq'` — and the
   AppImage `for pid in $(pgrep -f '[r]adio-only'); do kill $pid; done`.
3. (Optional, offered earlier, not started) receiver-basecamp#? — add `delivery_module` to the
   `logos-repo.json` catalog so `lgpd install delivery` works (removes the manual step).

## Blockers

- **Radio runs ONLY on 268** (`pre-release-1dc1c08-268` = the `radio-only`/`x86_64` 274 MB build).
  Newer builds throw `std::length_error` in `getClient` at radio load (logos-delivery-module#31,
  logos-basecamp#150). Not fixable here — upstream.
- **receiver on macOS** still blocked upstream (cross-module SDK events don't dispatch; needs a
  new AppImage). Not in scope this session — Linux/268 demo is the path.

## Context that's hard to re-derive

- **AppImage identity trap (cost real time):** the file named `268-backup.AppImage` (270 MB,
  md5 `93eb43c4`) is **MISLABELED** — it's a newer 269+ build and crashes `radio_module` at load
  (`corrupted size vs prev_size`). The REAL 268 is the **274 MB** build = `radio-only` = `x86_64`
  = `khidr` (md5 `9c471d2`), matching the release's `x86_64.AppImage` asset size. Identify 268 by
  **byte size vs the release asset (274422264)**, never the filename. Saved to memory
  (`appimage-268-identity-trap`).
- **Streamkey is per-session and rotates.** `/tmp/station.liq` was the stale **khidr** instance
  pushing to dead path `61e3e063…`; I repointed it to the current `795e17453bd45944` /
  `pass=219ef44d07bbd7fcdac79c46ac46c26b`. If radio restarts/rekeys, re-pull path+key from the
  Stream tab (or mediamtx) and update the `output.url` in `/tmp/station.liq`, then restart liquidsoap.
- **Module load is on-demand on 268:** `delivery_module`/`radio_module` load ~60s after boot (when
  a consumer pulls them), not at startup. Don't conclude "didn't load" too early.
- **Runtime bins resolve from PATH:** `mediamtx` (nix), `ffplay`, `tor`, `torsocks` — all present,
  so Stream + Listen + onion all functional. The release lgx does NOT bundle mediamtx (only
  `scripts/install.sh` drops it into the module dir); PATH covered it here.
- **`pkill -f` self-match gotcha:** if the AppImage name or `logos-basecamp` path is in the same
  command, `pkill -f` kills its own shell (exit 144). Kill with bracketed patterns
  (`[l]ogos-basecamp`, `[r]adio-only`) in a command separate from any launch.
- liquidsoap source = a watched **playlist dir** (Soulseek `Cypherwave/`), not a literal file;
  `mksafe` → silence (not crash) if the dir empties.
