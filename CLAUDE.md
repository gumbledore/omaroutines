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

- `docs/` — `design.md` is the source of truth for scope and architecture
- (to be filled in as the repo is built out — CLI, systemd units, QML overlay/bar
  widget, task/log state)

## How to run

n/a — pre-implementation. See `docs/design.md` for the planned CLI surface.

## Conventions

- Bash + jq for the CLI/sweep, mirroring `~/.config/omarchy/plugins/gumbledore.reminders`
  (single CLI as sole writer of JSON state, flock + atomic rename, systemd `--user`
  `OnCalendar` sweep timer with `Persistent=true`).
- A small Python (`uv run`, `croniter`) helper computes next-occurrence-from-cron;
  everything else stays bash+jq.
- QML overlay + bar widget via `omarchy-shell shell summon`, same pattern as
  `gumbledore.reminders`.
