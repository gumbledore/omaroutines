#!/bin/bash
#
# Link `omaroutines` onto PATH and start the sweep timer.
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
PLUGIN_ID="gumbledore.omaroutines"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omaroutines"
SYSTEMCTL="${OMAROUTINES_SYSTEMCTL_BIN:-systemctl}" # stubbed in tests

say() { printf '  %s\n' "$*"; }

# --- uninstall -------------------------------------------------------------
# Reverses everything below. State (tasks/runs/logs) is left in place; the
# final message says where it is. `omarchy plugin remove` alone would delete
# the plugin folder and leave the timer firing a dead symlink every minute.

if [[ ${1:-} == --uninstall ]]; then
  "$SYSTEMCTL" --user disable --now omaroutines-sweep.timer 2>/dev/null || true
  "$SYSTEMCTL" --user disable --now omaroutines-herdr.service 2>/dev/null || true
  rm -f "$UNIT_DIR/omaroutines-sweep.timer" "$UNIT_DIR/omaroutines-sweep.service" "$UNIT_DIR/omaroutines-herdr.service"
  "$SYSTEMCTL" --user daemon-reload
  say "disabled and removed omaroutines-sweep.timer and omaroutines-herdr.service"
  [[ -L $BIN_DIR/omaroutines ]] && rm -f "$BIN_DIR/omaroutines" && say "removed $BIN_DIR/omaroutines"
  [[ -L $PLUGIN_DIR/$PLUGIN_ID ]] && rm -f "$PLUGIN_DIR/$PLUGIN_ID" && say "removed $PLUGIN_DIR/$PLUGIN_ID"
  if command -v omarchy-shell >/dev/null; then
    omarchy-shell shell rescanPlugins >/dev/null 2>&1 || say "NOTE: plugin rescan failed; run: omarchy restart shell"
  fi
  say "kept state in $STATE_DIR (delete it yourself if you want a clean slate)"
  say "kept the herdr session (agent transcripts) in ${XDG_CONFIG_HOME:-$HOME/.config}/herdr/sessions/omaroutines"
  say "  remove it with: herdr session stop omaroutines; herdr session delete omaroutines"
  exit 0
fi

for dep in jq systemd-analyze uuidgen; do
  command -v "$dep" >/dev/null || { echo "install.sh: $dep is required" >&2; exit 1; }
done
command -v claude >/dev/null || say "NOTE: claude not found — headless runs need it"
command -v herdr >/dev/null || say "NOTE: herdr not found — herdr runs need it"

# --- migrate from the old oma-claude-schedule / oma-schedule names ---------
# Idempotent, user-scope only (no sudo). Safe to run every install.

OLD_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/oma-schedule"
OLD_BIN="$BIN_DIR/oma-schedule"
OLD_PLUGIN_ID="kmg.oma-claude-schedule"
OLD_UNITS=(oma-schedule-sweep.timer oma-schedule-sweep.service oma-schedule-herdr.service)

if [[ -d $OLD_STATE_DIR && ! -e $STATE_DIR ]]; then
  mkdir -p "$(dirname -- "$STATE_DIR")"
  mv "$OLD_STATE_DIR" "$STATE_DIR"
  say "migrated state: $OLD_STATE_DIR -> $STATE_DIR"
fi

if [[ -L $OLD_BIN ]]; then
  rm -f "$OLD_BIN"
  say "removed old symlink $OLD_BIN"
fi

if [[ -L $PLUGIN_DIR/$OLD_PLUGIN_ID ]]; then
  rm -f "$PLUGIN_DIR/$OLD_PLUGIN_ID"
  say "removed old plugin symlink $PLUGIN_DIR/$OLD_PLUGIN_ID"
fi

if [[ -e $UNIT_DIR/${OLD_UNITS[0]} || -L $UNIT_DIR/${OLD_UNITS[0]} || -e $UNIT_DIR/${OLD_UNITS[2]} || -L $UNIT_DIR/${OLD_UNITS[2]} ]]; then
  "$SYSTEMCTL" --user disable --now oma-schedule-sweep.timer 2>/dev/null || true
  "$SYSTEMCTL" --user stop oma-schedule-herdr.service 2>/dev/null || true
  rm -f "${OLD_UNITS[@]/#/$UNIT_DIR/}"
  "$SYSTEMCTL" --user daemon-reload
  say "removed old units: ${OLD_UNITS[*]}"
fi

mkdir -p "$BIN_DIR" "$UNIT_DIR" "$STATE_DIR" "$PLUGIN_DIR"

# --- the CLI ---------------------------------------------------------------

if [[ -e $BIN_DIR/omaroutines && ! -L $BIN_DIR/omaroutines ]]; then
  echo "install.sh: $BIN_DIR/omaroutines exists and is not a symlink; move it aside first" >&2
  exit 1
fi
ln -sfn "$REPO_DIR/bin/omaroutines" "$BIN_DIR/omaroutines"
say "linked $BIN_DIR/omaroutines"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "NOTE: $BIN_DIR is not on your PATH — add it to your shell profile" ;;
esac

# --- the sweeper -----------------------------------------------------------

ln -sfn "$REPO_DIR/systemd/omaroutines-sweep.service" "$UNIT_DIR/omaroutines-sweep.service"
ln -sfn "$REPO_DIR/systemd/omaroutines-sweep.timer" "$UNIT_DIR/omaroutines-sweep.timer"
# The background herdr server is installed but not enabled: the first herdr
# run starts + enables it.
ln -sfn "$REPO_DIR/systemd/omaroutines-herdr.service" "$UNIT_DIR/omaroutines-herdr.service"
"$SYSTEMCTL" --user daemon-reload
"$SYSTEMCTL" --user enable --now omaroutines-sweep.timer
say "enabled omaroutines-sweep.timer (fires due tasks every minute)"
say "installed omaroutines-herdr.service (started on the first herdr run)"

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
    o.bind("SUPER + SHIFT + C", "Omaroutines", "omaroutines show-overlay")

  Try it:
    omaroutines add hello --prompt "Say hello" --cwd ~/some/repo --schedule manual
    omaroutines trigger hello && omaroutines log hello
EOF2
