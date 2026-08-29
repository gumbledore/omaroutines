"""Tests for tickets 04+05 (sweep + backlog), driven through
`omaroutines sweep` / `backlog run|skip` against a frozen clock
(OMAROUTINES_NOW) and a fake notifier (tests/conftest.py's fake_notify_bin).

Fixture clock: task added at T = Fri 2026-08-28 21:00:00 UTC with schedule
"*-*-* *:00/15:00" (every 15 min) gets next_due = T+900 (21:15:00). The
occurrence after that is T+1800 (21:30:00) -- verified independently via
`systemd-analyze calendar --iterations=1 --base-time=@<epoch>`.
"""

import json
import time

T = 1787950800  # Fri 2026-08-28 21:00:00 UTC
SCHEDULE = "*-*-* *:00/15:00"


def tasks_json(state_home):
    return json.loads((state_home / "omaroutines" / "tasks.json").read_text())


def task_by_name(state_home, name):
    for t in tasks_json(state_home)["tasks"]:
        if t["name"] == name:
            return t
    return None


def runs_for(state_home, task):
    runs = json.loads((state_home / "omaroutines" / "runs.json").read_text())["runs"]
    return [r for r in runs if r["task"] == task]


def add_task(cli, name, cwd, now=T, **opts):
    args = ["add", name, "--prompt", "do the thing", "--cwd", str(cwd)]
    for k, v in opts.items():
        args += [f"--{k.replace('_', '-')}", str(v)]
    r = cli(*args, env_overrides={"OMAROUTINES_NOW": str(now)})
    assert r.returncode == 0, r.stderr
    return r


def sweep(cli, now, **env):
    env_overrides = {"OMAROUTINES_NOW": str(now)}
    env_overrides.update(env)
    return cli("sweep", env_overrides=env_overrides)


def notify_calls(notify_log):
    if not notify_log.exists() or not notify_log.read_text().strip():
        return []
    return [c for c in notify_log.read_text().split("---\n") if c.strip()]


# --- single miss ----------------------------------------------------------


def test_single_miss_fires_silently(cli, state_home, cwd_dir, notify_log):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    r = sweep(cli, T + 16 * 60, OMAROUTINES_SWEEP_WAIT="1")
    assert r.returncode == 0, r.stderr
    assert "t1: fired" in r.stdout

    runs = runs_for(state_home, "t1")
    assert len(runs) == 1
    assert runs[0]["trigger"] == "scheduled"

    task = task_by_name(state_home, "t1")
    assert task["backlog_since"] is None
    assert task["next_due"] > T + 16 * 60

    assert notify_calls(notify_log) == []


def test_future_next_due_not_fired(cli, state_home, cwd_dir, notify_log):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    r = sweep(cli, T)  # next_due is T+900, still in the future
    assert r.returncode == 0, r.stderr
    assert r.stdout == ""
    assert runs_for(state_home, "t1") == []


def test_disabled_and_manual_never_fire(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    cli("disable", "t1")
    add_task(cli, "t2", cwd_dir, schedule="manual", worktree="false")

    r = sweep(cli, T + 16 * 60)
    assert r.returncode == 0, r.stderr
    assert runs_for(state_home, "t1") == []
    assert runs_for(state_home, "t2") == []
    assert task_by_name(state_home, "t1")["next_due"] == T + 900  # untouched


# --- multi-miss backlog -----------------------------------------------------


def test_multi_miss_creates_backlog_notification(cli, state_home, cwd_dir, notify_log):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    r = sweep(cli, T + 46 * 60)
    assert r.returncode == 0, r.stderr
    assert "t1: backlog pending (notified)" in r.stdout

    assert runs_for(state_home, "t1") == []
    task = task_by_name(state_home, "t1")
    assert task["backlog_since"] == T + 46 * 60

    calls = notify_calls(notify_log)
    assert len(calls) == 1
    assert "t1" in calls[0]
    assert "backlog\nrun\nt1" in calls[0]


def test_backlog_pending_no_renotify(cli, state_home, cwd_dir, notify_log):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    sweep(cli, T + 46 * 60)
    r = sweep(cli, T + 47 * 60)
    assert r.returncode == 0, r.stderr
    assert r.stdout == ""
    assert runs_for(state_home, "t1") == []
    assert len(notify_calls(notify_log)) == 1


def test_backlog_timeout_resolves_skip(cli, state_home, cwd_dir, notify_log):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    sweep(cli, T + 46 * 60, OMAROUTINES_BACKLOG_TIMEOUT="60")
    r = sweep(cli, T + 47 * 60, OMAROUTINES_BACKLOG_TIMEOUT="60")
    assert r.returncode == 0, r.stderr
    assert "t1: backlog skipped (no response)" in r.stdout

    assert runs_for(state_home, "t1") == []
    task = task_by_name(state_home, "t1")
    assert task["backlog_since"] is None
    assert task["next_due"] > T + 47 * 60
    assert len(notify_calls(notify_log)) == 1  # still just the original


# --- backlog run/skip commands ----------------------------------------------


def test_backlog_run_fires_once_in_foreground(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    sweep(cli, T + 46 * 60)

    r = cli("backlog", "run", "t1", env_overrides={"OMAROUTINES_NOW": str(T + 46 * 60)})
    assert r.returncode == 0, r.stderr
    assert "run 1: success" in r.stdout

    runs = runs_for(state_home, "t1")
    assert len(runs) == 1
    assert runs[0]["trigger"] == "backlog-catchup"

    task = task_by_name(state_home, "t1")
    assert task["backlog_since"] is None
    assert task["next_due"] > T + 46 * 60


def test_backlog_skip_command(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    sweep(cli, T + 46 * 60)

    r = cli("backlog", "skip", "t1", env_overrides={"OMAROUTINES_NOW": str(T + 46 * 60)})
    assert r.returncode == 0, r.stderr
    assert "t1: backlog skipped" in r.stdout

    assert runs_for(state_home, "t1") == []
    task = task_by_name(state_home, "t1")
    assert task["backlog_since"] is None
    assert task["next_due"] > T + 46 * 60


def test_backlog_unknown_task_fails(cli, state_home):
    r = cli("backlog", "run", "nosuch")
    assert r.returncode == 1


def test_backlog_bad_verb_fails(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    r = cli("backlog", "frobnicate", "t1")
    assert r.returncode == 1


# --- non-blocking sweep -------------------------------------------------------


def test_sweep_wait_produces_completed_run(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    r = sweep(cli, T + 16 * 60, OMAROUTINES_SWEEP_WAIT="1")
    assert r.returncode == 0, r.stderr

    runs = runs_for(state_home, "t1")
    assert len(runs) == 1
    assert runs[0]["status"] == "success"
    assert runs[0]["session_id"]


def test_sweep_without_wait_returns_promptly(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")

    start = time.monotonic()
    r = sweep(cli, T + 16 * 60, FAKE_CLAUDE_SLEEP="3")
    elapsed = time.monotonic() - start
    assert r.returncode == 0, r.stderr
    assert elapsed < 5, f"sweep blocked for {elapsed}s"

    deadline = time.monotonic() + 10
    runs = []
    while time.monotonic() < deadline:
        runs = runs_for(state_home, "t1")
        if runs and runs[0]["status"] != "running":
            break
        time.sleep(0.2)
    assert runs and runs[0]["status"] == "success"
