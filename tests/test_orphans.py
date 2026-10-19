"""Runs whose process dies: run_task's kill trap finalizes them as
failure/killed, and the sweep marks entries left "running" by a dead process
(dead pid, other boot, or a provably dead legacy entry) as failure/orphaned.
"""

import json
import os
import signal
import subprocess
import time
from pathlib import Path


def runs_path(state_home):
    return state_home / "omaroutines" / "runs.json"


def runs(state_home):
    p = runs_path(state_home)
    return json.loads(p.read_text())["runs"] if p.exists() else []


def wait_for(fn, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        v = fn()
        if v:
            return v
        time.sleep(0.1)
    raise AssertionError("condition not met")


def add_task(cli, name, cwd, **opts):
    args = ["add", name, "--prompt", "do the thing", "--cwd", str(cwd)]
    for k, v in opts.items():
        args += [f"--{k.replace('_', '-')}", str(v)]
    r = cli(*args)
    assert r.returncode == 0, r.stderr


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def test_run_entry_records_pid_and_boot(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo, worktree="false")
    assert cli("trigger", "t1").returncode == 0
    (r,) = runs(state_home)
    assert isinstance(r["pid"], int) and r["boot_id"] == boot_id()


def test_term_during_missed_delay_finalizes_killed(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo, worktree="false")
    p = cli("run", "t1", "missed", env_overrides={"OMAROUTINES_RESUME_DELAY": "30"}, background=True)
    wait_for(lambda: runs(state_home) and (state_home / "omaroutines/logs/1.out").read_text())
    os.kill(p.pid, signal.SIGTERM)  # bash alone: the trap must not wait out the sleep
    assert p.wait(timeout=5) == 1
    (r,) = runs(state_home)
    assert (r["status"], r["reason"], r["exit_code"]) == ("failure", "killed", 1)
    assert r["end"] is not None and r["cwd"] == str(git_repo)
    assert "run killed" in (state_home / "omaroutines/logs/1.out").read_text()


def test_killed_worktree_run_is_recorded_and_pruned(cli, state_home, git_repo, calls_dir):
    add_task(cli, "t1", git_repo)
    p = cli("run", "t1", "manual", env_overrides={"FAKE_CLAUDE_SLEEP": "30"}, background=True)
    wt = wait_for(lambda: runs(state_home) and list(calls_dir.glob("*.pwd")) and runs(state_home)[0]["worktree_path"])
    r = runs(state_home)[0]
    assert r["status"] == "running" and r["worktree_branch"] and r["base_commit"]
    # prune never touches a live run's worktree
    assert cli("prune").returncode == 0 and Path(wt).is_dir()

    os.killpg(p.pid, signal.SIGTERM)  # whole tree, like systemd stopping the unit
    p.wait(timeout=5)
    r = runs(state_home)[0]
    assert (r["status"], r["reason"]) == ("failure", "killed")
    assert r["worktree_path"] == wt and r["cwd"] == wt

    out = cli("prune")
    assert f"pruned: {wt}" in out.stdout
    assert not Path(wt).exists()
    assert runs(state_home)[0]["worktree_path"] is None


def dead_pid():
    p = subprocess.Popen(["true"])
    p.wait()
    return p.pid


def test_sweep_marks_orphaned_runs(cli, state_home, git_repo, notify_log):
    add_task(cli, "t1", git_repo, worktree="false")
    now = int(time.time())
    base = {"task": "t1", "trigger": "scheduled", "end": None, "status": "running", "exit_code": None,
            "session_id": None, "worktree_path": None, "pane_id": None, "reason": None}
    entries = [
        {"id": 1, "start": now, "backend": "headless", "pid": dead_pid(), "boot_id": boot_id()},
        {"id": 2, "start": now, "backend": "headless", "pid": os.getpid(), "boot_id": "another-boot"},
        {"id": 3, "start": now, "backend": "headless", "pid": os.getpid(), "boot_id": boot_id()},  # alive
        {"id": 4, "start": 1, "backend": "headless"},  # legacy, before this boot
        {"id": 5, "start": now, "backend": "headless"},  # legacy, unbounded: left alone
        {"id": 6, "start": now - 3 * 3600, "backend": "herdr"},  # legacy, past herdr timeout
        {"id": 7, "start": now - 60, "backend": "herdr"},  # legacy, within timeout
    ]
    runs_path(state_home).write_text(json.dumps(
        {"version": 1, "nextRunId": 8, "runs": [{**base, **e} for e in entries]}))

    r = cli("sweep")
    assert r.returncode == 0, r.stderr
    by_id = {x["id"]: x for x in runs(state_home)}
    for i in (1, 2, 4, 6):
        assert (by_id[i]["status"], by_id[i]["reason"], by_id[i]["exit_code"]) == ("failure", "orphaned", 1)
        assert by_id[i]["end"] is not None
        assert f"t1: run {i} orphaned" in r.stdout
    for i in (3, 5, 7):
        assert by_id[i]["status"] == "running"
    assert "t1 failed" in notify_log.read_text()
