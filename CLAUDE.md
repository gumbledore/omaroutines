# omaroutines

An Omarchy plugin that schedules unattended Claude Code runs — the Linux/Hyprland
replacement for Claude Desktop's scheduled-tasks feature.

**Read `docs/design.md` before writing code.** It carries the architecture and the
reasoning behind every decision.

## Why this exists

Replaces Claude Desktop's scheduled-tasks feature for Linux/Hyprland users, whose
scheduled-tasks UI has no Linux equivalent. Recurring routines (wiki lint passes,
literature watches, data pulls) previously lived as Claude Desktop scheduled tasks;
on Omarchy they need a native trigger, run log, and UI, built on the same
primitives as `gumbledore.reminders`.

## Key directories

- `docs/design.md` — source of truth for scope and architecture
- `bin/omaroutines` — the CLI, sole writer of `~/.local/state/omaroutines/{tasks,runs}.json`
  and `~/.config/omaroutines/settings.json`
- `defaults/settings.json` — shipped settings (execution backend, agent, herdr knobs), merged on read
- `systemd/` — `omaroutines-sweep.{timer,service}` (every-minute sweep) and
  `omaroutines-herdr.service` (background herdr session, started on the first herdr run)
- `manifest.json`, `BarWidget.qml`, `Panel.qml`, `panel/`, `install.sh` — Omarchy plugin packaging, bar widget, and its popup task panel
- `tests/` — pytest suite driving the CLI as a subprocess (fake claude/herdr/systemctl in
  `tests/conftest.py` + `tests/stubs/`), a headless QML smoke test (`tests/qml/`), and an
  opt-in real-herdr integration test

## How to run

- Install: `./install.sh` (symlinks CLI to `~/.local/bin`, enables the timer)
- Tests: `uv run pytest`
- `omaroutines --help` for the CLI surface

## Conventions

- Bash + jq for the CLI/sweep, mirroring `~/.config/omarchy/plugins/gumbledore.reminders`
  (single CLI as sole writer of JSON state, flock + atomic rename, systemd `--user`
  `OnCalendar` sweep timer with `Persistent=true`).
- Schedule math uses `systemd-analyze calendar` (no Python at runtime; `uv` is
  only for the test suite).
- Bar widget + bar-anchored panel (omagit/omaplug pattern); `omaroutines
  show-overlay` summons it via `omarchy-shell shell summon`.
- Two backends: `headless` (`claude -p`, claude only) and `herdr` (live agent
  of any supported kind in the hidden `omaroutines` herdr session; Attach
  instead of Resume). Agent kind resolves task → settings → `omarchy-default-agent`.
