"""Tests for ticket 03 (execution engine) + ticket 06 (log/resume), driven
through `oma-schedule trigger/log/resume` against a fake `claude` binary
(tests/conftest.py) and a throwaway git repo as task cwd.
"""

import concurrent.futures
import json
import subprocess


def runs_json(state_home):
    return json.loads((state_home / "oma-schedule" / "runs.json").read_text())


def runs_for(state_home, task):
    return [r for r in runs_json(state_home)["runs"] if r["task"] == task]


def add_task(cli, name, cwd, **opts):
    args = ["add", name, "--prompt", "do the thing", "--cwd", str(cwd)]
    for k, v in opts.items():
        args += [f"--{k.replace('_', '-')}", str(v)]
    r = cli(*args)
    assert r.returncode == 0, r.stderr
    return r


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True)


# --- worktree lifecycle --------------------------------------------------------


def test_trigger_worktree_no_changes_is_removed(cli, state_home, git_repo, calls_dir):
    add_task(cli, "t1", git_repo)
    r = cli("trigger", "t1")
    assert r.returncode == 0, r.stderr
    assert "run 1: success" in r.stdout
    assert "session" in r.stdout

    runs = runs_for(state_home, "t1")
    assert len(runs) == 1
    run = runs[0]
    assert run["status"] == "success"
    assert run["exit_code"] == 0
    assert run["worktree_path"] is None
    assert run["worktree_branch"] is None
    assert run["session_id"]

    # worktree + branch cleaned up
    wt_list = git(git_repo, "worktree", "list").stdout
    assert ".worktrees" not in wt_list
    branches = git(git_repo, "branch", "--list", "oma-schedule/*").stdout
    assert branches.strip() == ""

    # claude ran inside the (now-removed) worktree, not the main checkout
    pwd_file = calls_dir / f"{run['session_id']}.pwd"
    assert pwd_file.exists()
    assert ".worktrees" in pwd_file.read_text()


