# Cross-module delivery events: GUI vs. headless `logoscore`

> Investigator notes (Sina) for the **Meshtastic ↔ Logos Messaging relay** question
> (vpavlin, #logos-core, 2026-06-25). Verdicts are tagged with confidence and backed by
> source links. Permalinks are pinned to commit SHAs so line numbers don't drift.

> **Update 2026-06-25 (after vpavlin's experiment).** The seed was deployed correctly, but
> under **bare `logoscore`** on the Pi, `delivery_module` received **zero inbound**
> (`messageReceived = 0`) — the block is **upstream of the gateway event**, so the seed
> can't reach it. This **refutes the "delivery receives, only the gateway event is blocked"
> model below for the headless case** — that model was an inference from the token
> architecture, never a bare-`logoscore` measurement. Our 24/7 "headless" setup is the
> **GUI AppImage under a display**, not `logoscore`, so we never had bare-`logoscore`
> inbound data. **Confirmed path for the Pi: GUI-under-xvfb.** See
> [§ Update: the headless experiment](#update-the-headless-experiment-2026-06-25).

## The question

Two parts, asked while bringing up a Basecamp core module (a Meshtastic↔Logos Messaging
relay) **headlessly via `logoscore`** on a Raspberry Pi:

1. **Why** do cross-module *method calls* work but *events* (provider→consumer) never fire
   under headless `logoscore`, while the GUI Basecamp works — same `liblogos_core`?
2. Is the **`ui_qml`+C++-backend shape mandatory** to receive delivery events under the
   GUI/ui-host, or can a `type: core` consumer receive them once the bootstrap has run?

## TL;DR

- **#1 — Root cause is real and known: [logos-basecamp#150](https://github.com/logos-co/logos-basecamp/issues/150).**
  The capability-token **bootstrap is the *host's* job**. The Basecamp GUI host does it;
  `logoscore`-cli does not. Same `liblogos_core`, different host → handshake never seeds →
  events dropped. `[CONFIRMED]`
- **#2 — The `ui_qml`+backend shape is *not* mandatory.** A `type: core` consumer receives
  delivery events under the GUI host once the bootstrap has run. We have a working one
  (`radio_module`) with **no UI backend and no token hack**. `[CONFIRMED]`
- **What we did is a *workaround*, not a fix.** #150 is still open. `[CONFIRMED]`

---

## #1 — Why GUI works and headless `logoscore` doesn't

The capability-token bootstrap (`informModuleToken` distribution) is performed by the
**Basecamp host loader**, not by `logoscore`. Both wrap the same `liblogos_core`, but only
the GUI host seeds tokens at plugin load. Without it, a third-party plugin's first
cross-module call provisions with an **empty** token, which the SDK rejects — so both real
method returns *and* event authorization fail.

This is upstream **[logos-basecamp#150 — "Third-party core plugins have no token bootstrap
path"](https://github.com/logos-co/logos-basecamp/issues/150)** (OPEN).

Independently corroborated in this repo: our `logoscore` smoke test deliberately drops the
`delivery_module` dependency and asserts only `ping()`, because bare `logoscore` can't
complete the handshake for *any* module —
[`radio_module/tests/run-headless-tests.sh#L8-L13`](https://github.com/xAlisher/radio-basecamp/blob/27198c5ae1c1fa73fd24c1f432a3278e1ea99683/radio_module/tests/run-headless-tests.sh#L8-L13):

> *"Bare standalone logoscore's capability-token handshake fails for EVERY module
> (confirmed: canonical `capability_module.requestModule` also returns `false`)."*

### How we run it headlessly anyway

We **do not use `logoscore`** for the live deployment. The 24/7 "headless" server runs the
**full Basecamp GUI AppImage** backgrounded with a display (`launch-khidr.sh` / `relaunch.sh`).
That is the GUI code path, so the bootstrap runs and inbound events flow. On `aarch64`/RPi
that doesn't transplant directly (our AppImage is x86_64) — the durable fix is #150.

---

## #2 — A `type: core` consumer **does** receive events under the GUI host

**Verdict: the `ui_qml`+C++-backend shape is not required for event receipt under
GUI/ui-host.** `[CONFIRMED]`

`radio_module` is the existence proof — it is `type: core` and its entire discovery feature
is built on inbound `messageReceived` events from `delivery_module`:

- Type & dependency:
  [`radio_module/metadata.json`](https://github.com/xAlisher/radio-basecamp/blob/27198c5ae1c1fa73fd24c1f432a3278e1ea99683/radio_module/metadata.json)
  (`"type": "core"`, `"dependencies": ["delivery_module"]`)
- Wiring — plain `getClient` → `requestObject` → `onEvent`, **no UI backend, no token seed**:
  [`radio_module/src/radio_plugin.cpp#L569-L587`](https://github.com/xAlisher/radio-basecamp/blob/27198c5ae1c1fa73fd24c1f432a3278e1ea99683/radio_module/src/radio_plugin.cpp#L569-L587)

```cpp
m_delivery    = logosAPI->getClient("delivery_module");        // :532
m_deliveryObj = m_delivery->requestObject("delivery_module");  // :575
m_delivery->onEvent(m_deliveryObj, "messageReceived", …);      // :577
```

Receipt was verified cross-machine on the GUI build: `received relay message …
payloadSizeBytes=210`. So once the GUI host runs the bootstrap, a bare core consumer's
events flow with **none** of the hacks we use elsewhere.

### Why this should hold for your core consumer specifically `[CONFIRMED — SDK source]`

Events ride the **same QRO replica as calls**: `requestObject` returns the replica, `onEvent`
subscribes its `eventResponse` signal, and `invokeRemoteMethod` calls over the same
connection. Your calls already work → the replica is connected and authorized → events come
over it too. The "calls work, events don't" split is the **headless/no-bootstrap** artifact;
under the GUI path (capability actively distributing tokens) it closes.

### What the token hack is actually for (and isn't) `[CONFIRMED]`

The `TokenManager::saveToken(...)` pre-seed lives only in **receiver's ui-host backend** —
[`receiver-basecamp/src/receiver_ui_plugin.cpp#L133-L137`](https://github.com/xAlisher/receiver-basecamp/blob/90351731439b18e3661e57f2b3abdddc3f8140b3/src/receiver_ui_plugin.cpp#L133-L137):

```cpp
TokenManager& tm = TokenManager::instance();
if (tm.getToken("delivery_module").isEmpty())
    tm.saveToken("delivery_module", "receiver_bootstrap_v1");   // any non-empty string
m_delivery = m_logosAPI->getClient("delivery_module");
```

It exploits an inverted token-check (the only real gate is an `isEmpty()` reject, so any
non-empty string passes) to make `getClient` resolve **without** the GUI bootstrap. It is a
workaround for the #150 hole — **not** something the event path needs. `radio_module` proves
the GUI path needs neither a UI backend nor this seed.

### The one axis that *would* force a restructure `[? — build-dependent]`

Our move of `receiver` into a `ui_qml`+C++ backend was **not** about event flow. It was that
on **newer Basecamp builds the bare-core `getClient("delivery_module")` crashes at load**
(`std::length_error` / SIGSEGV in `LogosAPI::getClient`) — upstream
**[delivery-module#31](https://github.com/logos-co/logos-delivery-module/issues/31)** (OPEN) —
plus macOS. The crash is specifically the typed-SDK ctor (`new LogosModules(api)`); raw
`getClient` + `invokeRemoteMethod` avoids it on the builds where it works. Since your core
`getClient` already resolves for calls, you are not hitting this.

**Guidance:** keep the core consumer for the GUI path; events flow once the bootstrap runs.
Restructure into a UI backend only if you move to a build where `getClient` itself crashes at
load.

---

## Update: the headless experiment (2026-06-25)

The seed (below) was deployed and correct, and vpavlin ran it on the Pi. Result:

| Observation | Verdict |
|---|---|
| Seed implemented per this doc; gateway loads; **outbound** (mesh→LM) works | ✅ |
| Off-mesh publish + encryption correct (laptop decrypted the messages) | ✅ |
| **GUI host path** receives inbound fine (on the laptop) | ✅ — confirms our deployment method |
| **Bare `logoscore`** on the Pi: delivery's inbound `messageReceived = 0` | ❌ — nothing received |

**This refutes the model in this doc for the headless case.** The doc assumed *"delivery
receives + emits, only the gateway event is blocked, so the seed fixes it."* That was an
**inference from the capability-token architecture, never a bare-`logoscore` measurement.**
Under bare `logoscore` the block is **upstream of the gateway event**: delivery itself logs
zero inbound, so there is no emitted event for the seed to authorize. **The seed alone cannot
unblock bare `logoscore`.** `[REJECTED for headless]`

**Why we had no data:** our 24/7 "headless" deployment is the **GUI AppImage under a display**
(`launch-khidr.sh`: `export DISPLAY=:0` + `nohup "$APP"`), **not `logoscore`**. We had never
landed an inbound delivery message under bare `logoscore`. So vpavlin tested virgin territory.

### Confirmed path for the Pi `[CONFIRMED]`

**Run the GUI host under `xvfb`** (the path we use, the one shown to receive inbound). The
seed/`ui_qml` discussion above applies to the GUI/ui-host path; bare `logoscore` is not a
proven host for inbound delivery on either side.

### Before fully closing it — one diagnostic fork `[? — measurement resolves it]`

`messageReceived = 0` means different things depending on **whose counter** it is:

- **Delivery's *own* log/metric (0 frames off the network)** → this is a **networking /
  subscribe** problem, *not* the capability layer. Delivery's Waku relay does **not** need a
  capability token to receive from the network — so it *should* receive under bare `logoscore`
  **if it is subscribed and has relay peers**. The `logos.dev` preset ships **zero bootstrap
  nodes** (`bootstrapNodes=0 → currentPeerIds=[]`); we had to supply entry multiaddrs
  explicitly →
  [`receiver_ui_plugin.cpp#L143-L163`](https://github.com/xAlisher/receiver-basecamp/blob/90351731439b18e3661e57f2b3abdddc3f8140b3/src/receiver_ui_plugin.cpp#L143-L163).
  **A peerless node receives 0 inbound regardless of host** — rule this out first
  (`getNodeInfo` peer count; confirm `subscribe` registered).
- **Your gateway's `onDeliveryMessage` (delivery received but didn't push to you)** → *that's*
  the seed's domain (the Layer-B story this doc described).

So: if delivery's own log shows frames arriving while your callback stays 0 → clean evidence
for the seed / #150 story. If delivery's own log shows 0 **with confirmed peers + subscribe**
→ a separate, bigger gap (delivery networking under `logoscore`) that deserves its own issue.

### The seed itself (for the record)

Right before `getClient`, seed both names — your blocked direction is *inbound*
(delivery → your module), which needs `delivery_module` to hold a token for **your** module:

```cpp
TokenManager& tm = TokenManager::instance();
tm.saveToken("delivery_module", "x");          // so your outbound calls pass
tm.saveToken("<your_module_name>", "x");       // so delivery is authorized to push events back to you
```

Per the experiment above, this is **necessary-but-not-sufficient under bare `logoscore`**: it
addresses the consumer-authorization layer, but does nothing if delivery isn't receiving
inbound in the first place.

---

## References

| Ref | What | State |
|---|---|---|
| [logos-basecamp#150](https://github.com/logos-co/logos-basecamp/issues/150) | Third-party core plugins have no token bootstrap path | OPEN |
| [delivery-module#31](https://github.com/logos-co/logos-delivery-module/issues/31) | Core module consuming `delivery_module` SIGSEGVs in `getClient` | OPEN |
| [logos-basecamp#169](https://github.com/logos-co/logos-basecamp/issues/169) | Dev `.lgx` trips the 2s `logos_host` token-handshake timeout | OPEN |
| basecamp-skills | `sdk-capability-token-architecture`, `whole-archive-module-proxy-strip`, `standalone-logoscore-isolation` | — |

*Code permalinks pinned to: radio-basecamp `27198c5`, receiver-basecamp `9035173`.*
