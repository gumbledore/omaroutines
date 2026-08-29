"""Tests for bin/omaroutines (tickets 01 + 02): state store, core CLI,
schedule validation, and next_due math via systemd-analyze calendar.

Drives the CLI as a subprocess against an isolated XDG_STATE_HOME, per
docs/design.md's test seam. TZ=UTC is forced so schedule math is
deterministic regardless of the host's local timezone.
"""

import concurrent.futures
import json
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CLI = REPO_ROOT / "bin" / "omaroutines"

# Frozen clock: Fri 2026-08-28 20:46:40 UTC. Expected next_due values below
# were computed independently via:
#   TZ=UTC systemd-analyze calendar --iterations=1 --base-time=@1787950000 "<expr>"
FROZEN_NOW = 1787950000
NEXT_DUE_DAILY = 1787961600  # Sat 2026-08-29 00:00:00 UTC
NEXT_DUE_WEEKLY_MON_9 = 1788166800  # Mon 2026-08-31 09:00:00 UTC
NEXT_DUE_EVERY_15MIN = 1787950800  # Fri 2026-08-28 21:00:00 UTC


def tasks_json(state_home):
    return json.loads((state_home / "omaroutines" / "tasks.json").read_text())


def task_by_name(state_home, name):
    for t in tasks_json(state_home)["tasks"]:
        if t["name"] == name:
            return t
    return None


# --- ticket 01: state store + core CLI ---------------------------------------


def test_add_creates_task_record(cli, state_home, cwd_dir):
    r = cli("add", "t1", "--prompt", "do things", "--cwd", str(cwd_dir))
    assert r.returncode == 0, r.stderr
    t = task_by_name(state_home, "t1")
    assert t is not None
    assert t["prompt"] == "do things"
    assert t["cwd"] == str(cwd_dir)
    assert t["schedule"] == "manual"
    assert t["enabled"] is True
    assert t["next_due"] is None
    assert t["worktree"] is True
    assert t["permission_mode"] is None
    assert t["backlog_since"] is None
    assert isinstance(t["created"], int)


def test_add_requires_prompt_and_cwd(cli, state_home, cwd_dir):
    r = cli("add", "t1", "--cwd", str(cwd_dir))
    assert r.returncode != 0
    assert "prompt" in r.stderr

    r = cli("add", "t1", "--prompt", "hi")
    assert r.returncode != 0
    assert "cwd" in r.stderr

    assert not (state_home / "omaroutines" / "tasks.json").exists() or tasks_json(state_home)["tasks"] == []


def test_add_cwd_made_absolute_and_must_exist(cli, state_home, tmp_path, cwd_dir):
    rel_target = cwd_dir
    r = cli("add", "t1", "--prompt", "hi", "--cwd", str(rel_target))
    assert r.returncode == 0, r.stderr
    t = task_by_name(state_home, "t1")
    assert t["cwd"] == str(rel_target.resolve())

    missing = tmp_path / "does-not-exist"
    r = cli("add", "t2", "--prompt", "hi", "--cwd", str(missing))
    assert r.returncode != 0
    assert "directory" in r.stderr
    assert task_by_name(state_home, "t2") is None


def test_add_name_must_match_pattern_and_be_unique(cli, state_home, cwd_dir):
    # herdr agent-name rule: lowercase letter first, [a-z0-9_-], max 20 chars
    for bad in ("bad name!", "Test", "a.b", "-x", "1st", "a" * 21):
        r = cli("add", bad, "--prompt", "hi", "--cwd", str(cwd_dir))
        assert r.returncode != 0, bad
        assert "invalid task name" in r.stderr
    r = cli("add", "ok_name-1", "--prompt", "hi", "--cwd", str(cwd_dir))
    assert r.returncode == 0, r.stderr

    r = cli("add", "dup", "--prompt", "hi", "--cwd", str(cwd_dir))
    assert r.returncode == 0, r.stderr
    r = cli("add", "dup", "--prompt", "hi again", "--cwd", str(cwd_dir))
    assert r.returncode != 0
    assert task_by_name(state_home, "dup")["prompt"] == "hi"


def test_add_worktree_and_permission_mode_options(cli, state_home, cwd_dir):
    r = cli(
        "add",
        "t1",
        "--prompt",
        "hi",
        "--cwd",
        str(cwd_dir),
        "--worktree",
        "false",
        "--permission-mode",
        "acceptEdits",
    )
    assert r.returncode == 0, r.stderr
    t = task_by_name(state_home, "t1")
    assert t["worktree"] is False
    assert t["permission_mode"] == "acceptEdits"


