# How radio + receiver work

Decentralized audio broadcast on [Logos](https://logos.co). A host broadcasts; listeners
**discover the station over LogosMessaging by topic** — no central index, no account. The
differentiator is **discovery, not delivery**.

Two modules cover both roles:

- **radio** — the full app: a host **broadcasts** (Stream tab) *and* a built-in **listener**
  discovers-and-plays (Listen tab).
- **receiver** — a lightweight **listen-only companion**: discovers the same `radio` hosts and
  plays them, with no hosting / no MediaMTX / no hidden service of its own.

They never talk to each other directly — they **rendezvous on a shared LogosMessaging topic**.

---

## Radio — the broadcaster (+ built-in listener)

```
OBS Studio (capture)
        │
  [ Stream tab: name · Public/Private · Start ]
        │
   radio_module (core)
        │
        ├── Mints ingest URL (WHIP / RTMP / SRT) → OBS pushes into it
        │
        ├── Runs MediaMTX origin
        │         └── serves the stream as HLS (.m3u8)
        │
        ├── Fronts the origin with a Tor hidden service  🧅
        │         └── persistent .onion URL (no IP on the wire, NAT-traversing)
        │
        └── announce(name, .onion url, uptime) → delivery_module (LogosMessaging)
                  ├── Public  → well-known directory topic  /radio-basecamp/1/directory/json
                  ├── Private → unguessable per-stream topic /radio-basecamp/1/<random>/json
                  └── re-announces every 15s (heartbeat); listeners expire it after 45s (TTL)
```

1. **Capture** — point OBS at the generated ingest URL (WHIP/RTMP/SRT)
2. **Origin** — MediaMTX ingests and serves the stream as HLS `.m3u8`
3. **Hide** — a Tor hidden service fronts the origin; the announce carries a `.onion`, never an IP
   (Direct/LAN mode is opt-in and *does* expose host↔listener IPs)
4. **Announce** — `radio_module` publishes a heartbeat over LogosMessaging; **Public** lands on the
   shared directory topic, **Private** on an unguessable topic shared out-of-band (e.g. a DM)
5. **Discover & play** — any listener subscribed to that topic sees the station and pulls its HLS

---

## Receiver — the listen-only companion

```
        (no OBS · no MediaMTX · no hidden service)
        │
  [ Receiver panel ]
        │
   receiver (ui_qml + C++ backend)
        │
        ├── Subscribes to the directory topic → delivery_module (LogosMessaging)
        │         └── same /radio-basecamp/1/directory/json the host announces on
        │
        ├── Renders live stations as heartbeats arrive (name · host · uptime)
        │         └── drops a station after 45s of silence (TTL)
        │
        └── Play → pulls the announced .onion HLS over Tor  🧅
                  ├── Linux : torsocks in front of ffplay
                  └── macOS : privoxy HTTP→SOCKS bridge in front of ffplay (no torsocks on mac)
```

1. **Subscribe** — `receiver` joins the **same LogosMessaging directory topic** as `radio` hosts
2. **Discover** — live `radio-basecamp` stations appear (~10–15s) from their heartbeats
3. **Play** — tap a station; audio is pulled from the host's `.onion` over Tor — a plain HTTP pull,
   no peer connections

---

## Where they meet — the shared discovery plane

The host and every listener only ever share **the LogosMessaging topic**. No server sits between
them; the audio itself is a direct (Tor-tunnelled) HTTP pull from the host's origin.

```
   radio host                LogosMessaging topic                 listeners
       │                  /radio-basecamp/1/directory/json            │
 announce(.onion) ──15s──▶  ┌───────────────────────────┐  ──────────▶│  radio  (Listen tab)
                            │   delivery_module (Waku)    │  ──────────▶│  receiver (panel)
                            └───────────────────────────┘             │
                                  (heartbeat in · TTL out)            │
       ◀═════════  audio: listener's ffplay pulls HLS over Tor 🧅 ═══════════▶
                   (host's .onion ← origin/MediaMTX → torsocks/privoxy → ffplay)
```

- **Discovery** rides LogosMessaging (`delivery_module`) — heartbeat-only, no Store/history.
- **Delivery** is out-of-band: a Tor-tunnelled HTTP pull of HLS straight from the host's origin.
- **radio**'s Listen tab and **receiver** are interchangeable listeners on the same topic; receiver
  is the minimal one (no broadcast machinery), and interops with live `radio-basecamp` hosts.

> Platform note: both consume `delivery_module`. On Linux this functions on the **268-era** Basecamp
> build; newer builds regress third-party delivery consumers (logos-basecamp#150,
> logos-delivery-module#31). On macOS, receiver uses the relay architecture and works on a host with
> cpp-sdk ≥ #68. See each module's README "Compatibility" section.
