# Connecting Liquidsoap to Booth (radio-basecamp)

Liquidsoap is the **automated-DJ** alternative to OBS: instead of pushing a live
capture, it plays a music folder (or playlist) and streams AAC audio to Booth's
built-in origin (MediaMTX). Booth captures nothing itself — it just announces
your station and serves it to listeners over Tor.

The block below is written so you can **hand it straight to an AI agent** to set
up. The canonical multi-folder script we run (talks / DJ / jingles with weighted
rotation) is [`docs/parallel-society-radio/station.liq`](parallel-society-radio/station.liq).

---

## Agent task: stream a music folder to a Booth station via Liquidsoap

You are setting up Liquidsoap as an automated DJ that pushes audio to a Basecamp
"Booth" (`radio_module`) station's MediaMTX RTMP ingest.

### 0. Values you need from the human
Start a stream in Booth (Basecamp → Booth → **Start**). Booth shows an **OBS setup
card** with an **RTMP Server** and a **Stream Key**. Get both, e.g.:
- RTMP Server: `rtmp://127.0.0.1:1935`  (use the exact host:port shown; if Liquidsoap
  runs on a **different machine** than Booth, use Booth's **LAN IP**, not `127.0.0.1`)
- Stream Key:  `ab12cd34?user=publisher&pass=SECRETPASS`

Split the Stream Key into two parts:
- **PATH** = everything before `?`   → e.g. `ab12cd34`
- **PASS** = the value of `pass=`     → e.g. `SECRETPASS`

### 1. Install Liquidsoap (must have the ffmpeg/AAC encoder)
```bash
# Debian/Ubuntu:
sudo apt update && sudo apt install -y liquidsoap
# macOS:
brew install liquidsoap
# verify:
liquidsoap --version
```
If `apt`'s build lacks the `%ffmpeg` encoder (older distros), install the official
static build from https://www.liquidsoap.info/ instead.

### 2. Put audio files in one folder
```bash
mkdir -p ~/radio-music
# copy .mp3 / .flac / .m4a / .ogg files into ~/radio-music
ls ~/radio-music
```

### 3. Create `station.liq`
```liquidsoap
# station.liq — minimal Booth playout (single folder)
lib = environment.get(default="/home/USER/radio-music", "MUSIC_DIR")

music = playlist(mode="randomize", reload_mode="watch", lib)
radio = crossfade(fade_in=1., fade_out=1., duration=3., music)
radio = mksafe(limit(radio))

# now-playing → file Booth reads for the announce
def on_meta(m) =
  t = m["title"]; a = m["artist"]
  line = if a != "" then "#{a} — #{t}" else t end
  ignore(file.write(data=line, "#{lib}/nowplaying.txt"))
end
radio = source.on_metadata(radio, on_meta)

# output: AAC-in-FLV → Booth's MediaMTX RTMP ingest
rtmp_path = environment.get(default="", "PSR_RTMP_PATH")
rtmp_pass = environment.get(default="", "PSR_RTMP_PASS")
rtmp_host = environment.get(default="rtmp://127.0.0.1:1935", "PSR_RTMP_HOST")
rtmp_url  = "#{rtmp_host}/#{rtmp_path}?user=publisher&pass=#{rtmp_pass}"

output.url(
  url = rtmp_url,
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", samplerate=44100, channels=2)),
  radio)
```

### 4. Launch (fill in PATH / PASS from step 0)
```bash
MUSIC_DIR="$HOME/radio-music" \
PSR_RTMP_HOST="rtmp://127.0.0.1:1935" \
PSR_RTMP_PATH="ab12cd34" \
PSR_RTMP_PASS="SECRETPASS" \
liquidsoap station.liq
```

### 5. Verify it's live
- Liquidsoap logs show it connecting + encoding (no repeated errors).
- In Booth the status light moves: **Waiting for OBS… → Receiving stream… → 🔴 Live (announcing)**.
- Once 🔴 Live, Booth announces the station every 15 s; listeners can tap to play.
- `~/radio-music/nowplaying.txt` updates with the current track.

### Troubleshooting
| Symptom | Fix |
|---------|-----|
| Booth stuck on **Waiting for OBS…** | Wrong host/port/path/pass. PATH is before `?`, PASS is after `pass=`. Different machine → use Booth's LAN IP, not `127.0.0.1`. |
| **Failed to connect to server** | The RTMP port (**1935**) must be reachable from where Liquidsoap runs. |
| **No `%ffmpeg` / AAC error** | Your Liquidsoap lacks ffmpeg — install the official static build. |
| **Silence for listeners** | Folder must contain playable audio; check Liquidsoap logs show tracks starting. |

---

## Audio settings (match Booth's ingest)
- Codec **AAC**, **128 kbps**, **44.1 kHz**, **stereo** — the same target as the OBS path.
- `crossfade(duration=3.)` for smooth transitions (also propagates track metadata for now-playing).
- `nowplaying.txt` in the music dir is what `radio_module` reads to put "artist — title"
  into the station announce (#35).

Ports used by the origin: **1935** (RTMP in), **8889** (WHIP in), **8890** (SRT in),
**8888** (HLS out to listeners), **9997** (local status API).
