# Sourced by bin/omaroutines only; not executable.

# --- commands ------------------------------------------------------------------

# Shared by add/edit: enum/type checks on the new fields, then the combo
# check against what the task would resolve to right now. Warns when a
# permission mode is set on a task that resolves to a herdr agent kind
# whose unattended flags cannot carry it (ignored there).
validate_agent_fields() {
  local agent="$1" execution="$2" herdr_timeout="$3" perm_mode="$4" settings="${5:-}" model="${6:-}"
  [[ -z $agent ]] || validate_agent "$agent"
  [[ -z $execution ]] || validate_execution "$execution"
  [[ -z $herdr_timeout || $herdr_timeout =~ ^[0-9]+$ ]] || {
    echo "omaroutines: --herdr-timeout must be a whole number of minutes" >&2
    return 1
  }
  local kind source exec_resolved
  IFS='|' read -r kind source < <(resolve_agent "$agent")
  exec_resolved=$(resolve_execution "$execution")
  check_combo "$kind" "$source" "$exec_resolved"
  [[ -n $perm_mode && $exec_resolved == herdr ]] && ! perm_override_kind "$kind" &&
    echo "omaroutines: warning: permission mode is ignored under herdr for agent \"${kind:-unset}\"" >&2
  [[ -n $settings && $exec_resolved == herdr && $kind != claude ]] &&
    echo "omaroutines: warning: settings is ignored under herdr for agent \"${kind:-unset}\"" >&2
  [[ -n $model && $exec_resolved == herdr ]] && ! model_flag_kind "$kind" &&
    echo "omaroutines: warning: model is ignored under herdr for agent \"${kind:-unset}\" (no --model flag)" >&2
  return 0
}

# worktree=true needs a git repo to run `git worktree add` in.
require_git_repo() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "omaroutines: --cwd \"$1\" is not a git repository (required when --worktree true)" >&2
    return 1
  }
}

cmd_add() {
  local name="${1:-}"
  shift || true
  [[ -z $name ]] && {
    echo "omaroutines: add requires a task name" >&2
    return 1
  }
  validate_name "$name"

  local prompt="" cwd="" schedule="manual" perm_mode="" worktree="true" agent="" execution="" herdr_timeout="" settings="" model=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --prompt)
      prompt="$2"
      shift 2
      ;;
    --model)
      model="$2"
      shift 2
      ;;
    --settings)
      settings="$2"
      shift 2
      ;;
    --cwd)
      cwd="$2"
      shift 2
      ;;
    --schedule)
      schedule="$2"
      shift 2
      ;;
    --permission-mode)
      perm_mode="$2"
      shift 2
      ;;
    --worktree)
      worktree="$2"
      shift 2
      ;;
    --agent)
      agent="$2"
      shift 2
      ;;
    --execution)
      execution="$2"
      shift 2
      ;;
    --herdr-timeout)
      herdr_timeout="$2"
      shift 2
      ;;
    *)
      echo "omaroutines: unknown option \"$1\"" >&2
      return 1
      ;;
    esac
  done

  [[ -z $prompt ]] && {
    echo "omaroutines: --prompt is required" >&2
    return 1
  }
  [[ -z $cwd ]] && {
    echo "omaroutines: --cwd is required" >&2
    return 1
  }
  cwd=$(realpath -m "$cwd")
  [[ -d $cwd ]] || {
    echo "omaroutines: --cwd \"$cwd\" is not a directory" >&2
    return 1
  }
  [[ $worktree == true ]] && { require_git_repo "$cwd" || return 1; }

  ensure_store
  if task_exists "$name"; then
    echo "omaroutines: task \"$name\" already exists" >&2
    return 1
  fi

  local normalized next_due=null
  normalized=$(normalize_schedule "$schedule") || {
    echo "omaroutines: invalid schedule \"$schedule\"" >&2
    return 1
  }
  if [[ $normalized != manual ]]; then
    next_due=$(compute_next_due "$normalized") || {
      echo "omaroutines: could not compute next occurrence for \"$schedule\"" >&2
      return 1
    }
  fi
  [[ -z $perm_mode ]] || validate_perm_mode "$perm_mode"
  [[ -z $settings ]] || validate_settings "$settings"
  [[ -z $model ]] || validate_model "$model"
  validate_agent_fields "$agent" "$execution" "$herdr_timeout" "$perm_mode" "$settings" "$model"

  lock
  apply "$TASKS" \
    --arg name "$name" --arg prompt "$prompt" --arg cwd "$cwd" \
    --arg schedule "$normalized" --arg perm "$perm_mode" --arg settings "$settings" --arg model "$model" \
    --argjson worktree "$([[ $worktree == true ]] && echo true || echo false)" \
    --argjson next_due "${next_due:-null}" --argjson now "$(now)" \
    --arg agent "$agent" --arg execution "$execution" --argjson herdr_timeout "${herdr_timeout:-null}" '
    .tasks += [{
      name: $name, prompt: $prompt, cwd: $cwd, schedule: $schedule,
      permission_mode: (if $perm == "" then null else $perm end), worktree: $worktree, enabled: true,
      next_due: $next_due, backlog_since: null, created: $now,
      agent: (if $agent == "" then null else $agent end),
      execution: (if $execution == "" then null else $execution end),
      herdr_timeout: $herdr_timeout,
      settings: (if $settings == "" then null else $settings end),
      model: (if $model == "" then null else $model end)
    }]
  '
  echo "added: $name"
}

