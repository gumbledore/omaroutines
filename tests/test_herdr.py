"""Ticket 02 (.scratch/herdr-backend): the herdr backend, driven through
`trigger` against tests/stubs/herdr + tests/stubs/systemctl (conftest wires
them; STUB_DIR holds the stub's state and control files).
"""

import json
import os
import stat
from pathlib import Path

import pytest

from test_exec import add_task, runs_for


def stub_log(stub_dir):
    p = stub_dir / "log"
    return p.read_text().splitlines() if p.exists() else []


def herdr_calls(stub_dir):
    return [l for l in stub_log(stub_dir) if l.startswith("herdr ")]


def systemctl_calls(stub_dir):
    return [l for l in stub_log(stub_dir) if l.startswith("systemctl ")]


def agents(stub_dir):
    p = stub_dir / "agents.json"
    return json.loads(p.read_text()) if p.exists() else []


def log_file(state_home, run):
    return state_home / "omaroutines" / "logs" / f"{run['id']}.out"


@pytest.fixture
def herdr_cli(cli):
    r = cli("settings", "set", "execution", "herdr")
    assert r.returncode == 0, r.stderr
    return cli


# --- server + session -----------------------------------------------------------


def test_server_started_and_enabled_when_down(herdr_cli, state_home, cwd_dir, stub_dir):
    (stub_dir / "herdr-down").touch()
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    r = herdr_cli("trigger", "t1")
    assert r.returncode == 0, r.stderr
    assert "run 1: success" in r.stdout
    calls = systemctl_calls(stub_dir)
    assert calls == ["systemctl --user start omaroutines-herdr.service", "systemctl --user enable omaroutines-herdr.service"]
    assert all(l.endswith("[HERDR_SESSION=omaroutines]") for l in herdr_calls(stub_dir))


def test_server_untouched_when_up(herdr_cli, state_home, cwd_dir, stub_dir):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    assert herdr_cli("trigger", "t1").returncode == 0
    assert systemctl_calls(stub_dir) == []


def test_default_session_unsets_env_and_never_uses_the_unit(herdr_cli, state_home, cwd_dir, stub_dir):
    herdr_cli("settings", "set", "herdr_session", "default")
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    assert herdr_cli("trigger", "t1").returncode == 0
    assert all(l.endswith("[HERDR_SESSION=<unset>]") for l in herdr_calls(stub_dir))

    (stub_dir / "herdr-down").touch()
    r = herdr_cli("trigger", "t1")
    assert r.returncode == 1
    assert "herdr server is not running" in r.stderr
    assert systemctl_calls(stub_dir) == []
    run = runs_for(state_home, "t1")[-1]
    assert run["status"] == "failure" and run["reason"] == "exited"


# --- workspace / tab / agent ---------------------------------------------------


def test_workspace_reused_by_label_new_tab_per_run(herdr_cli, state_home, cwd_dir, stub_dir):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    add_task(herdr_cli, "t2", cwd_dir, worktree="false")
    assert herdr_cli("trigger", "t1").returncode == 0
    assert herdr_cli("trigger", "t2").returncode == 0
    ws = json.loads((stub_dir / "workspaces.json").read_text())
    assert [w["label"] for w in ws] == [cwd_dir.name]
    assert sum(1 for l in herdr_calls(stub_dir) if l.startswith("herdr workspace create")) == 1
    tabs = [l for l in herdr_calls(stub_dir) if l.startswith("herdr tab create")]
    assert len(tabs) == 2 and all("--no-focus" in l and "--workspace w1" in l for l in tabs)
    r1, r2 = runs_for(state_home, "t1")[0], runs_for(state_home, "t2")[0]
    assert r1["workspace_id"] == r2["workspace_id"] == "w1"
    assert r1["pane_id"] != r2["pane_id"]
    assert r1["tab_id"] and r2["tab_id"]
    assert [a["name"] for a in agents(stub_dir)] == ["t1-1", "t2-2"]


