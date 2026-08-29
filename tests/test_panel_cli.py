"""Panel-facing CLI additions (.scratch/oma-schedule-panel/spec.md):
`resume <id> --terminal`, `last_run.session_available` in `list --json`, and
`session_available` / `log_path` in `log --json`. Session files come from
the fake claude (FAKE_CLAUDE_PROJECTS_DIR), never hand-written.
"""

import json
import time

from test_exec import add_task, runs_for

# Records its argv (one per line) to $FAKE_TERMINAL_LOG; stands in for
# xdg-terminal-exec.
FAKE_TERMINAL_SCRIPT = """#!/bin/bash
printf '%s\\n' "$@" >"${FAKE_TERMINAL_LOG:?}"
"""


def wait_for_file(path, timeout=5):
    deadline = time.monotonic() + timeout
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    return path.exists()


def session_env(claude_home, **extra):
    return {"FAKE_CLAUDE_PROJECTS_DIR": str(claude_home / "projects"), **extra}


def run_once(cli, cwd_dir, claude_home):
    add_task(cli, "t1", cwd_dir, worktree="false")
    r = cli("trigger", "t1", env_overrides=session_env(claude_home))
    assert r.returncode == 0, r.stderr


def session_file(claude_home, run):
    return claude_home / "projects" / "proj" / f"{run['session_id']}.jsonl"


def terminal_env(tmp_path, claude_home):
    script = tmp_path / "fake-terminal"
    script.write_text(FAKE_TERMINAL_SCRIPT)
    script.chmod(0o755)
    log = tmp_path / "terminal.log"
    return log, {"OMA_SCHEDULE_TERMINAL_BIN": str(script), "FAKE_TERMINAL_LOG": str(log)}


# --- resume --terminal ----------------------------------------------------------


def test_resume_terminal_launches_terminal_when_session_exists(cli, state_home, cwd_dir, claude_home, tmp_path):
    run_once(cli, cwd_dir, claude_home)
    run = runs_for(state_home, "t1")[0]
    assert session_file(claude_home, run).exists()
    log, env = terminal_env(tmp_path, claude_home)

    r = cli("resume", str(run["id"]), "--terminal", env_overrides=env)
    assert r.returncode == 0, r.stderr
    assert wait_for_file(log), "terminal was never launched"
    argv = log.read_text().splitlines()
    assert argv[0].endswith("/oma-schedule")
    assert argv[1:] == ["resume", str(run["id"])]


def test_resume_terminal_fails_without_launching_when_session_gone(cli, state_home, cwd_dir, claude_home, tmp_path):
    run_once(cli, cwd_dir, claude_home)
    run = runs_for(state_home, "t1")[0]
    session_file(claude_home, run).unlink()
    log, env = terminal_env(tmp_path, claude_home)

    r = cli("resume", str(run["id"]), "--terminal", env_overrides=env)
    assert r.returncode == 1
    assert "session no longer available" in r.stderr
    time.sleep(0.3)
    assert not log.exists()


def test_resume_terminal_unknown_run_fails(cli, state_home, tmp_path, claude_home):
    log, env = terminal_env(tmp_path, claude_home)
    r = cli("resume", "9999", "--terminal", env_overrides=env)
    assert r.returncode == 1
    assert "no such run" in r.stderr
    assert not log.exists()


# --- session_available / log_path -----------------------------------------------


def listing(cli):
    r = cli("list", "--json")
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def log_json(cli, name):
    r = cli("log", name, "--json")
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def test_list_last_run_session_available_tracks_session_file(cli, state_home, cwd_dir, claude_home):
    run_once(cli, cwd_dir, claude_home)
    run = runs_for(state_home, "t1")[0]
    lr = listing(cli)["tasks"][0]["last_run"]
    assert lr["session_available"] is True
    assert set(lr) == {"id", "status", "trigger", "start", "end", "session_available", "backend", "reason", "pane_id", "pane_available"}

    session_file(claude_home, run).unlink()
    assert listing(cli)["tasks"][0]["last_run"]["session_available"] is False


def test_log_json_session_available_and_log_path(cli, state_home, cwd_dir, claude_home):
    run_once(cli, cwd_dir, claude_home)
    # second run without a session file: per-run flags must differ
    r = cli("trigger", "t1")
    assert r.returncode == 0, r.stderr

    runs = log_json(cli, "t1")
    assert [x["id"] for x in runs] == [2, 1]
    assert runs[1]["session_available"] is True
    assert runs[0]["session_available"] is False
    for x in runs:
        assert x["log_path"] == str(state_home / "oma-schedule" / "logs" / f"{x['id']}.out")
        assert (state_home / "oma-schedule" / "logs" / f"{x['id']}.out").exists()

    (state_home / "oma-schedule" / "logs" / "1.out").unlink()
    runs = log_json(cli, "t1")
    assert runs[1]["log_path"] is None
    assert runs[0]["log_path"] is not None
