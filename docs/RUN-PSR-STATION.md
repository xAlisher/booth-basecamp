# Running Parallel Society Radio (PSR) — Operator Guide

How to run the live station end-to-end. Written so a fresh agent can bring it up, check it, and fix
the common failures without prior context. Last verified **2026-07-05**.

---

## 0. Where it runs

The station runs entirely on **Sneg** (`ssh snezhok`, user **`sher`**) — the broadcaster box with the
music library. Your laptop is only a *listener* (via the Receiver module). Everything below is run on
Sneg unless noted. All services are **systemd `--user`** units, so:

```bash
ssh snezhok
export XDG_RUNTIME_DIR=/run/user/$(id -u)   # needed for systemctl --user over ssh
```

---

## 1. Is it running? (30-second health check)

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
# the moving parts:
for s in logos-radio-xvfb logos-radio-app logos-radio-psr psr-onion-monitor.timer; do
  echo "$s: $(systemctl --user is-active $s)"; done
# is MediaMTX ingesting the feed? (ready:true + bytesReceived climbing = liquidsoap is streaming in)
curl -s localhost:9997/v3/paths/get/33a5971eeba1d06a | grep -oE '"ready":[a-z]+|"bytesReceived":[0-9]+'
```

Healthy = all `active`, `"ready":true`, and `bytesReceived` grows between two calls.

**Reachability (is the onion live for listeners?)** — see §6; a live feed can still be dark on Tor.

---

## 2. Architecture — the signal path

```
 station.liq (playout)                                    Tor hidden service
      │ liquidsoap                                              │ (onion)
      ▼  RTMP aac/128k → 127.0.0.1:1935                         ▼
  ┌──────────────── radio_module's MediaMTX ────────────────────────┐
  │  RTMP :1935 ingest → HLS :8888 (hlsAlwaysRemux) → API :9997      │
  └─────────────────────────────────────────────────────────────────┘
                          │  HLS over the onion
                          ▼
                Receiver module (listener) → ffplay
```

- **liquidsoap** = the playout brain (picks tracks, mixes, encodes AAC, pushes RTMP).
- **radio_module** (inside a headless Basecamp) = runs **MediaMTX** (the media server) + **Tor** (the
  onion hidden service). It ingests the RTMP feed and serves it as HLS over the onion.
- **MediaMTX ports:** RTMP `1935` (ingest), HLS `8888`, API `9997`, WHIP `8889`, SRT `8890`.

---

## 3. The four services (what each does)

| Service | Role |
|---|---|
| `logos-radio-xvfb.service` | Virtual display `:99` (the Basecamp app is a GUI app run headless). |
| `logos-radio-app.service` | The **host**. Runs `~/radio-station/run-app.sh`: launches the Basecamp AppImage on `:99`, waits for boot (~80s), clicks the radio panel → `radio_module` loads → auto-resumes the `running:true` station → spawns **MediaMTX + Tor**. Restarts on exit. |
| `logos-radio-psr.service` | The **feed**. `liquidsoap /mnt/music/parallel-society-radio/station.liq`, with `PSR_RTMP_PATH` + `PSR_RTMP_PASS` in its env, streaming into MediaMTX. `Restart=on-failure`. |
| `psr-onion-monitor.timer` | Every 2 min, republishes the station if the onion **HS descriptor goes dark** (radio #46). 5-min cooldown. |

> ⚠️ `logos-radio-feed.service` is the **old ffmpeg loop** and is **disabled** — do NOT enable it, it
> competes with liquidsoap on the same RTMP path and will fight the feed.

Start order (if bringing up from cold): **xvfb → app → (wait ~2 min for the app to boot + spawn
MediaMTX) → psr**. The monitor timer runs on its own.

```bash
systemctl --user start logos-radio-xvfb logos-radio-app
# wait ~2 min for MediaMTX to appear:
until curl -s localhost:9997/v3/config/global/get >/dev/null 2>&1; do sleep 5; done
systemctl --user start logos-radio-psr
systemctl --user start psr-onion-monitor.timer
```

---

## 4. Station identity (the credentials)

`~/.local/share/Logos-radio/radio_module/station.json` (backup: `.bak-psr`):

| Field | Value |
|---|---|
| name | **Parallel Society Radio** |
| path | `33a5971eeba1d06a` |
| streamKey / RTMP pass | `7fe13705bdcd7e710e1843e5818df574` |
| onion | `nub4jjg3cqanyoahiqvtltdzsaonro35mldfxy6mcnvcjepowysrwmid.onion` |
| privacy / visibility | `onion` / `public` |
| announceTopic | `/radio-basecamp/1/directory/json` |
| `running` | **`true`** ← this is why the app auto-resumes the broadcast on launch |

The **RTMP path + pass** must match `logos-radio-psr.service`'s `PSR_RTMP_PATH` / `PSR_RTMP_PASS`
(they're the `path` + `streamKey` above). If you re-key the station, update **both** places.

The onion key is persisted, so **the onion address survives restarts** — restarting the app republishes
the *same* onion, it does not mint a new one.

---

## 5. Content & playout (`station.liq`)

Library: **`/mnt/music/parallel-society-radio/`** → `talks/`, `dj/`, `jingles/` (13 tracks, pre-normalised
EBU R128: talks −16, music −14 LUFS). `station.liq` is the playout script:

- `rotate(weights=[1,3], [talks, djsets])` → 1 talk then 3 DJ items, repeating. Watched dirs (auto-reload
  on change); `mksafe` → silence, not crash, if a dir empties.
- Output: `%ffmpeg(format="flv", %audio(codec="aac", b="128k", samplerate=44100, channels=2))` → RTMP.
- **Telnet control surface on `:1234`** (skip / queue / metadata): `telnet localhost 1234`.
- Jingles are optional/commented — uncomment the `jingles` block in `station.liq` once jingle files land.

**To change what's playing:** drop/remove files in `talks/` or `dj/` (liquidsoap reloads live), or edit
`station.liq` and `systemctl --user restart logos-radio-psr`.

---

## 6. Common operations

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)

# Restart just the FEED (playout changed / liquidsoap wedged):
systemctl --user restart logos-radio-psr

# Restart the STATION / republish the onion (onion went dark, see §7):
systemctl --user restart logos-radio-app     # ~75s to descriptor status-200, then ~2 min DHT propagation

# Check the onion is actually reachable (from Sneg, via a throwaway Tor):
#   tor on a spare SocksPort, then torsocks ffprobe the onion HLS — expect a codec line (aac).
# (or just trust the monitor + the receiver.)

# Logs:
journalctl --user -u logos-radio-app -n 50 --no-pager        # host / MediaMTX / Tor spawn
journalctl --user -u logos-radio-psr -n 50 --no-pager        # liquidsoap feed
journalctl --user -t psr-onion-monitor -n 20 --no-pager      # onion monitor decisions
tail -f ~/radio-station/app.log                              # the Basecamp app itself
tail -20 /tmp/radio_module/torhost-*/hs.log                  # Tor HS descriptor uploads
```