@pytest.mark.parametrize("kind,flags", [
    ("claude", ["--permission-mode", "auto"]),
    ("codex", ["--approve-for-me"]),
    ("gemini", ["--yolo"]),
    ("opencode", ["--auto"]),
    ("copilot", ["--allow-all"]),
    ("omp", ["--auto-approve"]),
    ("grok", ["--permission-mode", "bypassPermissions"]),
    ("pi", []),
])
def test_unattended_flags_per_kind(herdr_cli, state_home, cwd_dir, stub_dir, kind, flags):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false", agent=kind, permission_mode="plan")
    assert herdr_cli("trigger", "t1").returncode == 0
    start = next(l for l in herdr_calls(stub_dir) if l.startswith("herdr agent start"))
    assert f"--kind {kind}" in start
    args = (stub_dir / "start-args.t1-1").read_text().split()
    assert args == flags  # task permission_mode ignored
    assert (stub_dir / "prompt.t1-1").read_text().strip() == "do the thing"


def test_agent_name_collision_retries_with_suffix(herdr_cli, state_home, cwd_dir, stub_dir):
    (stub_dir / "start-outcome").write_text("taken")
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    assert herdr_cli("trigger", "t1").returncode == 0
    names = [a["name"] for a in agents(stub_dir)]
    assert len(names) == 1 and names[0].startswith("t1-1-")


# --- state mapping ---------------------------------------------------------------


@pytest.mark.parametrize("outcome,status,reason", [
    ("done", "success", None),
    ("idle", "success", None),
    ("blocked", "failure", "blocked"),
    ("working", "failure", "timeout"),
    ("vanish", "failure", "exited"),
])
def test_settled_state_mapping(herdr_cli, state_home, cwd_dir, stub_dir, outcome, status, reason):
    (stub_dir / "prompt-outcome").write_text(outcome)
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    r = herdr_cli("trigger", "t1")
    assert (r.returncode == 0) == (status == "success")
    assert f"run 1: {status}" in r.stdout
    run = runs_for(state_home, "t1")[0]
    assert run["status"] == status
    assert run["reason"] == reason
    assert run["backend"] == "herdr"
    assert run["session_id"] is None
    assert run["end"] is not None
    # the pane is never killed by the sweep
    assert not any(l.startswith("herdr tab close") for l in herdr_calls(stub_dir))
    if outcome != "vanish":
        assert run["pane_id"] is not None


def test_blocked_at_startup_is_failure_blocked(herdr_cli, state_home, cwd_dir, stub_dir):
    (stub_dir / "start-outcome").write_text("blocked")
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    r = herdr_cli("trigger", "t1")
    assert r.returncode == 1
    run = runs_for(state_home, "t1")[0]
    assert (run["status"], run["reason"]) == ("failure", "blocked")
    assert run["pane_id"] is not None
    assert not any(l.startswith("herdr agent prompt") for l in herdr_calls(stub_dir))


def test_timeout_comes_from_task_then_settings(herdr_cli, state_home, cwd_dir, stub_dir):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    herdr_cli("trigger", "t1")
    assert "--timeout\n3600000" in (stub_dir / "prompt-args.t1-1").read_text()
    herdr_cli("settings", "set", "herdr_timeout_minutes", "5")
    herdr_cli("trigger", "t1")
    assert "--timeout\n300000" in (stub_dir / "prompt-args.t1-2").read_text()
    herdr_cli("edit", "t1", "--herdr-timeout", "2")
    herdr_cli("trigger", "t1")
    assert "--timeout\n120000" in (stub_dir / "prompt-args.t1-3").read_text()
    herdr_cli("trigger", "t1", env_overrides={"OMAROUTINES_HERDR_TIMEOUT": "7"})
    assert "--timeout\n7000" in (stub_dir / "prompt-args.t1-4").read_text()


# --- transcript + log file --------------------------------------------------------


def test_transcript_snapshot_written_with_private_modes(herdr_cli, state_home, cwd_dir):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    assert herdr_cli("trigger", "t1").returncode == 0
    run = runs_for(state_home, "t1")[0]
    f = log_file(state_home, run)
    assert "TRANSCRIPT of t1-1" in f.read_text()
    assert stat.S_IMODE(f.stat().st_mode) == 0o600
    assert stat.S_IMODE(f.parent.stat().st_mode) == 0o700
    r = herdr_cli("log", "t1", "--json")
    entry = json.loads(r.stdout)[0]
    assert entry["backend"] == "herdr" and entry["log_path"] == str(f)
    assert entry["pane_available"] is True
    assert entry["session_available"] is False


