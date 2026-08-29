"""Headless QML smoke test: `quickshell -p tests/qml/Harness.qml` offscreen
with a fake HOME whose ~/.local/bin/oma-schedule echoes a canned
`list --json`. Proves the widget parses the contract and every panel file
compiles; it does not test layout or clicks. Skips without quickshell.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SHELL_DIR = Path("/usr/share/omarchy/shell")

PAYLOAD = {
    "count": 3,
    "tasks": [
        {"name": "watch", "prompt": "watch", "cwd": "/tmp", "schedule": "manual",
         "permission_mode": None, "worktree": False, "enabled": True, "next_due": None,
         "backlog_since": None, "created": 1756400000, "next_due_text": "-",
         "agent": "codex", "agent_source": "settings", "execution": "herdr",
         "last_run": {"id": 5, "status": "failure", "trigger": "manual", "start": 1756700000,
                      "end": 1756700100, "session_available": False, "backend": "herdr", "reason": "blocked",
                      "pane_id": "w1:p2", "pane_available": False}},
        {"name": "lint", "prompt": "lint", "cwd": "/tmp", "schedule": "Mon *-*-* 09:00:00",
         "permission_mode": None, "worktree": True, "enabled": True, "next_due": 1756716400,
         "backlog_since": None, "created": 1756400000, "next_due_text": "Mon 1 Sep 09:00",
         "agent": "claude", "agent_source": "omarchy", "execution": "headless",
         "last_run": {"id": 3, "status": "failure", "trigger": "scheduled", "start": 1756700000,
                      "end": 1756700100, "session_available": True, "backend": "headless", "reason": None,
                      "pane_id": None, "pane_available": False}},
        {"name": "manual-one", "prompt": "x", "cwd": "/tmp", "schedule": "manual",
         "permission_mode": None, "worktree": False, "enabled": False, "next_due": None,
         "backlog_since": None, "created": 1756400000, "next_due_text": "-",
         "agent": "codex", "agent_source": "task", "execution": "herdr", "last_run": None},
    ],
    "enabled": 2, "failed": 2, "running": 0, "backlog": 0, "badge": 2, "active": True,
    "next": {"task": "lint", "next_due": 1756716400, "next_due_text": "Mon 1 Sep 09:00"},
    "tooltip": "Next: lint Mon 1 Sep 09:00 · 2 failed",
}


def run_harness(tmp_path, plugin_dir, payload=PAYLOAD):
    if shutil.which("quickshell") is None or not SHELL_DIR.is_dir():
        pytest.skip("quickshell / omarchy shell not installed")
    home = tmp_path / "home"
    bin_dir = home / ".local" / "bin"
    bin_dir.mkdir(parents=True)
    fake = bin_dir / "oma-schedule"
    fake.write_text("#!/bin/bash\n[[ $1 == list ]] && printf '%s\\n' " + repr(json.dumps(payload)) + "\nexit 0\n")
    fake.chmod(0o755)

    # `qs.*` resolves against the config root, so the harness runs from a dir
    # holding the shell's Commons/Ui.
    config = tmp_path / "config"
    config.mkdir()
    for d in ("Commons", "Ui"):
        (config / d).symlink_to(SHELL_DIR / d)
    shutil.copy(REPO_ROOT / "tests" / "qml" / "Harness.qml", config / "Harness.qml")

    env = dict(os.environ)
    env.update({
        "HOME": str(home),
        "XDG_STATE_HOME": str(home / ".local" / "state"),
        "QT_QPA_PLATFORM": "offscreen",
        "OMA_SCHEDULE_PLUGIN_DIR": str(plugin_dir),
    })
    env.pop("WAYLAND_DISPLAY", None)
    r = subprocess.run(
        ["quickshell", "--no-color", "-p", str(config / "Harness.qml")],
        capture_output=True, text=True, env=env, timeout=60,
    )
    return r


def test_widget_parses_contract_and_panel_compiles(tmp_path):
    r = run_harness(tmp_path, REPO_ROOT)
    out = r.stdout + r.stderr
    assert "SMOKE PASS" in out, out
    assert "TASKS 3" in out
    assert "TOOLTIP Next: lint Mon 1 Sep 09:00" in out and "2 failed" in out  # console.log escapes "·"
    assert "BADGE 2" in out
    # Attach/Resume contract, instantiated against the payload (not just compiled)
    assert "TASKROW watch herdr=true blocked=true canResume=false tip=Pane no longer available" in out
    assert "RUNROW watch herdr=true blocked=true canResume=false" in out
    assert "TASKROW lint herdr=false blocked=false canResume=true tip=Resume run #3 in a terminal" in out
    assert "RUNROW lint herdr=false blocked=false canResume=true" in out
    assert "TASKROW manual-one herdr=false blocked=false canResume=false tip=No run yet" in out
    assert r.returncode == 0


def test_qml_syntax_error_fails(tmp_path):
    broken = tmp_path / "plugin"
    shutil.copytree(REPO_ROOT, broken, ignore=shutil.ignore_patterns(".git", ".venv", "tests", ".scratch", ".worktrees"))
    p = broken / "panel" / "TaskRow.qml"
    p.write_text(p.read_text() + "\nthis is not qml {{{\n")
    r = run_harness(tmp_path, broken)
    out = r.stdout + r.stderr
    assert "SMOKE PASS" not in out
    assert "COMPILE ERROR panel/TaskRow.qml" in out or "ROW ERROR TaskRow" in out
    assert r.returncode != 0