def test_trigger_worktree_with_changes_is_kept(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    r = cli("trigger", "t1", env_overrides={"FAKE_CLAUDE_TOUCH": "1"})
    assert r.returncode == 0, r.stderr

    run = runs_for(state_home, "t1")[0]
    assert run["worktree_path"] is not None
    assert run["worktree_branch"] is not None
    from pathlib import Path

    assert Path(run["worktree_path"]).is_dir()
    branches = git(git_repo, "branch", "--list", "oma-schedule/*").stdout
    assert run["worktree_branch"].split("/", 1)[1] in branches


def test_trigger_worktree_false_runs_directly_in_cwd(cli, state_home, git_repo, calls_dir):
    add_task(cli, "t1", git_repo, worktree="false")
    r = cli("trigger", "t1")
    assert r.returncode == 0, r.stderr

    run = runs_for(state_home, "t1")[0]
    assert run["worktree_path"] is None
    assert run["worktree_branch"] is None
    assert run["cwd"] == str(git_repo)

    pwd_file = calls_dir / f"{run['session_id']}.pwd"
    assert pwd_file.read_text().strip() == str(git_repo)
    assert not (git_repo / ".worktrees").exists()


# --- permission mode -------------------------------------------------------


def _argv_for(calls_dir, session_id):
    return (calls_dir / f"{session_id}.argv").read_text().splitlines()


def test_permission_mode_task_override(cli, state_home, git_repo, calls_dir, claude_home):
    (claude_home / "settings.json").write_text(json.dumps({"permissions": {"defaultMode": "auto"}}))
    add_task(cli, "t1", git_repo, permission_mode="acceptEdits")
    cli("trigger", "t1")
    run = runs_for(state_home, "t1")[0]
    assert run["permission_mode"] == "acceptEdits"
    argv = _argv_for(calls_dir, run["session_id"])
    assert "acceptEdits" in argv[argv.index("--permission-mode") + 1]


def test_permission_mode_falls_back_to_settings_json(cli, state_home, git_repo, calls_dir, claude_home):
    (claude_home / "settings.json").write_text(json.dumps({"permissions": {"defaultMode": "auto"}}))
    add_task(cli, "t1", git_repo)
    cli("trigger", "t1")
    run = runs_for(state_home, "t1")[0]
    assert run["permission_mode"] == "auto"


def test_permission_mode_falls_back_to_default_when_no_settings(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    cli("trigger", "t1")
    run = runs_for(state_home, "t1")[0]
    assert run["permission_mode"] == "default"


# --- failure handling --------------------------------------------------------


def test_claude_failure_marks_run_failed_and_exits_nonzero(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    r = cli("trigger", "t1", env_overrides={"FAKE_CLAUDE_EXIT": "1"})
    assert r.returncode == 1
    assert "run 1: failure" in r.stdout
    run = runs_for(state_home, "t1")[0]
    assert run["status"] == "failure"
    assert run["exit_code"] == 1


# --- concurrency --------------------------------------------------------------


def test_concurrent_triggers_get_isolated_worktrees(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(
            pool.map(lambda _: cli("trigger", "t1", env_overrides={"FAKE_CLAUDE_TOUCH": "1"}), range(4))
        )
    assert all(r.returncode == 0 for r in results), [r.stderr for r in results]

    runs = runs_for(state_home, "t1")
    assert len(runs) == 4
    assert all(r["status"] == "success" for r in runs)
    ids = {r["id"] for r in runs}
    assert len(ids) == 4
    paths = {r["worktree_path"] for r in runs}
    branches = {r["worktree_branch"] for r in runs}
    assert len(paths) == 4
    assert len(branches) == 4


# --- log ordering + pruning ---------------------------------------------------


def test_log_unknown_task_fails(cli, state_home):
    r = cli("log", "nosuch")
    assert r.returncode == 1


def test_log_no_runs_yet(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    r = cli("log", "t1")
    assert r.returncode == 0
    assert "no runs yet" in r.stdout


def test_log_newest_first_and_json_shape(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo, worktree="false")
    cli("trigger", "t1")
    cli("trigger", "t1")
    cli("trigger", "t1")

    r = cli("log", "t1")
    assert r.returncode == 0
    lines = [l for l in r.stdout.splitlines() if l.strip().startswith("#")]
    ids = [int(l.split()[0].lstrip("#")) for l in lines]
    assert ids == sorted(ids, reverse=True)

    r = cli("log", "t1", "--json")
    assert r.returncode == 0
    payload = json.loads(r.stdout)
    assert [p["id"] for p in payload] == sorted((p["id"] for p in payload), reverse=True)
    assert all("session_id" in p and "worktree_path" in p and "worktree_branch" in p for p in payload)


def test_pruning_keeps_newest_retain_runs(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo, worktree="false")
    for _ in range(22):
        r = cli("trigger", "t1")
        assert r.returncode == 0, r.stderr

    runs = runs_for(state_home, "t1")
    assert len(runs) == 20
    ids = sorted(r["id"] for r in runs)
    assert ids == list(range(3, 23))


# --- resume --------------------------------------------------------------------


def test_resume_live_session(cli, state_home, git_repo, claude_home):
    add_task(cli, "t1", git_repo, worktree="false")
    cli("trigger", "t1")
    run = runs_for(state_home, "t1")[0]
    sid = run["session_id"]
    proj_dir = claude_home / "projects" / "x"
    proj_dir.mkdir(parents=True)
    (proj_dir / f"{sid}.jsonl").write_text("{}\n")

    r = cli("resume", str(run["id"]))
    assert r.returncode == 0, r.stderr
    assert f"RESUMED {sid}" in r.stdout


def test_resume_missing_session_fails(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo, worktree="false")
    cli("trigger", "t1")
    run = runs_for(state_home, "t1")[0]

    r = cli("resume", str(run["id"]))
    assert r.returncode == 1
    assert "session no longer available" in r.stderr
    assert str(run["id"]) in r.stderr


def test_resume_unknown_run_fails(cli, state_home):
    r = cli("resume", "9999")
    assert r.returncode == 1


# --- misc --------------------------------------------------------------------


def test_run_log_file_captures_claude_output(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo, worktree="false")
    cli("trigger", "t1")
    run = runs_for(state_home, "t1")[0]
    log_file = state_home / "oma-schedule" / "logs" / f"{run['id']}.out"
    assert log_file.exists()
    assert "result" in log_file.read_text()


def test_trigger_unknown_task_fails(cli, state_home):
    r = cli("trigger", "nosuch")
    assert r.returncode == 1


def test_trigger_disabled_task_still_runs(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo, worktree="false")
    cli("disable", "t1")
    r = cli("trigger", "t1")
    assert r.returncode == 0, r.stderr
    assert "run 1: success" in r.stdout


def test_trigger_on_repo_without_commits_fails_cleanly(cli, state_home, tmp_path, fake_claude_bin, claude_home):
    # `git rev-parse HEAD` fails on an empty repo; the run must still be finalized
    repo = tmp_path / "empty-repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repo, check=True)
    cli("add", "t", "--prompt", "p", "--cwd", str(repo))
    r = cli("trigger", "t")
    assert r.returncode == 1
    runs = json.loads((state_home / "oma-schedule" / "runs.json").read_text())["runs"]
    assert len(runs) == 1 and runs[0]["status"] == "failure"
    assert subprocess.run(["git", "worktree", "list"], cwd=repo, capture_output=True, text=True).stdout.count("\n") == 1


def test_invalid_settings_json_mode_fails_run_without_invoking_claude(
    cli, state_home, git_repo, calls_dir, claude_home
):
    (claude_home / "settings.json").write_text(json.dumps({"permissions": {"defaultMode": "yolo"}}))
    add_task(cli, "t1", git_repo, worktree="false")
    r = cli("trigger", "t1")
    assert r.returncode == 1
    assert "invalid permission mode" in r.stderr
    run = runs_for(state_home, "t1")[0]
    assert run["status"] == "failure"
    assert not list(calls_dir.glob("*.argv"))


def test_log_files_are_private(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo, worktree="false")
    cli("trigger", "t1")
    logs = state_home / "oma-schedule" / "logs"
    assert logs.stat().st_mode & 0o777 == 0o700
    assert (logs / "1.out").stat().st_mode & 0o777 == 0o600


def test_log_files_pruned_with_runs(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo, worktree="false")
    for _ in range(22):
        cli("trigger", "t1")
    ids = {r["id"] for r in runs_for(state_home, "t1")}
    assert len(ids) == 20
    logs = state_home / "oma-schedule" / "logs"
    on_disk = {int(p.stem) for p in logs.glob("*.out")}
    assert on_disk == ids