def test_pane_available_false_when_server_down_or_pane_gone(herdr_cli, state_home, cwd_dir, stub_dir):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    herdr_cli("trigger", "t1")
    run = runs_for(state_home, "t1")[0]

    def last_run():
        return next(t for t in json.loads(herdr_cli("list", "--json").stdout)["tasks"] if t["name"] == "t1")["last_run"]

    assert last_run()["pane_available"] is True
    (stub_dir / "herdr-down").touch()
    assert last_run()["pane_available"] is False
    (stub_dir / "herdr-down").unlink()
    (stub_dir / "panes.json").write_text("[]")
    assert last_run()["pane_available"] is False
    assert json.loads(herdr_cli("log", "t1", "--json").stdout)[0]["pane_available"] is False


# --- worktree + retention -------------------------------------------------------------


def test_unchanged_worktree_kept_while_pane_open_and_prune_skips_it(herdr_cli, state_home, git_repo):
    add_task(herdr_cli, "t1", git_repo)
    assert herdr_cli("trigger", "t1").returncode == 0
    run = runs_for(state_home, "t1")[0]
    assert run["worktree_path"] is not None and os.path.isdir(run["worktree_path"])
    assert run["cwd"] == run["worktree_path"]
    r = herdr_cli("prune")
    assert r.returncode == 0 and "pruned" not in r.stdout
    assert runs_for(state_home, "t1")[0]["worktree_path"] is not None


def test_headless_task_override_still_runs_claude(herdr_cli, state_home, cwd_dir, stub_dir, calls_dir):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false", execution="headless")
    assert herdr_cli("trigger", "t1").returncode == 0
    assert herdr_calls(stub_dir) == []
    run = runs_for(state_home, "t1")[0]
    assert run["backend"] == "headless" and run["session_id"]


# --- attach (ticket 03) ----------------------------------------------------------


def terminal_env(tmp_path):
    from test_panel_cli import FAKE_TERMINAL_SCRIPT
    script = tmp_path / "fake-terminal"
    script.write_text(FAKE_TERMINAL_SCRIPT)
    script.chmod(0o755)
    log = tmp_path / "terminal.log"
    return log, {"OMAROUTINES_TERMINAL_BIN": str(script), "FAKE_TERMINAL_LOG": str(log)}


def test_attach_focuses_agent_then_attaches_session(herdr_cli, state_home, cwd_dir, stub_dir):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    herdr_cli("trigger", "t1")
    run = runs_for(state_home, "t1")[0]
    r = herdr_cli("attach", str(run["id"]))
    assert r.returncode == 0, r.stderr
    assert "ATTACHED omaroutines" in r.stdout
    calls = herdr_calls(stub_dir)
    assert calls[-2].startswith("herdr agent focus t1-1")
    assert calls[-1].startswith("herdr session attach omaroutines")


def test_attach_default_session_runs_bare_herdr(herdr_cli, state_home, cwd_dir, stub_dir):
    herdr_cli("settings", "set", "herdr_session", "default")
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    herdr_cli("trigger", "t1")
    r = herdr_cli("attach", "1")
    assert r.returncode == 0, r.stderr
    assert "ATTACHED default" in r.stdout
    assert herdr_calls(stub_dir)[-1] == "herdr  [HERDR_SESSION=<unset>]"


def test_attach_terminal_detaches_via_launcher(herdr_cli, state_home, cwd_dir, tmp_path):
    from test_panel_cli import wait_for_file
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    herdr_cli("trigger", "t1")
    log, env = terminal_env(tmp_path)
    r = herdr_cli("attach", "1", "--terminal", env_overrides=env)
    assert r.returncode == 0, r.stderr
    assert wait_for_file(log)
    argv = log.read_text().splitlines()
    assert argv[0].endswith("/omaroutines") and argv[1:] == ["attach", "1"]


