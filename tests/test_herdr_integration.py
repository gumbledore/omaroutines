"""Opt-in end-to-end check against a real herdr server: the only place
herdr's actual done/idle/blocked classification is exercised.

    OMAROUTINES_HERDR_INTEGRATION=1 uv run pytest tests/test_herdr_integration.py -s

Starts `herdr server` for a throwaway named session, runs one trivial
claude prompt through the real CLI path (systemctl stays stubbed so the
plugin's own unit is never touched), and stops the server. herdr honors
XDG_CONFIG_HOME, so the session lives under a short throwaway config dir
(unix socket paths are length-limited) and nothing touches ~/.config/herdr.
The task cwd is this repo (claude must already trust it).
"""

import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import pytest

from test_exec import add_task, runs_for  # noqa: F401

REPO_ROOT = Path(__file__).resolve().parent.parent

pytestmark = pytest.mark.skipif(
    os.environ.get("OMAROUTINES_HERDR_INTEGRATION") != "1" or shutil.which("herdr") is None,
    reason="set OMAROUTINES_HERDR_INTEGRATION=1 with herdr on PATH",
)


def herdr_env(config_home, session):
    env = {k: v for k, v in os.environ.items() if k not in ("HERDR_SOCKET_PATH", "HERDR_ENV")}
    env["HERDR_SESSION"] = session
    env["XDG_CONFIG_HOME"] = str(config_home)
    return env


def herdr(config_home, session, *args):
    return subprocess.run(["herdr", *args], capture_output=True, text=True, env=herdr_env(config_home, session))


@pytest.fixture
def short_config_home():
    d = Path(tempfile.mkdtemp(prefix="oma-", dir="/tmp"))
    yield d
    shutil.rmtree(d, ignore_errors=True)


@pytest.fixture
def session(short_config_home):
    name = f"omaroutines-test-{os.getpid()}"
    server = subprocess.Popen(["herdr", "server"], env=herdr_env(short_config_home, name),
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        if '"running":true' in herdr(short_config_home, name, "status", "server", "--json").stdout:
            break
        time.sleep(0.2)
    else:
        server.kill()
        pytest.fail("herdr server did not start")
    yield name
    herdr(short_config_home, name, "session", "stop", name)
    try:
        server.wait(timeout=20)
    except subprocess.TimeoutExpired:
        server.kill()


def test_real_claude_prompt_settles_as_success(cli, state_home, short_config_home, session):
    env = {"XDG_CONFIG_HOME": str(short_config_home), "OMAROUTINES_HERDR_BIN": "herdr"}
    assert cli("settings", "set", "execution", "herdr", env_overrides=env).returncode == 0
    assert cli("settings", "set", "herdr_session", session, env_overrides=env).returncode == 0
    r = cli("add", "ping", "--prompt", "Reply with exactly the word PONG and nothing else.",
            "--cwd", str(REPO_ROOT), "--worktree", "false", "--agent", "claude", "--herdr-timeout", "5",
            env_overrides=env)
    assert r.returncode == 0, r.stderr
    r = cli("trigger", "ping", env_overrides=env)
    assert r.returncode == 0, r.stderr + r.stdout
    run = runs_for(state_home, "ping")[0]
    assert run["status"] == "success" and run["backend"] == "herdr" and run["pane_id"]
    log = (state_home / "omaroutines" / "logs" / f"{run['id']}.out").read_text()
    assert "transcript" in log
    assert herdr(short_config_home, session, "agent", "list").stdout.count('"name":"ping-1"') == 1
