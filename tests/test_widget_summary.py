"""Bar-widget data contract: `oma-schedule list --json` summary fields
(.scratch/oma-schedule-bar-widget/spec.md). States are produced through the
real run paths (fake claude exit / sleep, frozen-clock sweep), never by editing
runs.json by hand.
"""

import json
import time

from test_sweep import SCHEDULE, T, add_task, sweep


def listing(cli, now=None):
    env = {"OMA_SCHEDULE_NOW": str(now)} if now else None
    r = cli("list", "--json", env_overrides=env)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def wait_for(fetch, ok, timeout=5):
    """Poll `fetch()` until `ok(result)`; background runs log `running` a beat
    after `sweep` returns."""
    deadline = time.monotonic() + timeout
    while True:
        result = fetch()
        if ok(result) or time.monotonic() > deadline:
            return result
        time.sleep(0.1)


def task(payload, name):
    return next(t for t in payload["tasks"] if t["name"] == name)


def test_no_tasks_baseline(cli, state_home):
    p = listing(cli)
    assert p["count"] == 0
    assert p["enabled"] == 0
    assert p["failed"] == p["running"] == p["backlog"] == p["badge"] == 0
    assert p["next"] is None
    assert p["active"] is False
    assert p["tooltip"] == "No enabled tasks"


def test_last_run_null_then_newest(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, worktree="false")
    assert task(listing(cli), "t1")["last_run"] is None

    cli("trigger", "t1")
    cli("trigger", "t1")
    cli("trigger", "t1", env_overrides={"FAKE_CLAUDE_EXIT": "2"})
    lr = task(listing(cli), "t1")["last_run"]
    assert lr["id"] == 3
    assert lr["status"] == "failure"
    assert lr["trigger"] == "manual"
    assert isinstance(lr["start"], int) and isinstance(lr["end"], int)
    assert set(lr) == {"id", "status", "trigger", "start", "end"}


def test_failed_run_sets_badge_and_tooltip(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, worktree="false", schedule=SCHEDULE)
    cli("trigger", "t1", env_overrides={"FAKE_CLAUDE_EXIT": "1"})
    p = listing(cli, now=T)
    assert p["failed"] == 1
    assert p["badge"] == 1
    assert p["active"] is True
    assert p["tooltip"] == "Next: t1 Fri 28 Aug 21:15 · 1 failed"


def test_healthy_enabled_task_is_not_active(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, worktree="false", schedule=SCHEDULE)
    cli("trigger", "t1")
    p = listing(cli, now=T)
    assert p["count"] == 1 and p["enabled"] == 1
    assert p["badge"] == 0
    assert p["active"] is False
    assert p["next"] == {"task": "t1", "next_due": T + 900, "next_due_text": "Fri 28 Aug 21:15"}
    assert p["tooltip"] == "Next: t1 Fri 28 Aug 21:15"


def test_running_task_counted(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    sweep(cli, T + 16 * 60, FAKE_CLAUDE_SLEEP="3")
    p = wait_for(lambda: listing(cli), lambda p: task(p, "t1")["last_run"] is not None)
    assert task(p, "t1")["last_run"]["status"] == "running"
    assert task(p, "t1")["last_run"]["end"] is None
    assert p["running"] == 1
    assert p["failed"] == 0
    assert p["badge"] == 0
    assert "1 running" in p["tooltip"]

    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and listing(cli)["running"]:
        time.sleep(0.2)
    assert listing(cli)["running"] == 0


def test_backlog_counted_and_cleared_by_skip(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    sweep(cli, T + 46 * 60)
    p = listing(cli, now=T + 46 * 60)
    assert p["backlog"] == 1
    assert p["badge"] == 1
    assert p["active"] is True
    assert p["tooltip"].endswith(" · 1 backlog")

    cli("backlog", "skip", "t1", env_overrides={"OMA_SCHEDULE_NOW": str(T + 46 * 60)})
    p = listing(cli, now=T + 46 * 60)
    assert p["backlog"] == 0 and p["badge"] == 0 and p["active"] is False


def test_disabled_failed_task_counts_failed_but_not_backlog_or_next(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, schedule=SCHEDULE, worktree="false")
    sweep(cli, T + 46 * 60)  # backlog pending on t1
    cli("trigger", "t1", env_overrides={"FAKE_CLAUDE_EXIT": "1"})
    cli("disable", "t1")
    p = listing(cli, now=T + 46 * 60)
    assert p["enabled"] == 0
    assert p["failed"] == 1
    assert p["backlog"] == 0
    assert p["next"] is None
    assert p["badge"] == 1 and p["active"] is True
    assert p["tooltip"] == "No enabled tasks"


def test_next_picks_earliest_enabled_nonmanual(cli, state_home, cwd_dir):
    add_task(cli, "later", cwd_dir, schedule="*-*-* 23:00:00")
    add_task(cli, "soon", cwd_dir, schedule=SCHEDULE)
    add_task(cli, "soonest-but-off", cwd_dir, schedule="*-*-* *:05:00")
    add_task(cli, "manual", cwd_dir)
    cli("disable", "soonest-but-off")
    p = listing(cli, now=T)
    assert p["next"]["task"] == "soon"
    assert p["next"]["next_due"] == T + 900
    assert p["enabled"] == 3
    assert p["tooltip"] == "Next: soon Fri 28 Aug 21:15"


def test_all_manual_with_failure(cli, state_home, cwd_dir):
    add_task(cli, "m1", cwd_dir, worktree="false")
    add_task(cli, "m2", cwd_dir, worktree="false")
    cli("trigger", "m2", env_overrides={"FAKE_CLAUDE_EXIT": "1"})
    p = listing(cli)
    assert p["next"] is None
    assert p["tooltip"] == "Next: none · 1 failed"


def test_tooltip_all_segments(cli, state_home, cwd_dir):
    add_task(cli, "bl", cwd_dir, schedule=SCHEDULE, worktree="false")  # due T+15 -> 2 misses
    add_task(cli, "r", cwd_dir, schedule=SCHEDULE, worktree="false", now=T + 31 * 60)  # due T+45 -> 1 miss
    add_task(cli, "f", cwd_dir, worktree="false")
    sweep(cli, T + 46 * 60, FAKE_CLAUDE_SLEEP="3")  # bl -> backlog, r -> running
    cli("trigger", "f", env_overrides={"FAKE_CLAUDE_EXIT": "1"})
    p = wait_for(lambda: listing(cli, now=T + 46 * 60), lambda p: p["running"] == 1)
    assert p["tooltip"].startswith("Next: ")
    assert p["tooltip"].endswith(" · 1 failed · 1 running · 1 backlog")
    assert p["badge"] == 2

    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and listing(cli)["running"]:
        time.sleep(0.2)