def test_attach_refuses_when_pane_gone_or_server_down(herdr_cli, state_home, cwd_dir, stub_dir, tmp_path):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    herdr_cli("trigger", "t1")
    log, env = terminal_env(tmp_path)
    (stub_dir / "herdr-down").touch()
    r = herdr_cli("attach", "1", "--terminal", env_overrides=env)
    assert r.returncode == 1 and "not available" in r.stderr
    (stub_dir / "herdr-down").unlink()
    (stub_dir / "panes.json").write_text("[]")
    r = herdr_cli("attach", "1", env_overrides=env)
    assert r.returncode == 1 and "not available" in r.stderr
    assert not log.exists()
    assert herdr_cli("attach", "77").returncode == 1


def test_attach_and_resume_cross_hints(herdr_cli, state_home, cwd_dir, claude_home):
    add_task(herdr_cli, "h", cwd_dir, worktree="false")
    add_task(herdr_cli, "c", cwd_dir, worktree="false", execution="headless")
    herdr_cli("trigger", "h")
    herdr_cli("trigger", "c", env_overrides={"FAKE_CLAUDE_PROJECTS_DIR": str(claude_home / "projects")})
    r = herdr_cli("resume", "1")
    assert r.returncode == 1 and "omaroutines attach 1" in r.stderr
    r = herdr_cli("attach", "2")
    assert r.returncode == 1 and "omaroutines resume 2" in r.stderr


# --- pane retention (ticket 04) -------------------------------------------------


def panes(stub_dir):
    p = stub_dir / "panes.json"
    return json.loads(p.read_text()) if p.exists() else []


def test_retain_closes_oldest_panes_beyond_limit(herdr_cli, state_home, cwd_dir, stub_dir):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    for _ in range(5):
        assert herdr_cli("trigger", "t1").returncode == 0
    runs = runs_for(state_home, "t1")
    assert len(runs) == 5
    assert [r["pane_id"] is None for r in runs] == [True, True, False, False, False]
    assert [r["tab_id"] is None for r in runs] == [True, True, False, False, False]
    live = {p["pane_id"] for p in panes(stub_dir)}
    assert {r["pane_id"] for r in runs[2:]} <= live
    assert len([a for a in agents(stub_dir) if a["name"].startswith("t1-")]) == 3
    closes = [l for l in herdr_calls(stub_dir) if l.startswith("herdr tab close")]
    assert len(closes) == 2
    # log entries + files survive pane pruning
    for r in runs[:2]:
        assert log_file(state_home, r).exists()


def test_retain_setting_respected_and_per_task(herdr_cli, state_home, cwd_dir, stub_dir):
    herdr_cli("settings", "set", "herdr_retain", "1")
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    add_task(herdr_cli, "t2", cwd_dir, worktree="false")
    for _ in range(2):
        herdr_cli("trigger", "t1")
        herdr_cli("trigger", "t2")
    for name in ("t1", "t2"):
        runs = runs_for(state_home, name)
        assert [r["pane_id"] is None for r in runs] == [True, False]
    assert len(agents(stub_dir)) == 2


def test_working_and_blocked_panes_never_pruned(herdr_cli, state_home, cwd_dir, stub_dir):
    herdr_cli("settings", "set", "herdr_retain", "1")
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    (stub_dir / "prompt-outcome").write_text("blocked")
    herdr_cli("trigger", "t1")
    (stub_dir / "prompt-outcome").write_text("working")
    herdr_cli("trigger", "t1")
    (stub_dir / "prompt-outcome").write_text("done")
    for _ in range(3):
        herdr_cli("trigger", "t1")
    runs = runs_for(state_home, "t1")
    assert runs[0]["reason"] == "blocked" and runs[0]["pane_id"] is not None
    assert runs[1]["reason"] == "timeout" and runs[1]["pane_id"] is not None
    assert runs[2]["pane_id"] is None and runs[3]["pane_id"] is None  # settled, beyond retain=1
    assert runs[4]["pane_id"] is not None
    assert not any(l.startswith("herdr tab close") and l.split()[3] in (runs[0]["tab_id"], runs[1]["tab_id"]) for l in herdr_calls(stub_dir))


def test_vanished_pane_is_reconciled(herdr_cli, state_home, cwd_dir, stub_dir):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    herdr_cli("trigger", "t1")
    (stub_dir / "panes.json").write_text("[]")
    (stub_dir / "agents.json").write_text("[]")
    herdr_cli("trigger", "t1")
    runs = runs_for(state_home, "t1")
    assert runs[0]["pane_id"] is None and runs[1]["pane_id"] is not None
    assert not any(l.startswith("herdr tab close") for l in herdr_calls(stub_dir))


