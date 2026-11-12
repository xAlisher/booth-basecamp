{
  description = "radio_module — decentralized audio broadcast origin + discovery (core module)";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder";
    # Pin nixpkgs/bundler to the builder's so the Rust/zerokit toolchain that delivery_module
    # pulls (RLN) resolves from the shared binary cache instead of building from source.
    nixpkgs.follows = "logos-module-builder/nixpkgs";
    nix-bundle-lgx.follows = "logos-module-builder/nix-bundle-lgx";
    # delivery_module is auto-resolved from metadata.json `dependencies` via this input.
    # Input attr name MUST match the dependency name. Pinned to the rev receiver-basecamp uses
    # (c21ffb83) — its zerokit builds/caches on aarch64-darwin, unlike the old v0.1.1 pin whose
    # zerokit 0.9.0 falls back to vendoring old Rust crates → crates.io 403 on darwin (#booth mac build).
    delivery_module.url = "github:logos-co/logos-delivery-module/c21ffb83b2b891843de9a940dd60e5e56c8803de";
    delivery_module.inputs.logos-module-builder.follows = "logos-module-builder";
    # #91 One pinned nixpkgs for the bundled helpers (tor must be 0.4.9+; the builder's nixpkgs is too old:
    # mediamtx 1.15). nixos-26.05 = tor 0.4.9.16, mediamtx 1.18.2, ffmpeg 8.1.3. See nix/bundled-versions.txt.
    nixpkgs-helpers.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = inputs@{ logos-module-builder, nixpkgs-helpers, ... }:
    let
      # Helpers are built for the HOST system (each release build is single-system), which makes this
      # IMPURE: build with `nix build --impure .#lgx-portable`. Same workaround as receiver-basecamp
      # (docs/PACKAGING.md there); drop it when logos-module-builder PR #184 (postInstall as a
      # function of { system, pkgs }) merges.
      system = builtins.currentSystem;
      hp = nixpkgs-helpers.legacyPackages.${system};
      ffmpegMin = import ./nix/ffmpeg-min-fn.nix { inherit (hp) ffmpeg-headless; };
      helperBundle = hp.callPackage ./nix/helper-bundle.nix { inherit ffmpegMin; };
    in
    logos-module-builder.lib.mkLogosModule {
      src = ./.;
      configFile = ./metadata.json;
      flakeInputs = inputs;
      # #91 ship mediamtx + tor + ffmpeg + ffprobe at <moduleDir>/bin/ → zero-install Booth.
      # (Copying into $out/lib/bin survives the portable bundler for core modules too; the older
      # logos-module-builder#114 note below is about other paths. Verified on darwin-arm64 2026-11-12.)
      postInstall = ''
        mkdir -p $out/lib/bin
        cp -a ${helperBundle}/. $out/lib/bin/
        chmod -R u+w $out/lib/bin
      '';
      # HISTORICAL NOTE (pre-#91): runtime binaries (mediamtx/tor/torsocks/ffplay) can't be bundled via postInstall — the
      # portable bundler (nix-bundle-dir) closures only the .so + its lib deps and drops extra files
      # (upstream: logos-co/logos-module-builder#114). The plugin resolves them via resolveBin():
      # env override → <module-dir>[/bin] → PATH. scripts/install.sh drops a static mediamtx into the
      # module dir post-install for a self-contained dev install until #114 lands.
    };
}