---

## 7. Troubleshooting

**Feed not ingesting** (`"ready":false` or `bytesReceived` flat):
- liquidsoap died or can't reach MediaMTX. `systemctl --user restart logos-radio-psr`; check its journal.
- If MediaMTX itself is gone (`curl localhost:9997/...` fails), the app died → `systemctl --user restart
  logos-radio-app` and wait ~2 min.

**"Station unreachable / no sound" for listeners, but `"ready":true`** — this is the classic **onion
descriptor gone dark** (#38): MediaMTX is serving locally but the Tor HS descriptor fell out of the DHT.
- The **monitor auto-heals it** within ~2 min — check `journalctl --user -t psr-onion-monitor` for a
  `descriptor DARK … → republishing` line.
- Manual fix: `systemctl --user restart logos-radio-app`, then wait ~2 min for DHT propagation (the onion
  is unreachable *during* propagation even after `status 200` — that's normal).
- Confirm on the broadcaster: the latest `/tmp/radio_module/torhost-*/hs.log` line should be an
  `Uploaded hidden service descriptor … 200`, not `cant upload`.

**Everything down / cold boot:** start the services in the order in §3.

**Do not:** enable `logos-radio-feed.service` (competes with liquidsoap); `kill -HUP` MediaMTX (it
*terminates* it — MediaMTX has no hot-reload); run a second liquidsoap on the same path.

---

## 8. File & command reference

| Thing | Location (on Sneg) |
|---|---|
| App launcher | `~/radio-station/run-app.sh` (ExecStart of `logos-radio-app`) |
| App log | `~/radio-station/app.log` |
| Station config | `~/.local/share/Logos-radio/radio_module/station.json` |
| Playout script | `/mnt/music/parallel-society-radio/station.liq` |
| Music library | `/mnt/music/parallel-society-radio/{talks,dj,jingles}` |
| Feed service | `~/.config/systemd/user/logos-radio-psr.service` |
| Onion monitor | `~/.local/bin/psr-onion-monitor.sh` + `psr-onion-monitor.{service,timer}` |
| Tor HS log | `/tmp/radio_module/torhost-33a5971eeba1d06a/hs.log` |
| MediaMTX config | `/tmp/radio_module/33a5971eeba1d06a/mediamtx.yml` (generated by radio_module; `hlsAlwaysRemux: yes` baked in) |

**Verify a listener can hear it:** open the **Receiver** module → find "Parallel Society Radio" → Play.
First `.onion` connect can take 20s–2 min (Tor rendezvous variability); the receiver retries and shows
Connecting → Caching → Playing honestly.
