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
- `manifest.json` — Omarchy plugin manifest (`overlay` + `bar-widget` kinds).
  QML files are out of scope for v0.1; the manifest declares entry points only.
- `install.sh` — symlinks CLI into `~/.local/bin`, symlinks units, `daemon-reload`,
  `enable --now` the timer.
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
`RETAIN_RUNS=20`.

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
oma-schedule resume <run-id>
oma-schedule show-overlay
```

Default `--schedule` is `manual`. Errors go to stderr, non-zero exit, and never
mutate state. `list --json` returns `{count, tasks:[...], active, tooltip}`
(bar-widget friendly, like `rem ls --json`).

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

Tests (`tests/test_cli.py`, pytest) drive `bin/oma-schedule` as a subprocess
and assert on stdout, exit codes, and the JSON files. No bash internals are
tested directly.
