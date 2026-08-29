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
    for u in ("omaroutines-sweep.timer", "omaroutines-sweep.service", "omaroutines-herdr.service"):
        (units / u).symlink_to(REPO_ROOT / "systemd" / u)
    (home / ".local" / "bin").mkdir(parents=True)
    (home / ".local" / "bin" / "omaroutines").symlink_to(REPO_ROOT / "bin" / "omaroutines")
    state = home / ".local" / "state" / "omaroutines"
    state.mkdir(parents=True)
    (state / "tasks.json").write_text("{}")
    session = home / ".config" / "herdr" / "sessions" / "omaroutines"
    session.mkdir(parents=True)
    (session / "session.json").write_text("{}")
    stub = tmp_path / "stub"
    stub.mkdir()
    # never rescan the real shell from a test
    (stub / "omarchy-shell").write_text("#!/bin/bash\nexit 0\n")
    (stub / "omarchy-shell").chmod(0o755)

    env = dict(os.environ, HOME=str(home), PATH=f"{stub}:{os.environ['PATH']}",
               OMAROUTINES_SYSTEMCTL_BIN=str(REPO_ROOT / "tests" / "stubs" / "systemctl"),
               STUB_DIR=str(stub), STUB_LOG=str(stub / "log"))
    env.pop("XDG_CONFIG_HOME", None)
    env.pop("XDG_STATE_HOME", None)
    r = subprocess.run(["/bin/bash", str(REPO_ROOT / "install.sh"), "--uninstall"], capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stderr

    calls = (stub / "log").read_text().splitlines()
    assert "systemctl --user disable --now omaroutines-sweep.timer" in calls
    assert "systemctl --user disable --now omaroutines-herdr.service" in calls
    assert not any(units.iterdir())
    assert not (home / ".local" / "bin" / "omaroutines").exists()
    assert (state / "tasks.json").exists()
    assert (session / "session.json").exists()
    assert "herdr session delete omaroutines" in r.stdout


def _env(tmp_path, home):
    stub = tmp_path / "stub"
    stub.mkdir(exist_ok=True)
    (stub / "omarchy-shell").write_text("#!/bin/bash\nexit 0\n")
    (stub / "omarchy-shell").chmod(0o755)
    env = dict(os.environ, HOME=str(home), PATH=f"{stub}:{os.environ['PATH']}",
               OMAROUTINES_SYSTEMCTL_BIN=str(REPO_ROOT / "tests" / "stubs" / "systemctl"),
               STUB_DIR=str(stub), STUB_LOG=str(stub / "log"))
    env.pop("XDG_CONFIG_HOME", None)
    env.pop("XDG_STATE_HOME", None)
    return env


def test_install_from_marketplace_clone_location(tmp_path):
    """`omarchy plugin add` clones into ~/.config/omarchy/plugins/<id> as a
    real directory; install.sh run from there must not try to replace it."""
    home = tmp_path / "home"
    plugin = home / ".config" / "omarchy" / "plugins" / "gumbledore.omaroutines"
    plugin.mkdir(parents=True)
    subprocess.run(["git", "clone", "-q", str(REPO_ROOT), str(plugin)], check=True, capture_output=True)
    (plugin / "install.sh").write_text((REPO_ROOT / "install.sh").read_text())  # test the working tree, not HEAD
    r = subprocess.run(["/bin/bash", str(plugin / "install.sh")], capture_output=True, text=True, env=_env(tmp_path, home))
    assert r.returncode == 0, r.stderr
    assert plugin.is_dir() and not plugin.is_symlink()
    assert (home / ".local" / "bin" / "omaroutines").resolve() == plugin / "bin" / "omaroutines"
    assert (home / ".config" / "systemd" / "user" / "omaroutines-sweep.timer").is_symlink()


def test_install_from_elsewhere_links_plugin(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    r = subprocess.run(["/bin/bash", str(REPO_ROOT / "install.sh")], capture_output=True, text=True, env=_env(tmp_path, home))
    assert r.returncode == 0, r.stderr
    link = home / ".config" / "omarchy" / "plugins" / "gumbledore.omaroutines"
    assert link.is_symlink() and link.resolve() == REPO_ROOT
