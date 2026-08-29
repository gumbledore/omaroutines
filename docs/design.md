# oma-claude-schedule — design

Source of truth for architecture. The full problem statement and user stories
live in the spec that produced this (`.scratch/oma-claude-schedule/spec.md`,
untracked); this file carries the decisions an implementer needs.

## Shape

Mirrors `~/.config/omarchy/plugins/gumbledore.reminders` (`rem`) exactly:

- `bin/oma-schedule` — single bash+jq CLI, **sole writer** of all JSON state.
  Every write: `flock` on `$STATE_DIR/.lock` → `jq` filter → temp file →
  atomic `mv` (`rem`'s `apply()`).
- `systemd/oma-schedule-sweep.{timer,service}` — `--user` oneshot,
  `OnCalendar=*:*:00`, `Persistent=true`, `AccuracySec=1s`. Runs
  `oma-schedule sweep` every minute; `Persistent=true` replays a missed sweep
  after sleep/boot.
- `manifest.json` — Omarchy plugin manifest (`bar-widget` kind only; the panel
  is private to the widget, as in omagit/omaplug).
- `BarWidget.qml` — bar icon + owner of the `list --json` poll (re-run on
  `tasks.json`/`runs.json` changes, every 60 s, on right-click, and after every
  panel action). Exposes `open()/close()/toggle()/opened` so the shell's
  `summon` (→ `oma-schedule show-overlay`) opens the panel. Left-click toggles.
- `Panel.qml` + `panel/{TaskRow,RunRow}.qml` — bar-anchored popup
  (`KeyboardPanel`; Escape / outside click / Tab cycling like other panels).
  One row per task: enable toggle, name (click = expand run history), schedule
  + next due, last-run chip, backlog pill with Run/Skip, Trigger / Resume /
  Remove (two-click armed, 6 s disarm). Expanded rows fetch `log <task> --json`
  while the panel is open. Every action is one CLI call through a shared
  one-at-a-time `Process`; non-zero exit shows stderr inline on that row.
  Trigger is the exception: launched detached, because a `Process` dies with
  the shell and would strand a run as `running`. Header buttons: refresh, an
  inline add-task form (name, cwd, prompt, schedule, permission mode,
  worktree → one `add` call, errors inline), and "open tasks.json" in the
  config editor (hand edits bypass validation and `next_due` recomputation).
  Edit stays CLI-only. Expanded rows show cwd/worktree/mode, the prompt in a
  wrapped box capped at ~10 lines, and the run history.
- `tests/qml/Harness.qml` — headless smoke harness (`quickshell -p`,
  offscreen) driven by `tests/test_qml_smoke.py`: loads `BarWidget.qml` against
  a fake CLI and compile-checks the panel files. No window backend exists
  offscreen, so the panel is loaded only once the widget has a `bar`.
- `install.sh` — symlinks CLI into `~/.local/bin`, symlinks units, `daemon-reload`,
  `enable --now` the timer, symlinks the repo into `~/.config/omarchy/plugins/<id>`
  and rescans plugins.
- No Python at runtime. `uv run pytest` is dev-only.

## State (`${XDG_STATE_HOME:-~/.local/state}/oma-schedule/`)

`tasks.json`:

```json
{"version":1,"tasks":[{
  "name":"lint-rad-onc",            // unique key, [A-Za-z0-9._-]+
  "prompt":"...",                   // full prompt text, owned here
  "cwd":"/home/kmg/Nucleus/rad-onc",// absolute; must be a git repo when worktree=true
  "schedule":"Mon *-*-* 09:00:00",  // systemd calendar spec, or "manual"
  "permission_mode":null,           // null = inherit ~/.claude/settings.json permissions.defaultMode
  "worktree":true,
  "enabled":true,
  "next_due":1756716400,            // epoch; null when schedule=="manual"
  "backlog_since":null,             // epoch when a multi-miss notification was sent; null otherwise
  "created":1756400000
}]}
```

`runs.json`:

```json
{"version":1,"nextRunId":1,"runs":[{
  "id":1,
  "task":"lint-rad-onc",
  "trigger":"manual",               // manual | scheduled | backlog-catchup
  "start":1756400000,
  "end":1756400300,                 // null while running
  "status":"success",               // running | success | failure
  "exit_code":0,
  "session_id":"uuid",
  "permission_mode":"auto",
  "worktree_path":"/…/.worktrees/lint-rad-onc-20260828-1",  // null if none or removed
  "worktree_branch":"oma-schedule/lint-rad-onc-…",           // null if none or removed
  "cwd":"/…"                        // directory the run actually executed in
}]}
```

Retention: after any run completes, that task's runs are pruned to the newest
`RETAIN_RUNS=20`; runs that still hold a worktree are exempt (see Worktree
pruning) so they never become orphans on disk.

## CLI surface

```
oma-schedule add <name> --prompt <text> --cwd <dir> [--schedule <expr>|manual]
                        [--permission-mode <mode>] [--worktree true|false]
oma-schedule edit <name> [--prompt ...] [--cwd ...] [--schedule ...]
                        [--permission-mode <mode>|none] [--worktree true|false]
oma-schedule list [--json]
oma-schedule rm <name>
oma-schedule enable <name> | disable <name>
oma-schedule trigger <name>              # run now (trigger=manual)
oma-schedule sweep                       # called by the timer
oma-schedule backlog run|skip <name>     # resolve a pending multi-miss backlog
oma-schedule log <name> [--json]
oma-schedule resume <run-id> [--terminal]
oma-schedule prune                       # remove kept worktrees whose branch is merged
oma-schedule show-overlay                # summon the panel
```

Default `--schedule` is `manual`. Errors go to stderr, non-zero exit, and never
mutate state. `list --json` is the bar widget's whole data contract: each task
gains `next_due_text` and `last_run` (`{id,status,trigger,start,end}` of its
newest run, or null); top level carries `count`, `enabled`, `failed`,
`running`, `backlog` (enabled tasks with a pending backlog), `badge`
(= failed + backlog), `next` (earliest-due enabled non-manual task, or null),
`active` (= badge > 0) and a ready-made `tooltip` string. Disabled tasks count
as failed/running but never as backlog/next. For the panel, `last_run` also
carries `session_available` (the session transcript still exists), and
`log <name> --json` adds `session_available` and `log_path` (the captured
output file, or null once it is gone) to every run. `list --json` reads
`tasks.json` once so a poll racing a write never sees two versions.

## Schedule math

`systemd-analyze calendar --iterations=1 [--base-time=@<epoch>] "<expr>"`.
Parse `Normalized form:` (stored back as `schedule`) and `Next elapse:`
(→ `date -d ... +%s` → `next_due`). Non-zero exit = invalid expression; its
stderr is surfaced verbatim. `manual` → `next_due: null`, never swept.

`next_due` is recomputed (from now) after every fire and on every `schedule`
change.

## Execution (`run_task`, shared by trigger / sweep / backlog run)

1. Allocate a run id + write a `running` log entry (under lock).
2. `session_id=$(uuidgen)` — generated up front and passed as
   `--session-id`, so the log links the session even if Claude never prints.
   (Deliberate deviation from the ticket's "captured from output": pushing
   the id is strictly more robust and `claude --session-id` is a real flag.)
3. If `worktree`: `git -C "$cwd" worktree add -b oma-schedule/<name>-<stamp>-<runid>
   "$cwd/.worktrees/<name>-<stamp>-<runid>"` (stamp = `%Y%m%d-%H%M%S`).
   Concurrent runs of the same task never collide because id is unique.
4. Resolve permission mode: task `permission_mode` if set, else
   `jq -r .permissions.defaultMode ~/.claude/settings.json`, else `default`.
5. `cd <run dir> && "$CLAUDE_BIN" -p "$prompt" --session-id "$sid"
   --permission-mode "$mode" --output-format json`. Runs are **not** serialized.
6. After exit: if worktree has no changes (`git status --porcelain` empty AND
   no commits ahead of the base) → `git worktree remove --force` + delete
   branch, log `worktree_path/branch: null`. Otherwise keep and record.
7. Finalize the log entry (end, status, exit_code) and prune to 20.

`trigger` runs in the foreground. `sweep` recomputes `next_due` **before**
launching each due task via `launch_run`: under the systemd service
(`$INVOCATION_ID` set) every run becomes its own transient unit
(`systemd-run --user … oma-schedule run <name> <trigger>`) because a oneshot
service kills plain `&` children the moment `sweep` exits; outside systemd
(tests, a shell) it just backgrounds `run_task`.

## Sweep + backlog

For each enabled task with non-null `next_due <= now`:

- Compute the occurrence *after* `next_due`:
  `systemd-analyze calendar --iterations=1 --base-time=@next_due "<expr>"`.
  If that second occurrence is also `<= now`, more than one fire was missed
  → **backlog**. Otherwise → single miss → fire (`trigger=scheduled`).
- Backlog: set `backlog_since=now`, send ONE notification via
  `$NOTIFY_BIN` ("<n> missed runs of <task> — click to run the backlog") with
  `--exec oma-schedule backlog run <name>`. Sweep does not block.
  (`omarchy-notification-send` supports a single click action; "Skip" is the
  timeout default, or `oma-schedule backlog skip <name>` explicitly.)
- While `backlog_since` is set, the task is not re-notified. If
  `now - backlog_since >= BACKLOG_TIMEOUT` (default 900 s) a later sweep
  resolves it as skip: clears `backlog_since`, recomputes `next_due` from now.
- `backlog run` fires the task **once** (`trigger=backlog-catchup`), clears
  `backlog_since`, recomputes `next_due`. `backlog skip` only does the latter.

## Resume

`oma-schedule resume <run-id>` looks up the run's `session_id`, checks that
`~/.claude/projects/*/<session_id>.jsonl` exists; if not, prints
`oma-schedule: session no longer available (run <id>)` and exits 1. Otherwise
`exec "$CLAUDE_BIN" --resume <session_id>` from the run's recorded `cwd`
(falling back to the task `cwd` if that directory is gone).

`--terminal` (used by the panel) runs the same checks, then launches
`setsid -f "$TERMINAL_BIN" oma-schedule resume <run-id>` and exits 0
immediately; failures keep the messages above and exit 1 so the panel can show
them inline.

## Worktree pruning

A run that leaves changes keeps its worktree + `oma-schedule/<task>-<stamp>-<id>`
branch as the review artifact. The session transcript is independent of it
(`claude --resume` works from any cwd), so pruning never breaks Resume — it
only changes where a resumed Claude lands (main checkout instead of the branch).

- **Done = merged.** `prune` removes a kept worktree when its branch is an
  ancestor of the repo's default branch (`origin/HEAD`, else `main`, else
  `master`) **or** `git cherry` shows every commit patch-equivalent there
  (squash/rebase merges). Local only — never fetches. `git worktree remove`
  without `--force`, so a dirty worktree is kept; the local branch is deleted
  with `-D`, remote branches are never touched. A worktree already deleted by
  hand just has its record cleared. The repo root comes from `worktree_path`,
  so runs of a removed task are still cleaned up.
