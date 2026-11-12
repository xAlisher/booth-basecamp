# #91 Trimmed ffmpeg + ffprobe for Booth's playlist source (radio_module/src/playlist_source.cpp).
# Only what the playlist pipeline uses, so the bundle stays small and has few library deps:
#   decode  : common audio files (mp3, flac, aac/m4a, alac, ogg vorbis/opus, wav/aiff pcm, wma, mka/webm, wavpack, ape)
#   encode  : AAC → FLV over RTMP into the bundled mediamtx;  raw s16le PCM between decoder and encoder
#   tests   : wav + null muxers, pcm_s16le encoder, lavfi sine (tests/playlist_test.cpp makes its fixtures)
{ ffmpeg-headless }:
ffmpeg-headless.overrideAttrs (o: {
  pname = "ffmpeg-booth-min";
  doCheck = false;
  configureFlags = o.configureFlags ++ [
    "--disable-everything" "--disable-ffplay"   # (no --disable-doc: nixpkgs ffmpeg has a "doc" output)
    "--enable-ffmpeg" "--enable-ffprobe"
    "--enable-swresample" "--enable-avfilter"
    "--enable-network" "--enable-protocol=file,pipe,tcp,rtmp"
    "--enable-demuxer=mp3,flac,aac,mov,ogg,wav,aiff,asf,matroska,wv,ape,pcm_s16le,lavfi"   # pcm_s16le = the "-f s16le" raw PCM format
    "--enable-decoder=mp3,mp3float,flac,aac,aac_latm,alac,vorbis,opus,wmav1,wmav2,wavpack,ape,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le,pcm_u8"
    "--enable-parser=mpegaudio,flac,aac,aac_latm,vorbis,opus"
    "--enable-encoder=aac,pcm_s16le"
    "--enable-muxer=flv,pcm_s16le,wav,null"
    "--enable-filter=aresample,aformat,anull,anullsrc,sine,volume,loudnorm"
    "--enable-bsf=aac_adtstoasc"
    "--enable-indev=lavfi"
  ];
})
