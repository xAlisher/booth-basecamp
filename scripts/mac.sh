#!/usr/bin/env bash
# Build and test Booth on the Mac (darwin-arm64, #88) from a Linux checkout.
#
#   scripts/mac.sh sync    rsync this checkout to the Mac (no .git, no build results)
#   scripts/mac.sh test    sync + run the standalone playlist/child-guard test there
#   scripts/mac.sh build   sync + nix build both .lgx packages (darwin-arm64) there
#   scripts/mac.sh fetch   copy the built .lgx files back into dist/darwin-arm64/
#   scripts/mac.sh ssh …   run a command on the Mac
#
# Host details live in scripts/hosts.local.env (gitignored; see scripts/hosts.example.env).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/scripts/hosts.local.env"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (copy scripts/hosts.example.env)" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${MAC_HOST:?set MAC_HOST in $ENV_FILE}"
MAC_DIR="${MAC_DIR:-booth-basecamp}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
[ -n "${MAC_JUMP:-}" ] && SSH_OPTS+=(-J "$MAC_JUMP")

# Non-login ssh on macOS doesn't see Homebrew or nix; put them first.
REMOTE_PATH='export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH'

remote() { ssh "${SSH_OPTS[@]}" "$MAC_HOST" "$REMOTE_PATH; cd ~/$MAC_DIR 2>/dev/null || true; $*"; }

sync() {
  ssh "${SSH_OPTS[@]}" "$MAC_HOST" "mkdir -p ~/$MAC_DIR"
  rsync -az --delete -e "ssh ${SSH_OPTS[*]}" \
    --exclude .git --exclude 'result' --exclude 'result-*' --exclude logs --exclude dist \
    --exclude 'scripts/hosts.local.env' --exclude '*.lgx' \
    "$ROOT/" "$MAC_HOST:$MAC_DIR/"
  echo "synced → $MAC_HOST:$MAC_DIR"
}

case "${1:-}" in
  sync) sync ;;
  test)
    sync
    # Qt + cmake from nixpkgs (no Homebrew Qt needed); ffmpeg/mediamtx from Homebrew.
    remote "cd radio_module && nix shell nixpkgs#qt6.qtbase nixpkgs#cmake --command ./tests/run-playlist-test.sh"
    ;;
  build)   # radio_ui: --impure + absolute override, its relative path:../radio_module input fails without .git
    sync
    remote "cd radio_module && nix build .#lgx-portable --out-link result-lgx-portable -L 2>&1 | tail -20 && ls -la result-lgx-portable/"
    remote "cd radio_ui && nix build --impure .#lgx-portable --override-input radio_module path:\$HOME/$MAC_DIR/radio_module --out-link result-lgx-portable -L 2>&1 | tail -20 && ls -la result-lgx-portable/"
    ;;
  fetch)
    mkdir -p "$ROOT/dist/darwin-arm64"
    for m in radio_module radio_ui; do
      rsync -azL -e "ssh ${SSH_OPTS[*]}" "$MAC_HOST:$MAC_DIR/$m/result-lgx-portable/" "$ROOT/dist/darwin-arm64/"
    done
    ls -la "$ROOT/dist/darwin-arm64"
    ;;
  ssh) shift; remote "$@" ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