cmd_edit() {
  local name="${1:-}"
  shift || true
  [[ -z $name ]] && {
    echo "omaroutines: edit requires a task name" >&2
    return 1
  }
  ensure_store
  require_task "$name"

  local set_prompt=0 set_cwd=0 set_schedule=0 set_perm=0 set_worktree=0
  local set_agent=0 set_execution=0 set_timeout=0 set_settings=0 set_model=0
  local prompt="" cwd="" schedule="" perm_mode="" worktree="" agent="" execution="" herdr_timeout="" settings="" model=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --prompt)
      prompt="$2"
      set_prompt=1
      shift 2
      ;;
    --model)
      model="$2"
      set_model=1
      shift 2
      ;;
    --settings)
      settings="$2"
      set_settings=1
      shift 2
      ;;
    --agent)
      agent="$2"
      set_agent=1
      shift 2
      ;;
    --execution)
      execution="$2"
      set_execution=1
      shift 2
      ;;
    --herdr-timeout)
      herdr_timeout="$2"
      set_timeout=1
      shift 2
      ;;
    --cwd)
      cwd="$2"
      set_cwd=1
      shift 2
      ;;
    --schedule)
      schedule="$2"
      set_schedule=1
      shift 2
      ;;
    --permission-mode)
      perm_mode="$2"
      set_perm=1
      shift 2
      ;;
    --worktree)
      worktree="$2"
      set_worktree=1
      shift 2
      ;;
    *)
      echo "omaroutines: unknown option \"$1\"" >&2
      return 1
      ;;
    esac
  done

  if ((set_cwd)); then
    cwd=$(realpath -m "$cwd")
    [[ -d $cwd ]] || {
      echo "omaroutines: --cwd \"$cwd\" is not a directory" >&2
      return 1
    }
  fi
  if ((set_cwd || set_worktree)); then
    local eff_cwd eff_wt
    eff_cwd=$(jq -r --arg n "$name" '.tasks[] | select(.name == $n) | .cwd' "$TASKS")
    eff_wt=$(jq -r --arg n "$name" '.tasks[] | select(.name == $n) | .worktree' "$TASKS")
    ((set_cwd)) && eff_cwd="$cwd"
    ((set_worktree)) && eff_wt="$worktree"
    [[ $eff_wt == true ]] && { require_git_repo "$eff_cwd" || return 1; }
  fi

  local normalized="" next_due_json="null" have_next_due=0
  if ((set_schedule)); then
    normalized=$(normalize_schedule "$schedule") || {
      echo "omaroutines: invalid schedule \"$schedule\"" >&2
      return 1
    }
    if [[ $normalized != manual ]]; then
      next_due_json=$(compute_next_due "$normalized") || {
        echo "omaroutines: could not compute next occurrence for \"$schedule\"" >&2
        return 1
      }
    fi
    have_next_due=1
  fi

  [[ $perm_mode == none ]] && perm_mode=""
  [[ -z $perm_mode ]] || validate_perm_mode "$perm_mode"
  [[ $settings == none ]] && settings=""
  [[ -z $settings ]] || validate_settings "$settings"
  [[ $model == none ]] && model=""
  [[ -z $model ]] || validate_model "$model"
  [[ $agent == none ]] && agent=""
  [[ $execution == none ]] && execution=""
  [[ $herdr_timeout == none ]] && herdr_timeout=""
  # Combo check on the task as it will be after this edit.
  local cur eff_agent eff_exec eff_perm eff_settings eff_model
  cur=$(jq -c --arg n "$name" '.tasks[] | select(.name == $n)' "$TASKS")
  eff_agent=$(jq -r '.agent // empty' <<<"$cur")
  eff_exec=$(jq -r '.execution // empty' <<<"$cur")
  eff_perm=$(jq -r '.permission_mode // empty' <<<"$cur")
  eff_settings=$(jq -r '.settings // empty' <<<"$cur")
  eff_model=$(jq -r '.model // empty' <<<"$cur")
  ((set_agent)) && eff_agent="$agent"
  ((set_execution)) && eff_exec="$execution"
  ((set_perm)) && eff_perm="$perm_mode"
  ((set_settings)) && eff_settings="$settings"
  ((set_model)) && eff_model="$model"
  validate_agent_fields "$eff_agent" "$eff_exec" "$herdr_timeout" "$eff_perm" "$eff_settings" "$eff_model"

  lock
  apply "$TASKS" \
    --arg name "$name" \
    --argjson set_agent "$set_agent" --arg agent "$agent" \
    --argjson set_execution "$set_execution" --arg execution "$execution" \
    --argjson set_timeout "$set_timeout" --argjson herdr_timeout "${herdr_timeout:-null}" \
    --argjson set_prompt "$set_prompt" --arg prompt "$prompt" \
    --argjson set_cwd "$set_cwd" --arg cwd "$cwd" \
    --argjson set_schedule "$set_schedule" --arg schedule "$normalized" \
    --argjson have_next_due "$have_next_due" --argjson next_due "$next_due_json" \
    --argjson set_perm "$set_perm" --arg perm "$perm_mode" \
    --argjson set_settings "$set_settings" --arg settings "$settings" \
    --argjson set_model "$set_model" --arg model "$model" \
    --argjson set_worktree "$set_worktree" \
    --argjson worktree "$([[ $worktree == true ]] && echo true || echo false)" '
    .tasks |= map(if .name == $name then
        (if $set_prompt == 1 then .prompt = $prompt else . end)
      | (if $set_cwd == 1 then .cwd = $cwd else . end)
      | (if $set_schedule == 1 then .schedule = $schedule | .next_due = $next_due | .backlog_since = null else . end)
      | (if $set_perm == 1 then .permission_mode = (if $perm == "" then null else $perm end) else . end)
      | (if $set_worktree == 1 then .worktree = $worktree else . end)
      | (if $set_agent == 1 then .agent = (if $agent == "" then null else $agent end) else . end)
      | (if $set_execution == 1 then .execution = (if $execution == "" then null else $execution end) else . end)
      | (if $set_timeout == 1 then .herdr_timeout = $herdr_timeout else . end)
      | (if $set_settings == 1 then .settings = (if $settings == "" then null else $settings end) else . end)
      | (if $set_model == 1 then .model = (if $model == "" then null else $model end) else . end)
      else . end)
  '
  echo "edited: $name"
}

