# Parallel Society Radio — playout brain (#31). Streams to radio_module MediaMTX.
# Launch: PSR_RTMP_PATH=<path> PSR_RTMP_PASS=<pass> liquidsoap station.liq

settings.server.telnet.set(true)
settings.server.telnet.port.set(1234)

lib = "/mnt/music/parallel-society-radio"

# --- sources (watched dirs) ---------------------------------------------------
talks   = playlist(mode="randomize", reload_mode="watch", "#{lib}/talks")
djsets  = playlist(mode="randomize", reload_mode="watch", "#{lib}/dj")
jingles = playlist(mode="randomize", reload_mode="watch", "#{lib}/jingles")
# Sterlin's spoken-word interstitials (#37) — the contemplative counterweight to Chair's comedic
# stings. Kept in their OWN source so they retain their file metadata ("Lujan Sterlin — Parallel
# Society") and are NOT overwritten by the jingle stamp below.
spoken  = playlist(mode="randomize", reload_mode="watch", "#{lib}/spoken")

# Stamp jingle now-playing => announce shows "Chair — Parallel Society Radio" (#32/#35).
def stamp_jingle(_m) = [("artist", "Chair"), ("title", "Parallel Society Radio")] end
jingles = metadata.map(update=true, strip=false, insert_missing=true, stamp_jingle, jingles)

# --- idents: interleave Chair's comedic stings with Sterlin's contemplative drops (#37) --------
# Chair is frequent + short, Sterlin rarer + breathes longer => weight 2:1. Each keeps its own
# now-playing line, so the announce alternates "Chair — …" and "Lujan Sterlin — Parallel Society".
idents = rotate(weights=[2, 1], [jingles, spoken])

# --- programme: talk -> music -> music, with a shuffled ident ~every 6 items ---
base      = rotate(weights=[1, 2], [talks, djsets])
programme = rotate(weights=[1, 5], [idents, base])

# --- transitions: built-in crossfade (correctly propagates track metadata; the
#     hand-rolled cross transition broke now-playing, so we use the stdlib one). -
radio = crossfade(fade_in=1., fade_out=1., duration=3., programme)
radio = mksafe(radio)
radio = limit(radio)

# --- now-playing => file (#35): module reads this, adds nowPlaying to announce --
def on_meta(m) =
  title  = m["title"]
  artist = m["artist"]
  line   = if artist != "" then "#{artist} — #{title}" else title end
  ignore(file.write(data=line, "#{lib}/nowplaying.txt"))
end
radio = source.on_metadata(radio, on_meta)

# --- output: AAC-in-FLV => radio_module MediaMTX RTMP ingest -------------------
rtmp_path = environment.get(default="", "PSR_RTMP_PATH")
rtmp_pass = environment.get(default="", "PSR_RTMP_PASS")
rtmp_url  = "rtmp://127.0.0.1:1935/#{rtmp_path}?user=publisher&pass=#{rtmp_pass}"

output.url(
  url = rtmp_url,
  %ffmpeg(format="flv", %audio(codec="aac", b="128k", samplerate=44100, channels=2)),
  radio)
