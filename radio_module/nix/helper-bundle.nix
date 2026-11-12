# #91 Self-contained runtime helpers shipped at <moduleDir>/bin/ inside the radio_module .lgx, so Booth
# needs nothing installed (radio_plugin.cpp resolveBin() checks <moduleDir>/bin first). Adapted from
# receiver-basecamp nix/helper-bundle.nix (#75/#77).
#
#   mediamtx  stream origin (RTMP/WHIP/SRT in, HLS out)    Go binary: system libs only
#   tor       onion hosting (must be 0.4.9+)
#   ffmpeg    playlist encoder + decoders  ┐ trimmed build, nix/ffmpeg-min-fn.nix
#   ffprobe   track titles + durations     ┘
#
# Darwin: copy each binary + its /nix/store dylib closure, rewrite install names to @loader_path, ad-hoc
#         re-sign (install_name_tool invalidates the signature). System dylibs (/usr/lib, /System) stay.
# Linux : copy binaries + non-glibc libs, rpath $ORIGIN, standard interpreter (system glibc is always there).
# ALL inputs come from ONE nixpkgs (the flake's nixpkgs-helpers pin), so one libc on Linux.
{ stdenv, lib, ffmpegMin, tor, mediamtx
, glibc ? null, patchelf ? null      # linux
, sigtool ? null                     # darwin (codesign)
}:
let isDarwin = stdenv.hostPlatform.isDarwin;
in stdenv.mkDerivation {
  pname = "booth-helper-bundle";
  version = "1";
  dontUnpack = true;
  nativeBuildInputs = if isDarwin then [ sigtool ] else [ patchelf glibc.bin ];
  buildCommand =
    if isDarwin then ''
      mkdir -p $out
      collect() {
        otool -L "$1" | tail -n +2 | awk '{print $1}' | while read -r dep; do
          case "$dep" in
            /nix/store/*) b=$(basename "$dep");
              if [ ! -e "$out/$b" ]; then install -m755 "$dep" "$out/$b"; collect "$out/$b"; fi ;;
          esac
        done
      }
      for src in ${ffmpegMin}/bin/ffmpeg ${ffmpegMin}/bin/ffprobe ${tor}/bin/tor ${mediamtx}/bin/mediamtx; do
        install -m755 "$src" "$out/$(basename "$src")"; collect "$out/$(basename "$src")"
      done
      for f in $out/*; do
        install_name_tool -id "@loader_path/$(basename "$f")" "$f" 2>/dev/null || true
        otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
          case "$dep" in /nix/store/*) install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f" || true ;; esac
        done
        codesign -f -s - "$f" 2>/dev/null || true
      done
      # fail the build if anything still points into /nix/store (it would not exist on a user's Mac)
      for f in $out/*; do
        if otool -L "$f" | tail -n +2 | grep -q /nix/store; then echo "unrelocated dep in $f"; otool -L "$f"; exit 1; fi
      done
    '' else ''
      mkdir -p $out
      GLIBC_SKIP='libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|ld-linux|libresolv|libstdc\+\+|libgcc_s'
      add() {
        local src; src=$(readlink -f "$1")
        install -m555 "$src" "$out/$(basename "$1")"
        ldd "$src" 2>/dev/null | awk '/=>/{print $3}' | while read -r libp; do
          [ -z "$libp" ] && continue
          b=$(basename "$libp"); echo "$b" | grep -qE "$GLIBC_SKIP" && continue
          [ -e "$out/$b" ] || install -m555 "$(readlink -f "$libp")" "$out/$b"
        done
      }
      add ${ffmpegMin}/bin/ffmpeg
      add ${ffmpegMin}/bin/ffprobe
      add ${tor}/bin/tor
      add ${mediamtx}/bin/mediamtx
      chmod -R u+w $out
      for f in $out/*; do patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true; done
      for exe in ffmpeg ffprobe tor mediamtx; do
        patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 "$out/$exe" 2>/dev/null || true   # static Go binary: no-op
      done
    '';
}
