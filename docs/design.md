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
- `systemd/oma-schedule-herdr.service` — `herdr server` with
  `HERDR_SESSION=oma-schedule`, `Restart=on-failure`. Installed but not
  enabled; the CLI starts **and** enables it before the first herdr run, so it
  survives login/reboot and `attach` keeps working. Never started for
  `herdr_session: "default"` (the user's foreground herdr).
- `defaults/settings.json` — shipped settings, merged into
  `${XDG_CONFIG_HOME:-~/.config}/oma-schedule/settings.json` on every read
  (defaults ⊕ user, `schema_version` pinned to the shipped value, invalid JSON
  → defaults + stderr warning, file never clobbered). Keys: `execution`
  (`headless`|`herdr`), `agent` (kind or null), `herdr_session`,
  `herdr_retain`, `herdr_timeout_minutes`.
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
  offscreen, so the panel is loaded only once the widget has a `bar`. The
harness also instantiates `TaskRow`/`RunRow` against a fake panel object and
logs their Attach/Resume state, so the `list --json` → row contract is
checked with data, not just compiled.
- `install.sh` — symlinks CLI into `~/.local/bin`, symlinks units, `daemon-reload`,
  `enable --now` the timer (the herdr unit is only installed), symlinks the repo
  into `~/.config/omarchy/plugins/<id>` and rescans plugins. `--uninstall`
  reverses all of it (both units) and keeps state + the herdr session dir.
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
  "created":1756400000,
  "agent":null,                     // omarchy agent kind; null = settings.agent, then omarchy-default-agent
  "execution":null,                 // headless | herdr; null = settings.execution
  "herdr_timeout":null              // minutes; null = settings.herdr_timeout_minutes
}]}
```

Absent keys read as null — tasks written before these fields existed need no
migration.

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
  "cwd":"/…",                       // directory the run actually executed in
  "backend":"headless",             // headless | herdr
  "reason":null,                    // null | blocked | timeout | exited | invalid_config
  "pane_id":null, "tab_id":null, "workspace_id":null, "agent_name":null,  // herdr runs; pane/tab null once pruned
  "base_commit":null                // worktree base, for the unchanged check at pane pruning
}]}
```

herdr runs have `session_id: null` (there is no claude session to resume) and
`permission_mode: null` (ignored under herdr).

Retention: after any run completes, that task's runs are pruned to the newest
`RETAIN_RUNS=20`; runs that still hold a worktree **or a live herdr pane** are
exempt (see Worktree pruning / Pane retention) so they never become orphans.

## CLI surface

