# Radio — presentation notes

Speaker notes for presenting **radio + receiver** (decentralized pirate radio on Logos), distilled
from the Berlin Blockchain Week lightning talk (2026-06-17, ~11 min incl. demo + Q&A). Use this as the
talk-track + demo script for the next run. Transcript:
[`2026-06-17-berlin-blockchain-week.transcript.txt`](2026-06-17-berlin-blockchain-week.transcript.txt).

---

## The one-liner

> **A pirate radio station you can run from an old machine under your stairs — broadcast anything,
> discovered peer-to-peer over Logos messaging, with your IP hidden behind Tor. No platform, no
> licence, no one to knock on your door.**

## Narrative arc (the spine — keep this order)

1. **Who I am — and the unlock.** "I'm not a builder. I don't write code." I orchestrate AI agents —
   they reverse-engineer Logos' proof-of-concept modules, document every function, and write the
   *skills* for building Basecamp modules. A morning pipeline keeps those skills current against a
   fast-moving codebase (new commits / issues / logoscore scans). → **That's why a module takes hours,
   not days.** (This is the credibility hook: speed via agent orchestration.)
2. **Why radio — the grievance.** Obsessed with music; hate Spotify and centralized platforms — what
   they pay musicians, what they extract, what they do with the money. Childhood love of radio (a
   little red FM receiver). Wanted a pirate station — but **real radio hardware is costly and the
   airwaves are government-owned**; you can't legally broadcast what you want.
3. **The idea.** Use Logos tech — messaging + storage — as **a framework for pirate radio stations**.
4. **What I built — `radio`.** Spins up an **RTMP server** any broadcaster can push to (OBS, or — as of
   this morning — **Liquidsoap**, the open-source automation tool real stations use for weekly/monthly
   programming). Content goes in; the module **announces the stream onto a Logos messaging topic**, so
   anyone with the module subscribes to that topic and **sees the stations** — no central index.
5. **The problem I hit, and the fix.** First version **leaked the streamer's IP** — "not really
   private; if you broadcast something people in power don't like, they can knock your door and jail
   you." → **Tor / onion hides the streamer's IP.** This is the whole point of the project: it protects
   the broadcaster.
6. **The lightweight half — `receiver`.** "Radio" felt heavy when you just want to *listen*. So I built
   **receiver** — listen-only. It shows the live stations (e.g. the "Logos manifesto" stream running
   headless 24/7 on my home server), with a **cache/buffer setting** to ride out a bad connection.
7. **Live demo.** Play the "Logos manifesto" station through receiver; show discovery + buffered Tor
   playback. (Have it *already cached* — see fix list.)
8. **The ask (call to action).** Got an old machine you don't use and something to share — music banned
   from Spotify, your own podcast, experimental tracks from friends, basement jam sessions? **Install
   it, put it on a loop, and let others listen.**

## Key lines worth keeping (they landed)

- "I'm not a builder. I don't write code." → reframes the whole talk as *agent orchestration*.
- "Hours, not days."
- "Air and the magnetic field are owned by the government — you can't broadcast what you want."
- "If you stream something people in power don't like, they can knock your door and jail you."
- The call-to-action list: *banned-from-Spotify music / your podcast / friends' experimental tracks /
  basement jam sessions → put it on a loop and let others listen.*

## Demo script (tight version)

1. **radio** open → "this spins up the RTMP server; OBS or Liquidsoap pushes into it."
2. Point at the **announce** → "it publishes the stream to a Logos messaging topic — that's discovery,
   no central server."
3. Name the **Tor/onion** line explicitly while a station is visible → "the announce carries a `.onion`,
   never your IP."
4. Switch to **receiver** → "listen-only. Here are the live stations." Tap **Logos manifesto**.
5. Call out the **buffer/cache** ("~20s to absorb Tor latency") *as it caches* — turn the wait into a
   feature, not dead air.
6. Let ~10–15s of the station play, then land the **ask**.

## Q&A prep (anticipated)

- **"How do you transmit the audio — a mixer?"** → A broadcaster app (OBS or **Liquidsoap**) pushes to
  the **RTMP server the radio module runs inside Basecamp**; the module fronts it with Tor and announces
  it over Logos messaging. (This was asked at BBW — have the crisp version ready.)
- **"Isn't this just internet radio / Icecast?"** → Discovery is **peer-to-peer over Logos messaging
  (no directory server)**, and the **streamer's IP is hidden by Tor** — no host, no account, no licence.
- **"What stops takedowns?"** → No central index to seize; the origin is a hidden service. (Honest
  limit: the origin must stay online — see roadmap; mirror/restream mesh is planned.)
- **"How is the listener sure it's the real station / same host?"** → Today: by topic. **In progress:**
  a Keycard-derived **signing identity** so a station is verifiable by key, not name (radio#24 /
  receiver#13), plus pin-and-notify (receiver#14).
- **"Latency? Quality?"** → Tor adds latency; the listener buffer (configurable, ~2–20s+) smooths it.
  Audio-first for v1.
- **"What does Logos provide vs. you?"** → Logos = messaging (discovery) + storage primitives + the
  Basecamp module runtime; I built the radio/receiver modules and the broadcast/onion/playback pipeline.

## Fix list — tighten before the next run

- **The demo had ~1.5 min of dead air** (06:30–08:30) waiting on the 20s cache + Tor bootstrap. **Pre-warm
  the stream so it's already playing**, or narrate the buffer as a feature, or cut to a pre-cached tab.
  Never let the room sit in silence waiting for Tor.
- **State the Tor/privacy payoff earlier and once, clearly** — it's the strongest point and it got
  slightly buried in the live flow.
- **Have the second station's real name on a slide** — it came out garbled ("reading the truth / the
  gyroscope"); know exactly what's playing.
- **Close on the ask, not the demo** — the call-to-action ("old machine, put it on a loop") is the best
  ending; make sure the music/demo doesn't run past it.
- **One slide with the two-box diagram** (host → Logos topic → listener, Tor on the wire) would carry the
  architecture faster than narrating it; see [`../HOW-IT-WORKS.md`](../HOW-IT-WORKS.md).

## Caveats

Terms above are corrected from the auto-transcript (Liquidsoap, FM, "not private", logoscore); the
second station name is unverified. Don't put unverified names on a slide without checking the running
station config.
