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

Left-click (or `oma-schedule show-overlay`, e.g. bound to a key) opens a panel
under the icon; right-click refreshes. The panel lists every task with its
enable toggle, schedule and next due, last-run outcome, and Trigger / Resume /
Remove buttons; a pending backlog shows Run / Skip. Click a task name to expand
its prompt and run history (Resume and Log per run). Escape, a second click,
or clicking outside closes it. The header's `+` opens an add-task form and the
cog opens `tasks.json` in your config editor; editing existing tasks stays on
the CLI (`oma-schedule edit`). Runs that changed files keep their worktree
(`<cwd>/.worktrees/…`) for review; opening the panel prunes the ones whose
branch has since been merged (`oma-schedule prune` does the same from a shell).

## Uninstall

    ./install.sh --uninstall

This disables and removes the `oma-schedule-sweep.timer` user units, drops the
`~/.local/bin/oma-schedule` and plugin symlinks, and rescans plugins. Task,
run, and log state in `~/.local/state/oma-schedule/` is kept; delete it by hand
for a clean slate. Do this **before** `omarchy plugin remove` — removing the
plugin folder alone leaves the timer firing a dead path every minute. Kept
worktrees under each task's `<cwd>/.worktrees/` are ordinary git worktrees;
`git worktree remove` them if you no longer want them.

Dev loop: the plugin directory is a symlink, and the shell's recursive inotify
watch does not follow it, so QML edits are not hot-reloaded (re-running
`install.sh` re-reads the manifest but keeps the compiled QML). After editing
any QML run `omarchy restart shell`; `uv run pytest tests/test_qml_smoke.py`
is the fast inner loop (offscreen quickshell against a fake CLI).