```
oma-schedule add <name> --prompt <text> --cwd <dir> [--schedule <expr>|manual]
                        [--permission-mode <mode>] [--worktree true|false]
                        [--agent <kind>] [--execution headless|herdr] [--herdr-timeout <min>]
oma-schedule edit <name> [--prompt ...] [--cwd ...] [--schedule ...]
                        [--permission-mode <mode>|none] [--worktree true|false]
                        [--agent <kind>|none] [--execution ...|none] [--herdr-timeout <min>|none]
oma-schedule settings [get <key> | set <key> <value>]
oma-schedule list [--json]
oma-schedule rm <name>
oma-schedule enable <name> | disable <name>
oma-schedule trigger <name>              # run now (trigger=manual)
oma-schedule sweep                       # called by the timer
oma-schedule backlog run|skip <name>     # resolve a pending multi-miss backlog
oma-schedule log <name> [--json]
oma-schedule resume <run-id> [--terminal]  # headless runs
oma-schedule attach <run-id> [--terminal]  # herdr runs
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
carries `session_available` (the session transcript still exists), `backend`,
`reason`, `pane_id` and `pane_available` (pane still exists in the herdr
session; false whenever the server is unreachable), and
`log <name> --json` adds the same plus `log_path` (the captured output file,
or null once it is gone) to every run. Each task also carries the resolved
`agent`, its `agent_source` (`task`|`settings`|`omarchy`|`none`) and
`execution`; the omarchy default is read once per `list`. `list --json` reads
`tasks.json` once so a poll racing a write never sees two versions.

## Schedule math

`systemd-analyze calendar --iterations=1 [--base-time=@<epoch>] "<expr>"`.
Parse `Normalized form:` (stored back as `schedule`) and `Next elapse:`
(→ `date -d ... +%s` → `next_due`). Non-zero exit = invalid expression; its
stderr is surfaced verbatim. `manual` → `next_due: null`, never swept.

`next_due` is recomputed (from now) after every fire and on every `schedule`
change.

## Agent + backend resolution

At `add`/`edit`/`settings set` **and** again at fire time (the omarchy default
can change in between): agent kind = task `agent` → settings `agent` →
`omarchy-default-agent` output → none; execution = task `execution` → settings
`execution`. Accepted kinds are omarchy's list minus `crush` (no headless path,
not a herdr kind). `headless` supports claude only; any other combination is
rejected when typed and, at fire time, becomes a logged `failure` with
`reason: invalid_config` (same for "no agent set anywhere", whose message names
`omarchy default agent <name>`). `--permission-mode` on a task that currently
resolves to herdr is accepted with a warning — herdr runs ignore it.

## Execution (`run_task`, shared by trigger / sweep / backlog run)

Steps 1, 3, 6 and 7 are shared by both backends; 2, 4 and 5 are the headless
path, replaced under herdr by the section below.

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
   The result must be one of `default acceptEdits plan dontAsk bypassPermissions
   auto` (also enforced at `add`/`edit`); anything else fails the run before
   `claude` is invoked.
5. `cd <run dir> && "$CLAUDE_BIN" -p "$prompt" --session-id "$sid"
   --permission-mode "$mode" --output-format json`. Runs are **not** serialized.
6. After exit: if worktree has no changes (`git status --porcelain` empty AND
   no commits ahead of the base) → `git worktree remove --force` + delete
   branch, log `worktree_path/branch: null`. Otherwise keep and record. Under
   herdr an unchanged worktree is kept while the pane lives (attach must find
   the agent's files) and removed when the pane is pruned.
7. Finalize the log entry (end, status, exit_code) and prune to 20; `logs/<id>.out`
   files whose run was pruned are deleted alongside (logs live 0600 in a 0700 dir).

### herdr backend

Every herdr call runs with `HERDR_SESSION=<herdr_session>` (unset for
`"default"`) and with `HERDR_SOCKET_PATH`/`HERDR_ENV` scrubbed — inherited
from a herdr pane they override the session and point at the foreground
server. `HERDR_SOCKET_PATH` alone is never used: it re-loads the default
session's layout instead of isolating. Query-style calls (`status`, `list`,
`read`) are wrapped in a 10 s `timeout`, mutating ones (`create`, `agent
start`, `tab close`) in a 180 s one, so a hung server can neither hang `list`
nor strand a run; `agent start` also carries herdr's own 120 s readiness cap.
The herdr part of `run_task` runs with errexit off so a failed query always
ends in `finalize_run` (the sweep's `run` entry has no `||` guard).

1. Server: `herdr status server --json` → `.running`; if down, `systemctl
   --user start` + `enable` the unit and poll the socket (bounded). With
   `herdr_session: "default"` a down server fails the run instead.
2. Workspace: match by label = basename of the task `cwd` (create with
   `--cwd <cwd>` if absent). New tab `--cwd <run dir> --no-focus`; its root pane
   hosts the agent.
3. `agent start <task>-<run-id> --kind <kind> --pane <pane> -- <unattended
   flags>` (table copied from `omarchy-agent`: claude `--permission-mode auto`,
   codex `--approve-for-me`, gemini `--yolo`, opencode `--auto`, copilot
   `--allow-all`, omp `--auto-approve`, grok `--permission-mode
   bypassPermissions`, pi none). `agent_name_taken` → retry with a random
   suffix. A start that fails/blocks (e.g. claude's folder-trust dialog) is
   settled from `agent list`: the pane, not the exit code, is the truth.
4. `agent prompt <name> "<prompt>" --wait --timeout <ms>` where the timeout is
   task `herdr_timeout` → settings `herdr_timeout_minutes` (minutes; the
   `OMA_SCHEDULE_HERDR_TIMEOUT` env override is seconds, for tests).
5. Settle: `done`/`idle` → `success`; `blocked` → `failure/blocked`; still
   `working` at timeout → `failure/timeout`; agent gone or `unknown` →
   `failure/exited`. The sweep never kills a pane.
6. `agent read --source recent` is appended to `logs/<id>.out` (same 0600
   file as headless output), then step 6/7 above with `pane_id`, `tab_id`,
   `workspace_id`, `agent_name` recorded.
7. Pane retention (below) runs once this run's pane is on record.

`trigger`/`backlog run` print `run <id>: <status> (pane <id>)` for herdr runs
and `(session <uuid>)` for headless ones.

### Pane retention

Per task, after each herdr run: panes recorded on runs but no longer present
are reconciled (`pane_id`/`tab_id` → null); of the live ones, newest first,
`herdr_retain` (≥ 1) are kept and the rest are closed (`tab close`, which ends
the agent) unless their state is `working` or `blocked` — those are never
closed. A run with no recorded `tab_id`, or whose close fails, keeps its
`pane_id` so the pane stays visible rather than leaking.
A closed or vanished pane's worktree is removed with its branch if it is
still unchanged against the recorded `base_commit`; changed worktrees stay
for `prune`. The run entry and its log file survive; ordinary run retention
is re-applied afterwards, so at most 20 + `herdr_retain` runs per task exist.
`prune` (merged-worktree cleanup) skips runs whose pane is alive.

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

## Attach (herdr runs)

`oma-schedule attach <run-id>` is `resume` for herdr runs: the run must be a
herdr run with a `pane_id` that is still present (`pane list`, so a down
server also refuses), then `agent focus <agent_name>` and `exec herdr session
attach <session>` (bare `herdr` for `"default"`). `--terminal` detaches via
`$TERMINAL_BIN` exactly like `resume --terminal`. `resume` on a herdr run and
`attach` on a headless run each fail with a one-line hint naming the other
command. In the panel one button serves both: Resume for headless runs,
Attach for herdr runs, disabled when `session_available` / `pane_available`
is false, tinted urgent when `reason == blocked`; the failure reason is shown
next to the status, and the expanded task line shows `<agent> · <execution>`.
Settings and agent pinning have no panel UI.

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
| `OMA_SCHEDULE_TERMINAL_BIN` | `xdg-terminal-exec` | terminal launcher for `resume/attach --terminal`; fake in tests |
| `XDG_CONFIG_HOME` | `~/.config` | isolates `settings.json` (and, for herdr itself, its session dir) |
| `OMA_SCHEDULE_DEFAULT_AGENT_BIN` | `omarchy-default-agent` | prints the desktop's default agent kind, or nothing |
| `OMA_SCHEDULE_HERDR_BIN` | `herdr` | `tests/stubs/herdr`: JSON-shaped stub whose `agent start`/`prompt --wait` outcomes come from control files in `$STUB_DIR`; logs every call and the `HERDR_SESSION` it saw |
| `OMA_SCHEDULE_SYSTEMCTL_BIN` | `systemctl` | `tests/stubs/systemctl`: logs calls; `start oma-schedule-herdr.service` brings the stub server "up" |
| `OMA_SCHEDULE_HERDR_TIMEOUT` | unset | seconds; overrides the minutes-based prompt timeout (tests) |
| `OMA_SCHEDULE_HERDR_START_WAIT` | `20` | seconds to wait for the background server's socket |

Tests (`tests/test_*.py`, pytest) drive `bin/oma-schedule` as a subprocess
and assert on stdout, exit codes, and the JSON files. No bash internals are
tested directly. `tests/test_qml_smoke.py` runs quickshell offscreen (skips
when it is absent); it proves the QML compiles and parses the contract, not
layout or clicks. `tests/test_herdr_integration.py` is opt-in
(`OMA_SCHEDULE_HERDR_INTEGRATION=1`): one real claude prompt through a
throwaway herdr session under a temporary `XDG_CONFIG_HOME` — the only place
herdr's actual state classification is exercised.
