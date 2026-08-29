# oma-claude-schedule

Omarchy plugin that schedules unattended Claude Code runs — the Linux/Hyprland
replacement for Claude Desktop's scheduled tasks.

See `CLAUDE.md` for the AI workspace instructions and `docs/design.md` for the
architecture.

## Bar widget

`install.sh` links this repo into `~/.config/omarchy/plugins/kmg.oma-claude-schedule`
and rescans plugins. Place the widget once:

    omarchy bar put kmg.oma-claude-schedule --after gumbledore.reminders

It runs `oma-schedule list --json` on every change to the state files and every
60 s, and shows:

| State | Icon |
|---|---|
| no enabled tasks | dimmed, tooltip `No enabled tasks` |
| enabled, healthy | normal, tooltip `Next: <task> <when>` |
| failed last run / pending backlog | badge count + active color, tooltip adds `· N failed`, `· N backlog` |
| run in progress | tooltip adds `· N running` |
| CLI missing or failing | plain icon, tooltip `Claude Schedule` |

Click opens the overlay (`oma-schedule show-overlay`; the overlay is not built yet).

Dev loop: the plugin directory is a symlink, and the shell's recursive inotify
watch does not follow it, so QML edits are not hot-reloaded (re-running
`install.sh` re-reads the manifest but keeps the compiled QML). After editing
`BarWidget.qml` run `omarchy restart shell`.
