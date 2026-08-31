"""Ticket 01 (.scratch/herdr-backend): settings.json bootstrap/merge and the
`settings` CLI, plus agent/execution resolution and validation on tasks.
Driven through the CLI against an isolated XDG_CONFIG_HOME and a fake
`omarchy-default-agent` (tests/conftest.py).
"""

import json

from test_cli import task_by_name
from test_exec import add_task, runs_for


def settings_file(config_home):
    return config_home / "omaroutines" / "settings.json"


def listing_task(cli, name):
    r = cli("list", "--json")
    assert r.returncode == 0, r.stderr
    return next(t for t in json.loads(r.stdout)["tasks"] if t["name"] == name)


# --- settings file ------------------------------------------------------------


def test_settings_creates_file_from_defaults(cli, config_home):
    r = cli("settings")
    assert r.returncode == 0, r.stderr
    printed = json.loads(r.stdout)
    assert printed["schema_version"] == 1
    assert printed["execution"] == "headless"
    assert printed["agent"] is None
    assert printed["herdr_session"] == "omaroutines"
    assert printed["herdr_retain"] == 3
    assert printed["herdr_timeout_minutes"] == 60
    assert json.loads(settings_file(config_home).read_text()) == printed


def test_settings_merge_preserves_user_keys_and_pins_schema_version(cli, config_home):
    f = settings_file(config_home)
    f.parent.mkdir(parents=True)
    f.write_text(json.dumps({"schema_version": 99, "herdr_retain": 7, "custom": "x"}))
    r = cli("settings")
    assert r.returncode == 0, r.stderr
    printed = json.loads(r.stdout)
    assert printed["herdr_retain"] == 7
    assert printed["custom"] == "x"
    assert printed["schema_version"] == 1
    assert printed["execution"] == "headless"  # missing key self-healed
    assert json.loads(f.read_text())["execution"] == "headless"


def test_settings_invalid_json_falls_back_to_defaults(cli, config_home):
    f = settings_file(config_home)
    f.parent.mkdir(parents=True)
    f.write_text("{not json")
    r = cli("settings")
    assert r.returncode == 0
    assert json.loads(r.stdout)["execution"] == "headless"
    assert "not valid JSON" in r.stderr
    assert f.read_text() == "{not json"  # never clobbered


def test_settings_get_and_set(cli, config_home):
    r = cli("settings", "get", "execution")
    assert r.returncode == 0 and r.stdout.strip() == "headless"

    r = cli("settings", "set", "execution", "herdr")
    assert r.returncode == 0, r.stderr
    assert cli("settings", "get", "execution").stdout.strip() == "herdr"
    assert json.loads(settings_file(config_home).read_text())["execution"] == "herdr"

    r = cli("settings", "set", "herdr_retain", "5")
    assert r.returncode == 0, r.stderr
    assert json.loads(settings_file(config_home).read_text())["herdr_retain"] == 5

    r = cli("settings", "set", "agent", "codex")
    assert r.returncode == 0, r.stderr
    r = cli("settings", "set", "agent", "null")
    assert r.returncode == 0, r.stderr
    assert json.loads(settings_file(config_home).read_text())["agent"] is None


def test_settings_set_validates(cli, config_home):
    assert cli("settings", "set", "execution", "sideways").returncode != 0
    assert cli("settings", "set", "herdr_retain", "lots").returncode != 0
    assert cli("settings", "set", "agent", "crush").returncode != 0
    assert cli("settings", "set", "nosuch", "1").returncode != 0
    r = cli("settings", "get", "nosuch")
    assert r.returncode != 0
    # headless + non-claude at the settings layer is rejected
    r = cli("settings", "set", "agent", "codex")
    assert r.returncode != 0
    assert "headless" in r.stderr


# --- task fields --------------------------------------------------------------


def test_add_and_edit_agent_execution_timeout(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, agent="codex", execution="herdr", herdr_timeout="15")
    t = task_by_name(state_home, "t1")
    assert t["agent"] == "codex"
    assert t["execution"] == "herdr"
    assert t["herdr_timeout"] == 15

    add_task(cli, "t2", cwd_dir)
    t = task_by_name(state_home, "t2")
    assert t["agent"] is None and t["execution"] is None and t["herdr_timeout"] is None

    r = cli("edit", "t1", "--agent", "none", "--execution", "none", "--herdr-timeout", "none")
    assert r.returncode == 0, r.stderr
    t = task_by_name(state_home, "t1")
    assert t["agent"] is None and t["execution"] is None and t["herdr_timeout"] is None


def test_add_rejects_bad_values(cli, state_home, cwd_dir):
    base = ["add", "t1", "--prompt", "p", "--cwd", str(cwd_dir)]
    assert cli(*base, "--agent", "crush").returncode != 0
    assert cli(*base, "--agent", "nosuch").returncode != 0
    assert cli(*base, "--execution", "sideways").returncode != 0
    assert cli(*base, "--herdr-timeout", "soon").returncode != 0
    r = cli(*base, "--agent", "codex")  # execution inherits headless
    assert r.returncode != 0
    assert "headless" in r.stderr
    assert task_by_name(state_home, "t1") is None


