#!/bin/bash
#
# Link `oma-schedule` onto PATH and start the sweep timer.
# `install.sh --uninstall` reverses it (timer, units, symlinks; state is kept).
#
# `omarchy plugin add` clones this repo and loads the QML, but the CLI and the
# systemd timer do the real work and omarchy has no hook for installing those.
# Everything is symlinked back into the repo so `omarchy plugin update` updates
# the CLI and units along with the QML.

set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
PLUGIN_ID="kmg.oma-claude-schedule"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/oma-schedule"
SYSTEMCTL="${OMA_SCHEDULE_SYSTEMCTL_BIN:-systemctl}" # stubbed in tests

say() { printf '  %s\n' "$*"; }

# --- uninstall -------------------------------------------------------------
# Reverses everything below. State (tasks/runs/logs) is left in place; the
# final message says where it is. `omarchy plugin remove` alone would delete
# the plugin folder and leave the timer firing a dead symlink every minute.

if [[ ${1:-} == --uninstall ]]; then
  "$SYSTEMCTL" --user disable --now oma-schedule-sweep.timer 2>/dev/null || true
  "$SYSTEMCTL" --user disable --now oma-schedule-herdr.service 2>/dev/null || true
  rm -f "$UNIT_DIR/oma-schedule-sweep.timer" "$UNIT_DIR/oma-schedule-sweep.service" "$UNIT_DIR/oma-schedule-herdr.service"
  "$SYSTEMCTL" --user daemon-reload
  say "disabled and removed oma-schedule-sweep.timer and oma-schedule-herdr.service"
  [[ -L $BIN_DIR/oma-schedule ]] && rm -f "$BIN_DIR/oma-schedule" && say "removed $BIN_DIR/oma-schedule"
  [[ -L $PLUGIN_DIR/$PLUGIN_ID ]] && rm -f "$PLUGIN_DIR/$PLUGIN_ID" && say "removed $PLUGIN_DIR/$PLUGIN_ID"
  if command -v omarchy-shell >/dev/null; then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || say "NOTE: plugin rescan failed; run: omarchy restart shell"
  fi
  say "kept state in $STATE_DIR (delete it yourself if you want a clean slate)"
  say "kept the herdr session (agent transcripts) in ${XDG_CONFIG_HOME:-$HOME/.config}/herdr/sessions/oma-schedule"
  say "  remove it with: herdr session stop oma-schedule; herdr session delete oma-schedule"
  exit 0
fi

for dep in jq systemd-analyze uuidgen; do
  command -v "$dep" >/dev/null || { echo "install.sh: $dep is required" >&2; exit 1; }
done
command -v claude >/dev/null || say "NOTE: claude not found — headless runs need it"
command -v herdr >/dev/null || say "NOTE: herdr not found — herdr runs need it"

mkdir -p "$BIN_DIR" "$UNIT_DIR" "$STATE_DIR" "$PLUGIN_DIR"

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
# The background herdr server is installed but not enabled: the first herdr
# run starts + enables it.
ln -sfn "$REPO_DIR/systemd/oma-schedule-herdr.service" "$UNIT_DIR/oma-schedule-herdr.service"
"$SYSTEMCTL" --user daemon-reload
"$SYSTEMCTL" --user enable --now oma-schedule-sweep.timer
say "enabled oma-schedule-sweep.timer (fires due tasks every minute)"
say "installed oma-schedule-herdr.service (started on the first herdr run)"

# --- the shell plugin (bar widget) ------------------------------------------

if [[ -e $PLUGIN_DIR/$PLUGIN_ID && ! -L $PLUGIN_DIR/$PLUGIN_ID ]]; then
  echo "install.sh: $PLUGIN_DIR/$PLUGIN_ID exists and is not a symlink; move it aside first" >&2
  exit 1
fi
ln -sfn "$REPO_DIR" "$PLUGIN_DIR/$PLUGIN_ID"
say "linked $PLUGIN_DIR/$PLUGIN_ID"
if command -v omarchy-shell >/dev/null; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || say "NOTE: plugin rescan failed; run: omarchy restart shell"
fi

cat <<EOF2

  Done. Put the widget in the bar (once):
    omarchy bar put $PLUGIN_ID --after gumbledore.reminders   # or any --section/--after

  Optional: bind a key to open the task list in ~/.config/hypr/bindings.lua:
    o.bind("SUPER + SHIFT + C", "Claude Schedule", "oma-schedule show-overlay")

  Try it:
    oma-schedule add hello --prompt "Say hello" --cwd ~/some/repo --schedule manual
    oma-schedule trigger hello && oma-schedule log hello
EOF2