def test_pruned_pane_removes_unchanged_worktree_but_keeps_changed(herdr_cli, state_home, git_repo, stub_dir):
    herdr_cli("settings", "set", "herdr_retain", "1")
    add_task(herdr_cli, "t1", git_repo)
    herdr_cli("trigger", "t1")  # unchanged worktree, kept while pane lives
    first = runs_for(state_home, "t1")[0]
    assert os.path.isdir(first["worktree_path"])
    (Path(first["worktree_path"]) / "touched.txt").write_text("x")  # dirty the first worktree
    herdr_cli("trigger", "t1")
    runs = runs_for(state_home, "t1")
    # first pane pruned; its worktree was dirtied so it stays
    assert runs[0]["pane_id"] is None
    assert runs[0]["worktree_path"] is not None and os.path.isdir(runs[0]["worktree_path"])
    herdr_cli("trigger", "t1")
    runs = runs_for(state_home, "t1")
    # second pane pruned; its worktree is unchanged -> removed with its branch
    assert runs[1]["pane_id"] is None
    assert runs[1]["worktree_path"] is None and runs[1]["worktree_branch"] is None
    wts = git_repo / ".worktrees"
    assert len(list(wts.iterdir())) == 2  # dirty first + live third
    from test_exec import git
    branches = git(git_repo, "branch", "--list", "omaroutines/*").stdout
    assert branches.count("omaroutines/") == 2


def test_pruned_runs_reenter_ordinary_retention(herdr_cli, state_home, cwd_dir):
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    for _ in range(25):
        assert herdr_cli("trigger", "t1").returncode == 0
    runs = runs_for(state_home, "t1")
    # 20 ordinary + 3 with live panes (kept-worktree semantics); older pruned panes fall off
    assert len(runs) == 23
    assert [r["id"] for r in runs] == list(range(3, 26))
    assert sum(1 for r in runs if r["pane_id"]) == 3
    logs = sorted(int(f.stem) for f in (state_home / "omaroutines" / "logs").glob("*.out"))
    assert logs == list(range(3, 26))


# --- sweep path (no `||` guard around run_task) -----------------------------------


def test_sweep_fired_run_never_stranded_when_herdr_query_fails(herdr_cli, state_home, cwd_dir, stub_dir):
    (stub_dir / "list-fail").touch()
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    r = herdr_cli("run", "t1", "scheduled")  # what launch_run executes under systemd
    run = runs_for(state_home, "t1")[0]
    assert run["status"] in ("success", "failure") and run["end"] is not None
    assert (r.returncode == 0) == (run["status"] == "success")


def test_sweep_runs_herdr_task(herdr_cli, state_home, cwd_dir):
    from test_sweep import SCHEDULE, T
    from test_sweep import add_task as add_frozen
    add_frozen(herdr_cli, "t1", cwd_dir, worktree="false", schedule=SCHEDULE)
    r = herdr_cli("sweep", env_overrides={"OMAROUTINES_NOW": str(T + 900), "OMAROUTINES_SWEEP_WAIT": "1"})
    assert r.returncode == 0, r.stderr
    run = runs_for(state_home, "t1")[0]
    assert run["status"] == "success" and run["backend"] == "herdr" and run["trigger"] == "scheduled"


def test_pane_without_tab_id_is_never_orphaned(herdr_cli, state_home, cwd_dir, stub_dir):
    herdr_cli("settings", "set", "herdr_retain", "1")
    add_task(herdr_cli, "t1", cwd_dir, worktree="false")
    herdr_cli("trigger", "t1")
    p = state_home / "omaroutines" / "runs.json"
    d = json.loads(p.read_text())
    d["runs"][0]["tab_id"] = None  # legacy record
    p.write_text(json.dumps(d))
    herdr_cli("trigger", "t1")
    runs = runs_for(state_home, "t1")
    assert runs[0]["pane_id"] is not None  # kept visible rather than silently leaked
    assert not any(l.startswith("herdr tab close") for l in herdr_calls(stub_dir))


def test_settings_rejects_zero_retain(herdr_cli):
    assert herdr_cli("settings", "set", "herdr_retain", "0").returncode != 0