def test_list_human_and_json(cli, state_home, cwd_dir):
    cli("add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir))
    cli("add", "t2", "--prompt", "hi", "--cwd", str(cwd_dir), "--schedule", "daily")
    cli("disable", "t2")

    r = cli("list")
    assert r.returncode == 0
    assert "t1" in r.stdout
    assert "t2" in r.stdout
    assert "disabled" in r.stdout

    r = cli("list", "--json")
    assert r.returncode == 0
    payload = json.loads(r.stdout)
    assert payload["count"] == 2
    assert payload["active"] is False  # healthy: nothing needs attention
    names = {t["name"] for t in payload["tasks"]}
    assert names == {"t1", "t2"}
    t2 = next(t for t in payload["tasks"] if t["name"] == "t2")
    assert t2["enabled"] is False
    assert t2["next_due_text"] != "-"
    t1 = next(t for t in payload["tasks"] if t["name"] == "t1")
    assert t1["next_due_text"] == "-"


def test_list_empty(cli, state_home):
    r = cli("list")
    assert r.returncode == 0
    assert "no scheduled tasks" in r.stdout

    r = cli("list", "--json")
    payload = json.loads(r.stdout)
    assert payload["count"] == 0
    assert payload["active"] is False


def test_rm_removes_task(cli, state_home, cwd_dir):
    cli("add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir))
    r = cli("rm", "t1")
    assert r.returncode == 0
    assert task_by_name(state_home, "t1") is None


def test_rm_unknown_task_fails(cli, state_home):
    r = cli("rm", "nosuch")
    assert r.returncode == 1
    assert "nosuch" in r.stderr


def test_enable_disable_toggle_without_deleting(cli, state_home, cwd_dir):
    cli("add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir))
    r = cli("disable", "t1")
    assert r.returncode == 0
    assert task_by_name(state_home, "t1")["enabled"] is False

    r = cli("enable", "t1")
    assert r.returncode == 0
    assert task_by_name(state_home, "t1")["enabled"] is True


def test_enable_unknown_task_fails(cli, state_home):
    r = cli("enable", "nosuch")
    assert r.returncode == 1
    r = cli("disable", "nosuch")
    assert r.returncode == 1


def test_show_overlay_never_fails(cli, state_home):
    # summons omarchy-shell; harmless (exit 0) when no shell is running
    r = cli("show-overlay")
    assert r.returncode == 0


def test_help_and_unknown_command(cli):
    r = cli("--help")
    assert r.returncode == 0
    assert "omaroutines" in r.stdout

    r = cli("bogus-command")
    assert r.returncode == 1


# --- concurrency --------------------------------------------------------------


def test_concurrent_add_no_lost_writes(cli, state_home, cwd_dir):
    names = [f"task-{i}" for i in range(20)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
        results = list(
            pool.map(lambda n: cli("add", n, "--prompt", "hi", "--cwd", str(cwd_dir)), names)
        )
    assert all(r.returncode == 0 for r in results), [r.stderr for r in results]

    data = tasks_json(state_home)
    assert len(data["tasks"]) == 20
    assert {t["name"] for t in data["tasks"]} == set(names)


def test_concurrent_enable_disable_rm_no_corruption(cli, state_home, cwd_dir):
    names = [f"ct-{i}" for i in range(10)]
    for n in names:
        cli("add", n, "--prompt", "hi", "--cwd", str(cwd_dir))

    ops = []
    for n in names[:5]:
        ops.append(("enable", n))
        ops.append(("disable", n))
    for n in names[5:]:
        ops.append(("rm", n))

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(ops)) as pool:
        results = list(pool.map(lambda op: cli(*op), ops))

    # No crashes; state file stays valid JSON with the expected surviving set.
    assert all(r.returncode == 0 for r in results), [r.stderr for r in results]
    data = tasks_json(state_home)
    assert {t["name"] for t in data["tasks"]} == set(names[:5])


# --- ticket 02: schedule validation + next_due --------------------------------


def test_schedule_daily_next_due(cli, state_home, cwd_dir):
    r = cli(
        "add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir), "--schedule", "daily",
        env_overrides={"OMAROUTINES_NOW": str(FROZEN_NOW)},
    )
    assert r.returncode == 0, r.stderr
    t = task_by_name(state_home, "t1")
    assert t["schedule"] == "*-*-* 00:00:00"
    assert t["next_due"] == NEXT_DUE_DAILY


def test_schedule_weekly_next_due(cli, state_home, cwd_dir):
    r = cli(
        "add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir),
        "--schedule", "Mon *-*-* 09:00:00",
        env_overrides={"OMAROUTINES_NOW": str(FROZEN_NOW)},
    )
    assert r.returncode == 0, r.stderr
    t = task_by_name(state_home, "t1")
    assert t["schedule"] == "Mon *-*-* 09:00:00"
    assert t["next_due"] == NEXT_DUE_WEEKLY_MON_9


def test_schedule_every_15_minutes_next_due(cli, state_home, cwd_dir):
    r = cli(
        "add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir),
        "--schedule", "*-*-* *:00/15:00",
        env_overrides={"OMAROUTINES_NOW": str(FROZEN_NOW)},
    )
    assert r.returncode == 0, r.stderr
    t = task_by_name(state_home, "t1")
    assert t["schedule"] == "*-*-* *:00/15:00"
    assert t["next_due"] == NEXT_DUE_EVERY_15MIN


def test_invalid_schedule_rejected(cli, state_home, cwd_dir):
    r = cli("add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir), "--schedule", "bogus expr")
    assert r.returncode == 1
    assert "calendar" in r.stderr
    assert task_by_name(state_home, "t1") is None


def test_manual_schedule_has_no_next_due(cli, state_home, cwd_dir):
    r = cli("add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir), "--schedule", "manual")
    assert r.returncode == 0, r.stderr
    t = task_by_name(state_home, "t1")
    assert t["schedule"] == "manual"
    assert t["next_due"] is None


def test_edit_schedule_recomputes_next_due(cli, state_home, cwd_dir):
    cli("add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir))
    assert task_by_name(state_home, "t1")["next_due"] is None

    r = cli(
        "edit", "t1", "--schedule", "daily",
        env_overrides={"OMAROUTINES_NOW": str(FROZEN_NOW)},
    )
    assert r.returncode == 0, r.stderr
    t = task_by_name(state_home, "t1")
    assert t["schedule"] == "*-*-* 00:00:00"
    assert t["next_due"] == NEXT_DUE_DAILY


def test_edit_calendar_to_manual_clears_next_due(cli, state_home, cwd_dir):
    cli(
        "add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir), "--schedule", "daily",
        env_overrides={"OMAROUTINES_NOW": str(FROZEN_NOW)},
    )
    assert task_by_name(state_home, "t1")["next_due"] is not None

    r = cli("edit", "t1", "--schedule", "manual")
    assert r.returncode == 0, r.stderr
    t = task_by_name(state_home, "t1")
    assert t["schedule"] == "manual"
    assert t["next_due"] is None


def test_edit_invalid_schedule_does_not_mutate(cli, state_home, cwd_dir):
    cli("add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir), "--schedule", "daily")
    before = task_by_name(state_home, "t1")

    r = cli("edit", "t1", "--schedule", "not a valid expr")
    assert r.returncode == 1
    assert "calendar" in r.stderr
    assert task_by_name(state_home, "t1") == before


def test_edit_unknown_task_fails(cli, state_home):
    r = cli("edit", "nosuch", "--prompt", "hi")
    assert r.returncode == 1


def test_edit_permission_mode_none_clears(cli, state_home, cwd_dir):
    cli("add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir), "--permission-mode", "acceptEdits")
    assert task_by_name(state_home, "t1")["permission_mode"] == "acceptEdits"

    r = cli("edit", "t1", "--permission-mode", "none")
    assert r.returncode == 0, r.stderr
    assert task_by_name(state_home, "t1")["permission_mode"] is None


def test_edit_prompt_and_cwd(cli, state_home, cwd_dir, tmp_path):
    cli("add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir))
    new_dir = tmp_path / "elsewhere"
    new_dir.mkdir()
    subprocess.run(["git", "init", "-q", str(new_dir)], check=True, capture_output=True)
    r = cli("edit", "t1", "--prompt", "new prompt", "--cwd", str(new_dir))
    assert r.returncode == 0, r.stderr
    t = task_by_name(state_home, "t1")
    assert t["prompt"] == "new prompt"
    assert t["cwd"] == str(new_dir.resolve())


def test_add_rejects_unknown_permission_mode(cli, state_home, cwd_dir):
    r = cli("add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir), "--permission-mode", "yolo")
    assert r.returncode == 1
    assert "invalid permission mode" in r.stderr
    assert task_by_name(state_home, "t1") is None


def test_edit_rejects_unknown_permission_mode(cli, state_home, cwd_dir):
    cli("add", "t1", "--prompt", "hi", "--cwd", str(cwd_dir))
    r = cli("edit", "t1", "--permission-mode", "yolo")
    assert r.returncode == 1
    assert "invalid permission mode" in r.stderr
    assert task_by_name(state_home, "t1")["permission_mode"] is None


def test_add_worktree_requires_git_repo(cli, state_home, tmp_path):
    plain = tmp_path / "plain"
    plain.mkdir()
    r = cli("add", "t1", "--prompt", "hi", "--cwd", str(plain))
    assert r.returncode != 0
    assert "not a git repository" in r.stderr
    assert not (state_home / "omaroutines" / "tasks.json").exists()
    # worktree=false does not need a repo
    r = cli("add", "t1", "--prompt", "hi", "--cwd", str(plain), "--worktree", "false")
    assert r.returncode == 0, r.stderr


def test_edit_worktree_requires_git_repo(cli, state_home, cwd_dir, tmp_path):
    plain = tmp_path / "plain"
    plain.mkdir()
    cli("add", "t1", "--prompt", "hi", "--cwd", str(plain), "--worktree", "false")
    # turning worktree on while cwd is not a repo
    r = cli("edit", "t1", "--worktree", "true")
    assert r.returncode != 0 and "not a git repository" in r.stderr
    assert task_by_name(state_home, "t1")["worktree"] is False
    # moving a worktree task to a non-repo cwd
    cli("add", "t2", "--prompt", "hi", "--cwd", str(cwd_dir))
    r = cli("edit", "t2", "--cwd", str(plain))
    assert r.returncode != 0 and "not a git repository" in r.stderr
    assert task_by_name(state_home, "t2")["cwd"] == str(cwd_dir.resolve())
    # both at once, consistent, is fine
    r = cli("edit", "t2", "--cwd", str(plain), "--worktree", "false")
    assert r.returncode == 0, r.stderr