def test_edit_rejects_headless_with_non_claude(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, agent="codex", execution="herdr")
    r = cli("edit", "t1", "--execution", "headless")
    assert r.returncode != 0
    assert task_by_name(state_home, "t1")["execution"] == "herdr"


def test_permission_mode_warns_under_herdr_for_unsupported_kinds(cli, state_home, cwd_dir):
    r = cli("add", "t1", "--prompt", "p", "--cwd", str(cwd_dir), "--execution", "herdr",
            "--agent", "codex", "--permission-mode", "plan")
    assert r.returncode == 0, r.stderr
    assert "ignored under herdr" in r.stderr
    # claude accepts --permission-mode under herdr, so no warning
    r = cli("add", "t2", "--prompt", "p", "--cwd", str(cwd_dir), "--execution", "herdr", "--permission-mode", "plan")
    assert r.returncode == 0, r.stderr
    assert "ignored" not in r.stderr
    r = cli("add", "t3", "--prompt", "p", "--cwd", str(cwd_dir), "--permission-mode", "plan")
    assert r.returncode == 0, r.stderr
    assert "ignored" not in r.stderr


# --- resolution ---------------------------------------------------------------


def test_resolution_order_in_list_json(cli, state_home, cwd_dir, default_agent_bin):
    add_task(cli, "t1", cwd_dir)
    t = listing_task(cli, "t1")
    assert (t["agent"], t["agent_source"], t["execution"]) == ("claude", "omarchy", "headless")

    cli("settings", "set", "execution", "herdr")
    assert cli("settings", "set", "agent", "gemini").returncode == 0
    t = listing_task(cli, "t1")
    assert (t["agent"], t["agent_source"], t["execution"]) == ("gemini", "settings", "herdr")

    cli("edit", "t1", "--agent", "codex", "--execution", "headless".replace("headless", "herdr"))
    t = listing_task(cli, "t1")
    assert (t["agent"], t["agent_source"]) == ("codex", "task")

    default_agent_bin.write_text("#!/bin/bash\nexit 0\n")
    cli("settings", "set", "agent", "null")
    cli("edit", "t1", "--agent", "none")
    t = listing_task(cli, "t1")
    assert (t["agent"], t["agent_source"]) == (None, "none")


def test_run_fails_when_no_agent_anywhere(cli, state_home, cwd_dir, default_agent_bin):
    default_agent_bin.write_text("#!/bin/bash\nexit 0\n")
    add_task(cli, "t1", cwd_dir, worktree="false")
    r = cli("trigger", "t1")
    assert r.returncode == 1
    assert "no default agent set" in r.stderr
    assert "omarchy default agent" in r.stderr
    run = runs_for(state_home, "t1")[0]
    assert run["status"] == "failure"
    assert run["reason"] == "invalid_config"
    assert run["backend"] == "headless"
    assert "no default agent set" in (state_home / "omaroutines" / "logs" / f"{run['id']}.out").read_text()


def test_run_fails_when_omarchy_default_is_non_claude_under_headless(cli, state_home, cwd_dir, default_agent_bin, calls_dir):
    add_task(cli, "t1", cwd_dir, worktree="false")
    default_agent_bin.write_text("#!/bin/bash\necho codex\n")  # changed after add
    r = cli("trigger", "t1")
    assert r.returncode == 1
    assert "headless" in r.stderr
    run = runs_for(state_home, "t1")[0]
    assert run["status"] == "failure" and run["reason"] == "invalid_config"
    assert not list(calls_dir.glob("*.argv"))  # claude never launched


def test_headless_run_still_succeeds_and_records_backend(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, worktree="false")
    r = cli("trigger", "t1")
    assert r.returncode == 0, r.stderr
    run = runs_for(state_home, "t1")[0]
    assert run["backend"] == "headless"
    assert run["reason"] is None


def test_legacy_task_without_new_keys_still_lists_and_runs(cli, state_home, cwd_dir):
    add_task(cli, "t1", cwd_dir, worktree="false")
    p = state_home / "omaroutines" / "tasks.json"
    d = json.loads(p.read_text())
    for k in ("agent", "execution", "herdr_timeout"):
        d["tasks"][0].pop(k, None)
    p.write_text(json.dumps(d))
    t = listing_task(cli, "t1")
    assert (t["agent"], t["execution"]) == ("claude", "headless")
    assert cli("trigger", "t1").returncode == 0


def test_list_json_exposes_settings_and_installed_kinds(cli, config_home, default_agent_bin):
    r = cli("list", "--json")
    p = json.loads(r.stdout)
    assert p["settings"] == {"execution": "headless", "agent": "claude", "agent_source": "omarchy",
                             "herdr_session": "omaroutines", "path": str(settings_file(config_home))}
    kinds = p["agent_kinds"]
    assert isinstance(kinds, list)
    assert set(kinds) <= {"pi", "omp", "opencode", "claude", "codex", "grok", "gemini", "copilot"}

    cli("settings", "set", "execution", "herdr")
    cli("settings", "set", "agent", "codex")
    s = json.loads(cli("list", "--json").stdout)["settings"]
    assert (s["execution"], s["agent"], s["agent_source"]) == ("herdr", "codex", "settings")
