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

## Backends and agents

Every run resolves an **agent kind** (task `--agent` → `settings.json`
`agent` → `omarchy default agent`; nothing set = the run fails with
`invalid_config`) and an **execution** backend (task `--execution` →
`settings.json` `execution`):

- `headless` (default) — `claude -p`, exit code = outcome, `claude --resume`
  from the panel. Claude only; `headless` with any other kind is rejected at
  `add`/`edit`/`settings set` and again at fire time.
- `herdr` — the run is a live agent (any herdr-supported omarchy kind except
  crush) in a new tab of a hidden **background herdr session** named
  `oma-schedule`. The sweep starts + enables `oma-schedule-herdr.service` on
  the first such run and leaves it up. The prompt is submitted with
  `--wait`; `done`/`idle` → success, `blocked` → `failure · blocked`,
  still working at `herdr_timeout_minutes` → `failure · timeout`, agent gone
  → `failure · exited`. The pane stays alive either way; the panel's Resume
  button becomes **Attach** (red when blocked) and `oma-schedule attach
  <run-id>` does the same from a shell. The three newest panes per task are
  kept (`herdr_retain`); older settled ones are closed. Agents launch in
  their unattended mode; the task's `permission_mode` is ignored.

Settings live in `~/.config/oma-schedule/settings.json` (merged from
`defaults/settings.json`): `execution`, `agent`, `herdr_session` (`default`
= your foreground herdr), `herdr_retain`, `herdr_timeout_minutes`.

    oma-schedule settings                       # show
    oma-schedule settings set execution herdr   # every non-pinned task -> herdr
    oma-schedule edit lint --agent claude --execution headless

## Uninstall

    ./install.sh --uninstall

This disables and removes the `oma-schedule-sweep.timer` and
`oma-schedule-herdr.service` user units, drops the `~/.local/bin/oma-schedule`
and plugin symlinks, and rescans plugins. Task, run, and log state in
`~/.local/state/oma-schedule/` is kept; delete it by hand for a clean slate.
The background herdr session (agent transcripts of herdr runs) is kept too,
in `~/.config/herdr/sessions/oma-schedule/`; remove it with
`herdr session stop oma-schedule; herdr session delete oma-schedule`. Do this **before** `omarchy plugin remove` — removing the
plugin folder alone leaves the timer firing a dead path every minute. Kept
worktrees under each task's `<cwd>/.worktrees/` are ordinary git worktrees;
`git worktree remove` them if you no longer want them.

Dev loop: the plugin directory is a symlink, and the shell's recursive inotify
watch does not follow it, so QML edits are not hot-reloaded (re-running
`install.sh` re-reads the manifest but keeps the compiled QML). After editing
any QML run `omarchy restart shell`; `uv run pytest tests/test_qml_smoke.py`
is the fast inner loop (offscreen quickshell against a fake CLI). herdr runs
are tested against `tests/stubs/herdr`; `OMA_SCHEDULE_HERDR_INTEGRATION=1
uv run pytest tests/test_herdr_integration.py` runs one real claude prompt
through a throwaway herdr session.
