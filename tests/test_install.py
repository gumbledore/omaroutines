"""`install.sh --uninstall` against a sandboxed HOME and the systemctl stub:
units and symlinks go, state and the herdr session directory stay."""

import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def test_uninstall_removes_units_and_symlinks_keeps_state(tmp_path):
    home = tmp_path / "home"
    units = home / ".config" / "systemd" / "user"
    units.mkdir(parents=True)
    for u in ("oma-schedule-sweep.timer", "oma-schedule-sweep.service", "oma-schedule-herdr.service"):
        (units / u).symlink_to(REPO_ROOT / "systemd" / u)
    (home / ".local" / "bin").mkdir(parents=True)
    (home / ".local" / "bin" / "oma-schedule").symlink_to(REPO_ROOT / "bin" / "oma-schedule")
    state = home / ".local" / "state" / "oma-schedule"
    state.mkdir(parents=True)
    (state / "tasks.json").write_text("{}")
    session = home / ".config" / "herdr" / "sessions" / "oma-schedule"
    session.mkdir(parents=True)
    (session / "session.json").write_text("{}")
    stub = tmp_path / "stub"
    stub.mkdir()
    # never rescan the real shell from a test
    (stub / "omarchy-shell").write_text("#!/bin/bash\nexit 0\n")
    (stub / "omarchy-shell").chmod(0o755)

    env = dict(os.environ, HOME=str(home), PATH=f"{stub}:{os.environ['PATH']}",
               OMA_SCHEDULE_SYSTEMCTL_BIN=str(REPO_ROOT / "tests" / "stubs" / "systemctl"),
               STUB_DIR=str(stub), STUB_LOG=str(stub / "log"))
    env.pop("XDG_CONFIG_HOME", None)
    env.pop("XDG_STATE_HOME", None)
    r = subprocess.run(["/bin/bash", str(REPO_ROOT / "install.sh"), "--uninstall"], capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stderr

    calls = (stub / "log").read_text().splitlines()
    assert "systemctl --user disable --now oma-schedule-sweep.timer" in calls
    assert "systemctl --user disable --now oma-schedule-herdr.service" in calls
    assert not any(units.iterdir())
    assert not (home / ".local" / "bin" / "oma-schedule").exists()
    assert (state / "tasks.json").exists()
    assert (session / "session.json").exists()
    assert "herdr session delete oma-schedule" in r.stdout
