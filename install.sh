#!/bin/bash
#
# Link `oma-schedule` onto PATH and start the sweep timer.
#
# `omarchy plugin add` clones this repo and loads the QML, but the CLI and the
# systemd timer do the real work and omarchy has no hook for installing those.
# Everything is symlinked back into the repo so `omarchy plugin update` updates
# the CLI and units along with the QML.

set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/oma-schedule"

say() { printf '  %s\n' "$*"; }

for dep in jq systemd-analyze claude uuidgen; do
  command -v "$dep" >/dev/null || { echo "install.sh: $dep is required" >&2; exit 1; }
done

mkdir -p "$BIN_DIR" "$UNIT_DIR" "$STATE_DIR"

# --- the CLI ---------------------------------------------------------------

if [[ -e $BIN_DIR/oma-schedule && ! -L $BIN_DIR/oma-schedule ]]; then
  echo "install.sh: $BIN_DIR/oma-schedule exists and is not a symlink; move it aside first" >&2
  exit 1
fi
ln -sfn "$REPO_DIR/bin/oma-schedule" "$BIN_DIR/oma-schedule"
say "linked $BIN_DIR/oma-schedule"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "NOTE: $BIN_DIR is not on your PATH — add it to your shell profile" ;;
esac

# --- the sweeper -----------------------------------------------------------

ln -sfn "$REPO_DIR/systemd/oma-schedule-sweep.service" "$UNIT_DIR/oma-schedule-sweep.service"
ln -sfn "$REPO_DIR/systemd/oma-schedule-sweep.timer" "$UNIT_DIR/oma-schedule-sweep.timer"
systemctl --user daemon-reload
systemctl --user enable --now oma-schedule-sweep.timer
say "enabled oma-schedule-sweep.timer (fires due tasks every minute)"

cat <<'EOF2'

  Done. Optional: bind a key to open the task list in ~/.config/hypr/bindings.lua:
    o.bind("SUPER + SHIFT + C", "Claude Schedule", "oma-schedule show-overlay")

  Try it:
    oma-schedule add hello --prompt "Say hello" --cwd ~/some/repo --schedule manual
    oma-schedule trigger hello && oma-schedule log hello
EOF2
