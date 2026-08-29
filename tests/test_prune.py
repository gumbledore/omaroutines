"""`omaroutines prune`: remove worktrees whose branch is merged into the
default branch (ancestor or squash-equivalent), clear their run records, and
never touch unmerged ones. Worktrees are produced by real runs (fake claude
with FAKE_CLAUDE_TOUCH=1), never hand-built.
"""

import json
import subprocess
from pathlib import Path

from test_exec import add_task, git, runs_for


def run_with_changes(cli, git_repo, name="t1"):
    r = cli("trigger", name, env_overrides={"FAKE_CLAUDE_TOUCH": "1"})
    assert r.returncode == 0, r.stderr
    run = runs_for_last(cli, name)
    assert run["worktree_path"] and Path(run["worktree_path"]).is_dir()
    git(Path(run["worktree_path"]), "add", "-A")
    git(Path(run["worktree_path"]), "commit", "-q", "-m", f"run {run['id']}")
    return run


def runs_for_last(cli, name):
    r = cli("log", name, "--json")
    return json.loads(r.stdout)[0]


def run_by_id(cli, name, run_id):
    r = cli("log", name, "--json")
    return next(x for x in json.loads(r.stdout) if x["id"] == run_id)


def branches(repo):
    return git(repo, "branch", "--list", "omaroutines/*").stdout.split()


def test_prune_removes_fast_forward_merged_worktree(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    run = run_with_changes(cli, git_repo)
    git(git_repo, "merge", "-q", "--ff-only", run["worktree_branch"])

    r = cli("prune")
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == f"pruned: {run['worktree_path']}"
    assert not Path(run["worktree_path"]).exists()
    assert branches(git_repo) == []
    after = run_by_id(cli, "t1", run["id"])
    assert after["worktree_path"] is None and after["worktree_branch"] is None


def test_prune_removes_squash_merged_worktree(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    run = run_with_changes(cli, git_repo)
    git(git_repo, "merge", "-q", "--squash", run["worktree_branch"])
    git(git_repo, "commit", "-q", "-m", "squash")
    # not an ancestor, but every patch is on main
    assert subprocess.run(["git", "-C", str(git_repo), "merge-base", "--is-ancestor",
                           run["worktree_branch"], "main"]).returncode != 0

    r = cli("prune")
    assert r.returncode == 0, r.stderr
    assert f"pruned: {run['worktree_path']}" in r.stdout
    assert not Path(run["worktree_path"]).exists()
    assert branches(git_repo) == []


def test_prune_leaves_unmerged_worktree(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    run = run_with_changes(cli, git_repo)

    r = cli("prune")
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == ""
    assert Path(run["worktree_path"]).is_dir()
    assert run["worktree_branch"].split("/", 1)[1] in " ".join(branches(git_repo))
    assert run_by_id(cli, "t1", run["id"])["worktree_path"] == run["worktree_path"]


def test_prune_leaves_merged_but_dirty_worktree(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    run = run_with_changes(cli, git_repo)
    git(git_repo, "merge", "-q", "--ff-only", run["worktree_branch"])
    (Path(run["worktree_path"]) / "scratch.txt").write_text("unsaved\n")

    r = cli("prune")
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == ""
    assert Path(run["worktree_path"]).is_dir()


def test_prune_clears_record_when_directory_deleted_by_hand(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    run = run_with_changes(cli, git_repo)
    subprocess.run(["rm", "-rf", run["worktree_path"]], check=True)

    r = cli("prune")
    assert r.returncode == 0, r.stderr
    after = run_by_id(cli, "t1", run["id"])
    assert after["worktree_path"] is None and after["worktree_branch"] is None
    assert branches(git_repo) == []


def test_prune_handles_removed_task(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    run = run_with_changes(cli, git_repo)
    git(git_repo, "merge", "-q", "--ff-only", run["worktree_branch"])
    cli("rm", "t1")

    r = cli("prune")
    assert r.returncode == 0, r.stderr
    assert not Path(run["worktree_path"]).exists()


def test_retention_keeps_runs_with_worktrees(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    kept = run_with_changes(cli, git_repo)
    for _ in range(22):
        assert cli("trigger", "t1").returncode == 0
    ids = [r["id"] for r in runs_for(state_home, "t1")]
    assert kept["id"] in ids
    assert len(ids) == 21  # newest 20 + the kept one

    git(git_repo, "merge", "-q", "--ff-only", kept["worktree_branch"])
    cli("prune")
    cli("trigger", "t1")
    assert kept["id"] not in [r["id"] for r in runs_for(state_home, "t1")]


def test_list_json_counts_worktrees_per_task(cli, state_home, git_repo):
    add_task(cli, "t1", git_repo)
    run_with_changes(cli, git_repo)
    run_with_changes(cli, git_repo)
    cli("trigger", "t1")
    p = json.loads(cli("list", "--json").stdout)
    assert p["tasks"][0]["worktrees"] == 2