- **Trigger = panel open.** The panel runs `prune` when opened and shows
  `pruned N merged worktree(s)` in the header for 5 s. Age never deletes
  anything; unmerged worktrees wait for you (delete by hand if unwanted).
- **Visibility.** `list --json` adds per-task `worktrees` (kept count); the
  row shows an `N worktrees` note and expanded history marks each run that
  kept one (path in tooltip). No bar badge, no top-level count.

## Test seam / injectable environment

All overridable via env, read once at CLI start:

| var | default | purpose |
|---|---|---|
| `XDG_STATE_HOME` | `~/.local/state` | isolates state per test |
| `OMA_SCHEDULE_CLAUDE_BIN` | `claude` | fake `claude` script in tests; must honor `-p`, `--session-id`, `--permission-mode`, `--resume` |
| `OMA_SCHEDULE_NOTIFY_BIN` | `omarchy-notification-send` | fake notifier in tests |
| `OMA_SCHEDULE_BACKLOG_TIMEOUT` | `900` | seconds before an unanswered backlog resolves to skip |
| `OMA_SCHEDULE_NOW` | `date +%s` | frozen clock for deterministic sweep/backlog tests |
| `OMA_SCHEDULE_CLAUDE_HOME` | `~/.claude` | where `settings.json` and `projects/` are read |
| `OMA_SCHEDULE_SWEEP_WAIT` | unset | `1` makes `sweep` wait for the runs it launched (tests only) |
| `OMA_SCHEDULE_TERMINAL_BIN` | `xdg-terminal-exec` | terminal launcher for `resume --terminal`; fake in tests |

Tests (`tests/test_*.py`, pytest) drive `bin/oma-schedule` as a subprocess
and assert on stdout, exit codes, and the JSON files. No bash internals are
tested directly. `tests/test_qml_smoke.py` runs quickshell offscreen (skips
when it is absent); it proves the QML compiles and parses the contract, not
layout or clicks.
