"""Shared fixtures for bin/omaroutines tests.

`cli` drives the CLI as a subprocess against an isolated XDG_STATE_HOME (per
docs/design.md's test seam), wired to a fake `claude` binary and a throwaway
CLAUDE_HOME so ticket-03 execution tests don't touch the real Claude Code.
"""

import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
CLI = REPO_ROOT / "bin" / "omaroutines"

# Records argv/pwd per --session-id (avoids collisions between concurrent
# runs of the same task) and echoes a fake `claude -p ... --output-format
# json` result. Honors --resume, FAKE_CLAUDE_TOUCH, FAKE_CLAUDE_EXIT, and
# FAKE_CLAUDE_PROJECTS_DIR (writes the session .jsonl the way claude does).
FAKE_CLAUDE_SCRIPT = """#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "--resume" ]]; then
  echo "RESUMED $2"
  exit 0
fi

sid=""
prev=""
for a in "$@"; do
  [[ "$prev" == "--session-id" ]] && sid="$a"
  prev="$a"
done

calls_dir="${FAKE_CLAUDE_CALLS_DIR:-.}"
mkdir -p "$calls_dir"
printf '%s\\n' "$@" >"$calls_dir/$sid.argv"
pwd >"$calls_dir/$sid.pwd"

[[ -n "${FAKE_CLAUDE_SLEEP:-}" ]] && sleep "$FAKE_CLAUDE_SLEEP"
[[ "${FAKE_CLAUDE_TOUCH:-}" == "1" ]] && touch touched.txt
if [[ -n "${FAKE_CLAUDE_PROJECTS_DIR:-}" ]]; then
  mkdir -p "$FAKE_CLAUDE_PROJECTS_DIR/proj"
  echo '{}' >"$FAKE_CLAUDE_PROJECTS_DIR/proj/$sid.jsonl"
fi

printf '{"type":"result","session_id":"%s","result":"ok"}\\n' "$sid"
exit "${FAKE_CLAUDE_EXIT:-0}"
"""


@pytest.fixture
def state_home(tmp_path):
    return tmp_path / "state"


@pytest.fixture
def cwd_dir(tmp_path):
    """Task --cwd; a git repo since add defaults to worktree=true."""
    d = tmp_path / "work"
    d.mkdir()
    subprocess.run(["git", "init", "-q", str(d)], check=True, capture_output=True)
    return d


@pytest.fixture
def calls_dir(tmp_path):
    d = tmp_path / "calls"
    d.mkdir()
    return d


@pytest.fixture
def fake_claude_bin(tmp_path):
    bin_dir = tmp_path / "fakebin"
    bin_dir.mkdir()
    script = bin_dir / "claude"
    script.write_text(FAKE_CLAUDE_SCRIPT)
    script.chmod(0o755)
    return script


@pytest.fixture
def claude_home(tmp_path):
    d = tmp_path / "claude-home"
    (d / "projects").mkdir(parents=True)
    return d


@pytest.fixture
def git_repo(tmp_path):
    """A throwaway git repo usable as a task's --cwd for worktree tests."""
    d = tmp_path / "repo"
    d.mkdir()
    run = lambda *args: subprocess.run(  # noqa: E731
        ["git", "-C", str(d), *args], check=True, capture_output=True, text=True
    )
    subprocess.run(["git", "init", "-q", "-b", "main", str(d)], check=True, capture_output=True)
    run("config", "user.email", "test@example.com")
    run("config", "user.name", "Test")
    (d / "README.md").write_text("hi\n")
    run("add", ".")
    run("commit", "-q", "-m", "init")
    return d


# Appends its full argv (one arg per line, call separated by "---") to
# $FAKE_NOTIFY_LOG so tests can assert on notification content.
FAKE_NOTIFY_SCRIPT = """#!/bin/bash
{ printf '%s\\n' "$@"; echo "---"; } >>"${FAKE_NOTIFY_LOG:?}"
"""


@pytest.fixture
def notify_log(tmp_path):
    return tmp_path / "notify.log"


@pytest.fixture
def fake_notify_bin(tmp_path):
    bin_dir = tmp_path / "fakebin"
    bin_dir.mkdir(exist_ok=True)
    script = bin_dir / "fake-notify"
    script.write_text(FAKE_NOTIFY_SCRIPT)
    script.chmod(0o755)
    return script


@pytest.fixture
def config_home(tmp_path):
    return tmp_path / "config"


@pytest.fixture
def default_agent_bin(tmp_path):
    """Fake `omarchy-default-agent`; prints `claude` unless a test rewrites it."""
    bin_dir = tmp_path / "fakebin"
    bin_dir.mkdir(exist_ok=True)
    script = bin_dir / "omarchy-default-agent"
    script.write_text("#!/bin/bash\necho claude\n")
    script.chmod(0o755)
    return script


@pytest.fixture
def stub_dir(tmp_path):
    """State + control files for tests/stubs/herdr and tests/stubs/systemctl;
    `log` is the invocation log both stubs append to."""
    d = tmp_path / "herdr-stub"
    d.mkdir()
    return d


@pytest.fixture
def cli(state_home, config_home, calls_dir, fake_claude_bin, claude_home, notify_log, fake_notify_bin, default_agent_bin, stub_dir):
    def run(*args, env_overrides=None):
        env = dict(os.environ)
        env["XDG_STATE_HOME"] = str(state_home)
        env["XDG_CONFIG_HOME"] = str(config_home)
        env["OMAROUTINES_DEFAULT_AGENT_BIN"] = str(default_agent_bin)
        env["OMAROUTINES_HERDR_BIN"] = str(REPO_ROOT / "tests" / "stubs" / "herdr")
        env["OMAROUTINES_SYSTEMCTL_BIN"] = str(REPO_ROOT / "tests" / "stubs" / "systemctl")
        env["STUB_DIR"] = str(stub_dir)
        env["STUB_LOG"] = str(stub_dir / "log")
        for k in ("HERDR_SESSION", "HERDR_SOCKET_PATH", "HERDR_ENV"):
            env.pop(k, None)
        env["TZ"] = "UTC"
        env["OMAROUTINES_CLAUDE_BIN"] = str(fake_claude_bin)
        env["OMAROUTINES_CLAUDE_HOME"] = str(claude_home)
        env["OMAROUTINES_NOTIFY_BIN"] = str(fake_notify_bin)
        env["FAKE_CLAUDE_CALLS_DIR"] = str(calls_dir)
        env["FAKE_NOTIFY_LOG"] = str(notify_log)
        env.pop("OMAROUTINES_NOW", None)
        if env_overrides:
            env.update(env_overrides)
        return subprocess.run(
            [str(CLI), *args],
            capture_output=True,
            text=True,
            env=env,
        )

    return run
