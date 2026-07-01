# Parallel Society Radio — content inventory

Source table for the station library (issue **#28**). Feeds ripping/normalisation (**#29**) and
programming (**#31**). Primary anchor: **https://www.youtube.com/@Logos_network**.

**Status:** ✅ YouTube sweep complete · ✅ scope confirmed **festival-only (A+B, 13 items)** · ✅ rip+loudness pipeline verified (`loudnorm.sh`) · ⏳ Discord sweep deferred (optional).

Content splits into **two events** on the channel:
- **Parallel Society festival** (recent, 2026) — the target: **6 DJ/live sets** + **7 talks** (both tagged
  "| Parallel Society"). ~10h27m.
- **Parallel Society Congress: Bangkok 2024** — a *related, older* event: **9 governance talks**. ~5h09m.
  Listed below but **flagged — confirm whether to include** (may dilute the "festival" identity).

---

## A. DJ / live sets — "Parallel Society" playlist  (music bed · ~5h40m)
Pre-mastered live music → light touch, target **-14 LUFS** + gentle limiter. No heavy compression.

| type | title | artist | source_url | duration | notes |
|------|-------|--------|------------|----------|-------|
| DJ set | Apparat (Live) | Apparat | https://youtu.be/IMZRFVQ9Ysg | 31:42 | electronic/live |
| DJ set | Calibre (Live Set) | Calibre | https://youtu.be/qCzh4ccoT8E | 35:46 | dnb/liquid |
| DJ set | Gilles Peterson w/ MC Rob Galliano | Gilles Peterson | https://youtu.be/lnpJUTk4HP8 | 1:02:02 | broadcast/eclectic |
| DJ set | Kode9 (Live Set) | Kode9 | https://youtu.be/wVniGpG9Cv0 | 1:31:19 | longest — good evening anchor |
| DJ set | Los Bitchos (Live) | Los Bitchos | https://youtu.be/dKhD1ssUmWI | 58:54 | band/instrumental |
| DJ set | Moses Boyd (Live) | Moses Boyd | https://youtu.be/jFCfkt_sd5s | 59:04 | jazz/live drums |

## B. Talks — "Parallel Talks" playlist  (talk blocks · ~4h48m)
Speech → normalise + gentle compression, target **-16 LUFS**; trim intros/applause/dead air.

| type | title | speaker | source_url | duration | notes |
|------|-------|---------|------------|----------|-------|
| talk | Living Within the Truth | Jarrad Hope | https://youtu.be/xy4uK20lFBQ | 57:34 | keynote-ish; ties to the Logos demo track |
| talk | What it Takes to Advance Digital Rights in 2026 | Pavel Zoneff | https://youtu.be/bX63G-wm3JI | 19:35 | short — good filler |
| talk | DarkFi Workshop | Rachel Rose O'Leary | https://youtu.be/bqN4NgkoLAE | 42:27 | workshop |
| talk | Logos Execution Zone Architecture | Moudy El Laz | https://youtu.be/Vdli7PjIXUw | 43:49 | technical |
| talk | How To Build A Country | Vit Jedlicka | https://youtu.be/g5zkFrgZXag | 58:01 | Liberland |
| talk | Cyber-Guerilla Resistance by Counter-Economics & Digital Sabotage | Amir Taaki | https://youtu.be/5huwiZUmm30 | 27:00 | high-energy |
| talk | Thinking Sovereignty | Francesco Moiraghi | https://youtu.be/XwoqUDXUEbk | 40:19 | philosophy |

## C. Parallel Society Congress: Bangkok 2024 — related event  (~5h09m) — ⚠️ confirm inclusion
| type | title | speaker | source_url | duration | notes |
|------|-------|---------|------------|----------|-------|
| talk | Welcome | Joe Nakamoto | https://youtu.be/XtTwkkiLcps | 6:44 | short intro |
| talk | Why Parallel Society Congress? | Jarrad Hope | https://youtu.be/hC1zx4P2BQ4 | 5:09 | short |
| talk | Farewell to Westphalia: Post-Nation-State Governance | (panel) | https://youtu.be/xR5xO1DVpyo | 1:03:48 | long panel |
| talk | Accessing Justice via Decentralised Legal Systems | (panel) | https://youtu.be/ez3DW63vwOw | 50:29 | |
| talk | How Bitcoin Changed Emerging Markets | (panel) | https://youtu.be/H8cFfqUnfr8 | 41:29 | |
| talk | Zanzalu: Building a Growth Ecosystem in Africa | (panel) | https://youtu.be/8VruoETY324 | 47:40 | |
| talk | How Governments Can Benefit from Parallel Societies | (panel) | https://youtu.be/K1Xnckqgro8 | 29:01 | |
| talk | How to Start Your Own Pop Up Village | (panel) | https://youtu.be/c7NBsTh-4AA | 55:30 | |
| talk | Regenerative Public Goods for Sustainable Communities | (panel) | https://youtu.be/q-xlv_D7yqo | 49:11 | |

---

## Totals
- **Festival (A+B):** 13 items, **~10h27m** — the launch core.
- **+ Bangkok 2024 (C):** +9 items, **~5h09m** → 22 items, ~15h37m if all included.

## Sources swept
- [x] YouTube — `@Logos_network` playlists ("Parallel Society", "Parallel Talks", "Parallel Society Congress: Bangkok 2024")
- [ ] YouTube — "Parallel Society" off-channel search (other uploaders)
- [ ] Logos Discord — festival threads + pins (via `/gm` tooling) — **pending**

## Open questions for Alisher (confirm-the-set gate before #29)
1. **Include Bangkok 2024 Congress (group C)?** Or festival-only (A+B) to keep the identity tight?
2. **Trim the long DJ sets?** Kode9 is 1h31m — keep full or cap set length for rotation variety?
3. **Discord sweep** — worth it, or is the YouTube set enough for the DWeb Camp demo?

## Legend
- **type** — talk · DJ set · panel · other
- **notes** — loudness handling, clips to trim (intros/applause), permission-gated, language