cmd_list() {
  ensure_store
  if [[ ${1:-} == --json ]]; then
    # jq's strftime is UTC-only; build a local-time text map in bash so
    # --json and the human table agree. tasks.json is read once: the widget
    # polls on file change, i.e. while the CLI may be rewriting next_due.
    local tasks_json text_map="{}" d
    tasks_json=$(cat "$TASKS")
    for d in $(jq -r '[.tasks[].next_due // empty] | unique | .[]' <<<"$tasks_json"); do
      text_map=$(jq -c --argjson d "$d" --arg t "$(when_text "$d")" '. + {($d|tostring): $t}' <<<"$text_map")
    done
    # Bar-widget summary (spec: .scratch/omaroutines-bar-widget/spec.md).
    # last_run = newest run per task; disabled tasks still count as
    # failed/running but never as backlog/next.
    # Agent resolution is done once here (settings + omarchy default) and
    # applied per task in jq; the omarchy default is a subprocess.
    local s_agent s_exec o_agent s_session kinds s_model
    s_agent=$(setting agent)
    s_model=$(setting model)
    s_exec=$(setting execution)
    s_session=$(setting herdr_session)
    o_agent=$("$DEFAULT_AGENT_BIN" 2>/dev/null) || o_agent=""
    kinds=$(installed_agent_kinds_json)
    jq -c --argjson map "$text_map" --slurpfile runs "$RUNS" --argjson avail "$(available_sessions_json)" \
      --argjson panes "$(live_panes_json)" --argjson kinds "$kinds" \
      --arg s_agent "$s_agent" --arg s_exec "$s_exec" --arg o_agent "$o_agent" --arg s_model "$s_model" \
      --argjson models "$(printf '%s\n' $MODEL_CHOICES | jq -R . | jq -sc .)" \
      --arg s_session "$s_session" --arg s_path "$SETTINGS" '
      (.tasks | map(.name)) as $names
      | ($runs[0].runs | group_by(.task) | map(max_by(.id)) | map(select(.trigger == "missed" and .missed_seen != true and (.task as $t | $names | index($t)) != null)) | length) as $missed_runs
      # skipped (backlog timeout) runs never become last_run: they must not hide a failure
      | ($runs[0].runs | map(select(.status != "skipped")) | group_by(.task) | map({key: .[0].task, value: (max_by(.id) | {id, status, trigger, start, end, backend: (.backend // "headless"), reason: (.reason // null), dismissed: (.dismissed // false), pane_id: (.pane_id // null), session_available: (.session_id as $s | $avail | index($s) != null), pane_available: (.pane_id as $p | $p != null and ($panes | index($p)) != null)})}) | from_entries) as $last
      | ($runs[0].runs | map(select(.worktree_path != null)) | group_by(.task) | map({key: .[0].task, value: length}) | from_entries) as $wts
      | (.tasks | map(
          (.agent // (if $s_agent != "" then $s_agent elif $o_agent != "" then $o_agent else null end)) as $ra
          | . + {
          agent: $ra,
          agent_source: (if .agent != null then "task" elif $s_agent != "" then "settings" elif $o_agent != "" then "omarchy" else "none" end),
          execution: (.execution // $s_exec),
          model: (.model // (if $s_model != "" and $ra == "claude" then $s_model else null end)),
          model_source: (if .model != null then "task" elif $s_model != "" and $ra == "claude" then "settings" else "none" end),
          next_due_text: (if .next_due == null then "-" else $map[(.next_due|tostring)] end),
          last_run: ($last[.name] // null),
          worktrees: ($wts[.name] // 0)
        })) as $tasks
      | ($tasks | map(select(.enabled and .next_due != null)) | min_by(.next_due)) as $n
      | {
          count: ($tasks | length),
          tasks: $tasks,
          enabled: ($tasks | map(select(.enabled)) | length),
          failed: ($tasks | map(select(.last_run.status == "failure" and .last_run.dismissed != true)) | length),
          running: ($tasks | map(select(.last_run.status == "running")) | length),
          needs_input: ($tasks | map(select(.last_run.status == "needs_input" and .last_run.dismissed != true)) | length),
          backlog: ($tasks | map(select(.enabled and .backlog_since != null)) | length),
          next: (if $n == null then null else {task: $n.name, next_due: $n.next_due, next_due_text: $n.next_due_text} end)
        }
      | .settings = {
          execution: $s_exec,
          agent: (if $s_agent != "" then $s_agent elif $o_agent != "" then $o_agent else null end),
          agent_source: (if $s_agent != "" then "settings" elif $o_agent != "" then "omarchy" else "none" end),
          model: (if $s_model != "" then $s_model else null end),
          herdr_session: $s_session, path: $s_path
        }
      | .agent_kinds = $kinds
      | .model_choices = $models
      | .missed = $missed_runs + .backlog
      | .badge = .failed + .needs_input
      | .active = (.badge > 0)
      | .tooltip = (
          if .enabled == 0 then "No enabled tasks"
          else (if .next == null then "Next: none" else "Next: \(.next.task) \(.next.next_due_text)" end)
            + (if .failed > 0 then " · \(.failed) failed" else "" end)
            + (if .needs_input > 0 then " · \(.needs_input) need input" else "" end)
            + (if .running > 0 then " · \(.running) running" else "" end)
            + (if .backlog > 0 then " · \(.backlog) backlog" else "" end)
          end)
    ' <<<"$tasks_json"
    return
  fi

  local any=0
  while IFS=$'\t' read -r name schedule enabled next_due; do
    any=1
    local due_text="-"
    [[ $next_due != null ]] && due_text=$(when_text "$next_due")
    local state="on"
    [[ $enabled == false ]] && state="off (disabled)"
    printf '  %-20s %-24s %-8s %s\n' "$name" "$schedule" "$state" "$due_text"
  done < <(jq -r '.tasks[] | [.name, .schedule, .enabled, (.next_due // "null")] | @tsv' "$TASKS")

  ((any)) || echo "  no scheduled tasks"
}

cmd_rm() {
  local name="${1:-}"
  [[ -z $name ]] && {
    echo "omaroutines: rm requires a task name" >&2
    return 1
  }
  ensure_store
  require_task "$name"
  lock
  apply "$TASKS" --arg name "$name" '.tasks |= map(select(.name != $name))'
  echo "removed: $name"
}

cmd_set_enabled() {
  local name="${1:-}" value="$2"
  [[ -z $name ]] && {
    echo "omaroutines: task name required" >&2
    return 1
  }
  ensure_store
  require_task "$name"
  lock
  apply "$TASKS" --arg name "$name" --argjson value "$value" '
    .tasks |= map(if .name == $name then .enabled = $value else . end)
  '
}

cmd_enable() {
  cmd_set_enabled "${1:-}" true
  echo "enabled: ${1:-}"
}

cmd_disable() {
  cmd_set_enabled "${1:-}" false
  echo "disabled: ${1:-}"
}


cmd_show_overlay() { omarchy-shell shell summon gumbledore.omaroutines "{}" >/dev/null 2>&1 || true; }
