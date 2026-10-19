# Sourced by bin/omaroutines only; not executable.

# --- worktree pruning ----------------------------------------------------------

# The repo's default branch: origin/HEAD if known, else main, else master.
default_branch() {
  local repo="$1" b
  b=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) && {
    echo "$b"
    return 0
  }
  for b in main master; do
    git -C "$repo" rev-parse --verify -q "$b" >/dev/null 2>&1 && {
      echo "$b"
      return 0
    }
  done
  return 1
}

# Merged = ancestor of the default branch, or every commit has a
# patch-equivalent there (squash/rebase merges). Local only; never fetches.
is_merged() {
  local repo="$1" branch="$2" def
  def=$(default_branch "$repo") || return 1
  git -C "$repo" rev-parse --verify -q "$branch" >/dev/null 2>&1 || return 1
  git -C "$repo" merge-base --is-ancestor "$branch" "$def" 2>/dev/null && return 0
  ! git -C "$repo" cherry "$def" "$branch" 2>/dev/null | grep -q '^+'
}

clear_worktree_record() {
  lock
  apply "$RUNS" --argjson id "$1" '
    .runs |= map(if .id == $id then .worktree_path = null | .worktree_branch = null else . end)
  '
  unlock
}

# Remove every kept worktree whose branch is merged (see is_merged); clear the
# record of any worktree already deleted by hand. Unmerged or dirty worktrees
# are left alone. The panel calls this on open. Prints "pruned: <path>" per removal.
cmd_prune() {
  ensure_store
  local id wt_path wt_branch repo
  while IFS=$'\t' read -r id wt_path wt_branch; do
    [[ -z $id ]] && continue
    repo=$(dirname "$(dirname "$wt_path")")
    if [[ ! -d $wt_path ]]; then
      git -C "$repo" worktree prune >/dev/null 2>&1 || true
      [[ $wt_branch != null ]] && git -C "$repo" branch -D "$wt_branch" >/dev/null 2>&1 || true
      clear_worktree_record "$id"
      continue
    fi
    [[ $wt_branch == null ]] && continue
    is_merged "$repo" "$wt_branch" || continue
    # no --force: a worktree with uncommitted changes is refused and kept
    git -C "$repo" worktree remove "$wt_path" >/dev/null 2>&1 || continue
    git -C "$repo" branch -D "$wt_branch" >/dev/null 2>&1 || true
    clear_worktree_record "$id"
    echo "pruned: $wt_path"
  done < <(jq -r '.runs[] | select(.worktree_path != null and .pane_id == null and .status != "running") | [.id, .worktree_path, (.worktree_branch // "null")] | @tsv' "$RUNS")
}

# settings | settings get <key> | settings set <key> <value>
cmd_settings() {
  local verb="${1:-}" key="${2:-}" value="${3:-}"
  case "$verb" in
  "")
    settings_json | jq .
    ;;
  get)
    [[ -n $key ]] || { echo "omaroutines: settings get requires a key" >&2; return 1; }
    settings_json | jq -e --arg k "$key" 'has($k)' >/dev/null || {
      echo "omaroutines: unknown setting \"$key\"" >&2
      return 1
    }
    settings_json | jq -r --arg k "$key" '.[$k]'
    ;;
  set)
    [[ -n $key && $# -ge 3 ]] || { echo "omaroutines: settings set requires <key> <value>" >&2; return 1; }
    local json
    case "$key" in
    execution)
      validate_execution "$value"
      json=$(jq -n --arg v "$value" '$v')
      ;;
    agent)
      if [[ $value == null || $value == none ]]; then
        json=null
      else
        validate_agent "$value"
        json=$(jq -n --arg v "$value" '$v')
      fi
      ;;
    model)
      if [[ $value == null || $value == none ]]; then
        json=null
      else
        validate_model "$value"
        json=$(jq -n --arg v "$value" '$v')
      fi
      ;;
    herdr_session)
      [[ $value =~ ^[A-Za-z0-9._-]+$ ]] || { echo "omaroutines: invalid session name \"$value\"" >&2; return 1; }
      json=$(jq -n --arg v "$value" '$v')
      ;;
    herdr_retain | herdr_timeout_minutes)
      [[ $value =~ ^[1-9][0-9]*$ ]] || { echo "omaroutines: $key must be a whole number >= 1" >&2; return 1; }
      json=$value
      ;;
    notify)
      [[ " all failure needs_input none " == *" $value "* ]] || {
        echo "omaroutines: notify must be one of: all failure needs_input none" >&2
        return 1
      }
      json=$(jq -n --arg v "$value" '$v')
      ;;
    herdr_launch_stagger_seconds)
      [[ $value =~ ^[0-9]+$ ]] || { echo "omaroutines: $key must be a whole number >= 0" >&2; return 1; }
      json=$value
      ;;
    *)
      echo "omaroutines: unknown or read-only setting \"$key\"" >&2
      return 1
      ;;
    esac
    # Combo check at the settings layer: what would a task with no overrides get?
    local merged kind exec_resolved
    merged=$(settings_json | jq -c --arg k "$key" --argjson v "$json" '.[$k] = $v')
    kind=$(jq -r '.agent // empty' <<<"$merged")
    exec_resolved=$(jq -r '.execution' <<<"$merged")
    check_combo "$kind" settings "$exec_resolved"
    lock
    write_settings "$merged"
    unlock
    echo "set: $key"
    ;;
  *)
    echo "omaroutines: settings takes no verb, \"get <key>\" or \"set <key> <value>\"" >&2
    return 1
    ;;
  esac
}
