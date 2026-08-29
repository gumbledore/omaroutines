# oma-claude-schedule

An Omarchy plugin that schedules unattended Claude Code runs — the Linux/Hyprland
replacement for Claude Desktop's scheduled-tasks feature.

**Read `docs/design.md` before writing code.** It carries the architecture and the
reasoning behind every decision. The interview that produced it is recorded in the
Nucleus root session that ran `/grill-me` on 2026-08-28.

## Why this exists

The user is moving off Windows/Claude Desktop, whose scheduled-tasks UI has no
Linux equivalent. Recurring routines (wiki lint passes, literature watches, data
pulls) previously lived as Claude Desktop scheduled tasks; on Omarchy they need a
native trigger, run log, and UI, built on the same primitives as this machine's
`gumbledore.reminders` plugin.

## Key directories

- `docs/design.md` — source of truth for scope and architecture
- `bin/oma-schedule` — the CLI, sole writer of `~/.local/state/oma-schedule/{tasks,runs}.json`
- `systemd/` — `oma-schedule-sweep.{timer,service}` (every-minute sweep)
- `manifest.json`, `BarWidget.qml`, `install.sh` — Omarchy plugin packaging + bar widget (overlay not yet built)
- `tests/` — pytest suite driving the CLI as a subprocess

## How to run

- Install: `./install.sh` (symlinks CLI to `~/.local/bin`, enables the timer)
- Tests: `uv run pytest`
- `oma-schedule --help` for the CLI surface

## Conventions

- Bash + jq for the CLI/sweep, mirroring `~/.config/omarchy/plugins/gumbledore.reminders`
  (single CLI as sole writer of JSON state, flock + atomic rename, systemd `--user`
  `OnCalendar` sweep timer with `Persistent=true`).
- Schedule math uses `systemd-analyze calendar` (no Python at runtime; `uv` is
  only for the test suite).
- QML overlay + bar widget via `omarchy-shell shell summon`, same pattern as
  `gumbledore.reminders`.
