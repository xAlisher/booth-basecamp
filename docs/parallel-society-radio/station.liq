# Parallel Society Radio — playout brain (#31). Deployed on Sneg, streams to radio_module's MediaMTX.
#
# Launch (#33):
#   PSR_RTMP_PATH=<path from Stream tab OBS card> \
#   PSR_RTMP_PASS=<pass from OBS card>            \
#   liquidsoap docs/parallel-society-radio/station.liq
#
# Content is pre-normalised at rip time (#29, two-pass EBU R128 loudnorm: talks -16, music -14 LUFS),
# so no ReplayGain here — just a gentle safety limiter on the final bus. Watched playlist dirs ⇒
# mksafe → silence (not crash) if a dir empties. Telnet control surface on :1234 (skip/queue/metadata).

settings.server.telnet.set(true)
settings.server.telnet.port.set(1234)

lib = "/mnt/music/parallel-society-radio"

# --- sources (watched dirs; reload on change) ---------------------------------
talks  = playlist(mode="randomize", reload_mode="watch", "#{lib}/talks")
djsets = playlist(mode="randomize", reload_mode="watch", "#{lib}/dj")

# --- programme: music-forward, a talk every ~4 items --------------------------
# rotate(weights=[1,3], …) = 1 talk then 3 DJ items, repeating.
programme = rotate(weights=[1, 3], [talks, djsets])

# --- station idents / jingles (#32) — OPTIONAL, launch-safe if the dir is empty.
# When chair28980's jingles land in #{lib}/jingles, uncomment to weave one every ~5 items:
#   jingles   = playlist(mode="randomize", reload_mode="watch", "#{lib}/jingles")
#   programme = rotate(weights=[1, 4], [jingles, programme])

# --- glue: smooth transitions + fallback silence ------------------------------
radio = crossfade(fade_in=1., fade_out=1., duration=3., programme)
radio = mksafe(radio)
radio = limit(radio)   # gentle brickwall safety net (content already at target loudness)

# --- now-playing → file (#35): module reads this, adds `nowPlaying` to the announce ---
def on_meta(m) =
  title  = m["title"]
  artist = m["artist"]
  line   = if artist != "" then "#{artist} — #{title}" else title end
  ignore(file.write(data=line, "#{lib}/nowplaying.txt"))
end
radio = source.on_metadata(radio, on_meta)

# --- output: AAC-in-FLV → radio_module's MediaMTX RTMP ingest -----------------
# Assign env first (do NOT wrap the env lookup inside a "#{…}" interpolation — that errors).
rtmp_path = environment.get(default="", "PSR_RTMP_PATH")
rtmp_pass = environment.get(default="", "PSR_RTMP_PASS")
rtmp_url  = "rtmp://127.0.0.1:1935/#{rtmp_path}?user=publisher&pass=#{rtmp_pass}"

output.url(
  url = rtmp_url,
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", samplerate=44100, channels=2)),
  radio)
