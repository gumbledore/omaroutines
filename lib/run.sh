# Sourced by bin/omaroutines only; not executable.

# --- execution (ticket 03) ----------------------------------------------------

# Finalize a run-log entry (under lock) by merging a JSON patch of fields and
# setting `end`, then prune that task's runs to the newest RETAIN_RUNS; runs
# that still hold a worktree or a live herdr pane are exempt so `prune` /
# `attach` can find them later. Log files follow runs.json: any logs/<id>.out
# with no matching run is removed.
finalize_run() {
  local run_id="$1" task="$2" patch="$3"
  local end
  FINALIZING=1 # tells run_task's kill trap the normal path owns the entry
  end=$(now)
  lock
  apply "$RUNS" --argjson id "$run_id" --argjson end "$end" --argjson patch "$patch" '
    .runs |= map(if .id == $id then . + $patch + {end: $end} else . end)'
  retain_runs "$task"
  unlock
  notify_run "$run_id" || true
}

# Desktop notification when an unattended run fails or waits on input
# (setting `notify`: all | failure | needs_input | none). Manual triggers
# are watched, so never notified. Click attaches / resumes the run.
notify_run() {
  local run_id="$1" task trig status pane sid want
  IFS=$'\t' read -r task trig status pane sid < <(jq -r --argjson id "$run_id" '
    .runs[] | select(.id == $id) | [.task, .trigger, .status, (.pane_id // ""), (.session_id // "")] | @tsv' "$RUNS")
  [[ $trig != manual && ($status == failure || $status == needs_input) ]] || return 0
  want=$(setting notify)
  [[ $want == all || $want == "$status" ]] || return 0
  local -a action=(omaroutines show-overlay)
  if [[ -n $pane ]]; then
    action=(omaroutines attach "$run_id" --terminal)
  elif [[ -n $sid ]]; then
    action=(omaroutines resume "$run_id" --terminal)
  fi
  if [[ $status == needs_input ]]; then
    "$NOTIFY_BIN" -g "$GLYPH" -u critical "Omaroutines: $task needs input" \
      "Run #$run_id is waiting on a prompt. Click to attach." --exec "${action[@]}" >/dev/null 2>&1
  else
    "$NOTIFY_BIN" -g "$GLYPH" -u normal "Omaroutines: $task failed" \
      "Run #$run_id ($trig) failed. Click to open it." --exec "${action[@]}" >/dev/null 2>&1
  fi
}

# Trim a task's runs to the newest RETAIN_RUNS (kept-worktree / live-pane
# runs are extra) and drop log files of runs no longer listed. Caller holds
# the lock.
retain_runs() {
  local task="$1"
  apply "$RUNS" --arg task "$task" --argjson retain "$RETAIN_RUNS" '
    .runs |= (
        (map(select(.task != $task))) as $others
      | (map(select(.task == $task and (.worktree_path != null or .pane_id != null)))) as $kept
      | (map(select(.task == $task and .worktree_path == null and .pane_id == null)) | sort_by(.id) | .[-$retain:]) as $mine
      | ($others + $kept + $mine) | sort_by(.id)
    )
  '
  local live f
  live=$(jq -r '.runs[].id' "$RUNS")
  for f in "$STATE_DIR/logs"/*.out; do
    [[ -f $f ]] || continue
    grep -qx "$(basename "$f" .out)" <<<"$live" || rm -f "$f"
  done
}

# Run a task end to end: worktree, claude -p invocation, worktree cleanup,
# run-log entry. Shared by trigger / sweep / backlog run (trigger arg is
# manual | scheduled | missed | backlog-catchup). Prints "<run-id> <status>" on stdout
# and returns 0 on success, 1 on failure -- callers that care parse that line;
# Claude's own output never reaches the CLI's stdout.
run_task() {
  local name="$1" trigger="$2"
  local task_json prompt cwd perm_override worktree_enabled settings model
  task_json=$(jq -c --arg n "$name" '.tasks[] | select(.name == $n)' "$TASKS")
  prompt=$(jq -r '.prompt' <<<"$task_json")
  settings=$(jq -r '.settings // empty' <<<"$task_json")
  local model_source
  IFS='|' read -r model model_source < <(resolve_model "$(jq -r '.model // empty' <<<"$task_json")")
  cwd=$(jq -r '.cwd' <<<"$task_json")
  perm_override=$(jq -r '.permission_mode // empty' <<<"$task_json")
  worktree_enabled=$(jq -r '.worktree' <<<"$task_json")

  # Resolve backend + agent kind now: the omarchy default may have changed
  # since the task was added. Done before the run entry exists so a bad
  # config still gets a logged, failed run below.
  local kind source execution
  IFS='|' read -r kind source < <(resolve_agent "$(jq -r '.agent // empty' <<<"$task_json")")
  execution=$(resolve_execution "$(jq -r '.execution // empty' <<<"$task_json")")

  mkdir -p -m 700 "$STATE_DIR/logs"

  local sid start run_id
  sid=$(uuidgen)
  [[ $execution == herdr ]] && sid=""
  start=$(now)
  lock
  run_id=$(jq -r '.nextRunId' "$RUNS")
  apply "$RUNS" \
    --argjson id "$run_id" --arg task "$name" --arg trig "$trigger" \
    --argjson start "$start" --arg sid "$sid" --arg backend "$execution" \
    --argjson pid "$BASHPID" --arg boot "$(boot_id)" '
    .nextRunId = ($id + 1)
    | .runs += [{
        id: $id, task: $task, trigger: $trig, start: $start, end: null,
        status: "running", exit_code: null, session_id: (if $sid == "" then null else $sid end),
        permission_mode: null, model: null, worktree_path: null, worktree_branch: null, cwd: null,
        backend: $backend, reason: null, pane_id: null, tab_id: null, workspace_id: null, agent_name: null,
        pid: $pid, boot_id: $boot
      }]
  '
  unlock

  local log_file="$STATE_DIR/logs/${run_id}.out"
  (umask 077 && : >"$log_file")

  # Killed (logout, stop, Ctrl-C): finalize as failed with what is known so
  # far. Once finalize_run has started, the normal path owns the entry. Bash
  # runs this only after a foreground child exits; under systemd the whole
  # cgroup is signaled, so sleep / herdr children die with us.
  local run_dir="" wt_path="" wt_branch="" base_commit=""
  FINALIZING=""
  HERDR_PANE="" HERDR_TAB="" HERDR_WS="" HERDR_AGENT=""
  on_kill() {
    trap '' TERM INT HUP
    [[ -n $FINALIZING ]] && return
    echo "omaroutines: run killed" >>"$log_file"
    finalize_run "$run_id" "$name" "$(jq -nc --arg rd "${run_dir:-$cwd}" --arg pane "$HERDR_PANE" \
      --arg tab "$HERDR_TAB" --arg ws "$HERDR_WS" --arg agent "$HERDR_AGENT" '
      def nn: if . == "" then null else . end;
      {exit_code: 1, status: "failure", reason: "killed", cwd: $rd, pane_id: ($pane | nn),
       tab_id: ($tab | nn), workspace_id: ($ws | nn), agent_name: ($agent | nn)}')"
    exit 1
  }
  trap on_kill TERM INT HUP

  # A missed run usually fires the moment the machine wakes, before the
  # network, auth, and herdr are usable; give them time to settle.
  if [[ $trigger == missed ]] && ((RESUME_DELAY > 0)); then
    echo "omaroutines: missed run, waiting ${RESUME_DELAY}s for the system to settle" >>"$log_file"
    # backgrounded + wait: a trapped signal interrupts wait, not sleep
    sleep "$RESUME_DELAY" &
    wait $! || true
  fi

  # A run that never launches an agent: log the message, record the reason.
  fail_config() {
    echo "omaroutines: $1" | tee -a "$log_file" >&2
    finalize_run "$run_id" "$name" "$(jq -nc --arg c "$cwd" '{exit_code: 1, status: "failure", reason: "invalid_config", cwd: $c}')"
    echo "$run_id failure"
    return 1
  }

  if [[ -z $kind ]]; then
    fail_config "no default agent set for \"$name\" (run: omarchy default agent <name>)"
    return 1
  fi
  if ! validate_agent "$kind" 2>>"$log_file" || ! check_combo "$kind" "$source" "$execution" 2>>"$log_file"; then
    fail_config "task \"$name\" has no valid backend for agent \"$kind\" under $execution (see run $run_id log)"
    return 1
  fi
  if [[ -n $model ]] && ! validate_model "$model" 2>>"$log_file"; then
    fail_config "invalid model \"$model\" for \"$name\""
    return 1
  fi
  # A task --model reaches any kind with a --model flag; the settings default
  # is claude-only. Recorded on the run as what actually applied.
  if [[ -n $model ]] && { ! model_flag_kind "$kind" || [[ $model_source == settings && $kind != claude ]]; }; then
    model=""
  fi

  local mode="$perm_override"
  if [[ -z $mode ]]; then
    mode=$(jq -r '.permissions.defaultMode // empty' "$CLAUDE_HOME/settings.json" 2>/dev/null) || true
  fi
  [[ -z $mode ]] && mode="default"
  if [[ $execution == headless ]] && ! validate_perm_mode "$mode" 2>>"$log_file"; then
    fail_config "invalid permission mode \"$mode\" for \"$name\""
    return 1
  fi

  run_dir="$cwd"
  if [[ $worktree_enabled == true ]]; then
    local stamp
    stamp=$(date -d "@$start" +%Y%m%d-%H%M%S)
    wt_branch="omaroutines/${name}-${stamp}-${run_id}"
    wt_path="$cwd/.worktrees/${name}-${stamp}-${run_id}"
    mkdir -p "$cwd/.worktrees"
    # rev-parse fails on a repo with no commits; treat it like a failed worktree add
    if ! base_commit=$(git -C "$cwd" rev-parse HEAD 2>>"$log_file") ||
      ! git -C "$cwd" worktree add -b "$wt_branch" "$wt_path" >>"$log_file" 2>&1; then
      echo "omaroutines: failed to create worktree for \"$name\"" >>"$log_file"
      finalize_run "$run_id" "$name" "$(jq -nc --arg c "$cwd" '{exit_code: 1, status: "failure", cwd: $c}')"
      echo "omaroutines: failed to create worktree for \"$name\"" >&2
      echo "$run_id failure"
      return 1
    fi
    run_dir="$wt_path"
    # On record now, so a killed run's worktree still reaches `prune`.
    lock
    apply "$RUNS" --argjson id "$run_id" --arg wp "$wt_path" --arg wb "$wt_branch" --arg base "$base_commit" '
      .runs |= map(if .id == $id then .worktree_path = $wp | .worktree_branch = $wb | .base_commit = $base else . end)'
    unlock
  fi

  local exit_code status reason="" pane="" tab="" ws="" agent_name=""
  if [[ $execution == herdr ]]; then
    local timeout_s herdr_perm=""
    timeout_s=$(jq -r '.herdr_timeout // empty' <<<"$task_json")
    [[ -n $timeout_s ]] || timeout_s=$(setting herdr_timeout_minutes)
    timeout_s=$((timeout_s * 60))
    [[ -n ${OMAROUTINES_HERDR_TIMEOUT:-} ]] && timeout_s="$OMAROUTINES_HERDR_TIMEOUT"
    # Only an explicit task override reaches herdr (no defaultMode fallback),
    # and only for kinds whose unattended flags can carry it.
    if [[ -n $perm_override ]] && perm_override_kind "$kind"; then
      if ! validate_perm_mode "$perm_override" 2>>"$log_file"; then
        fail_config "invalid permission mode \"$perm_override\" for \"$name\""
        return 1
      fi
      herdr_perm="$perm_override"
    fi
    cache_herdr_session
    # errexit off: a failed herdr query must end in finalize_run, never in a
    # run stranded as "running" (the sweep's `run` path has no `||` guard).
    set +e
    herdr_run "$name" "$run_id" "$kind" "$prompt" "$cwd" "$run_dir" "$timeout_s" "$herdr_perm" "$settings" "$model" >>"$log_file" 2>&1
    set -e
    status=${HERDR_RESULT%%|*}
    reason=${HERDR_RESULT#*|}
    pane="$HERDR_PANE"
    tab="$HERDR_TAB"
    ws="$HERDR_WS"
    agent_name="$HERDR_AGENT"
    exit_code=0
    [[ $status == success ]] || exit_code=1
    mode="$herdr_perm"
    [[ -n $pane ]] || grep -h '^omaroutines:' "$log_file" >&2 || true
  else
    set +e
    local -a extra=()
    [[ -n $settings ]] && extra=(--settings "$settings")
    [[ -n $model ]] && extra+=(--model "$model")
    (cd "$run_dir" && "$CLAUDE_BIN" -p "$prompt" --session-id "$sid" --permission-mode "$mode" --output-format json "${extra[@]}") >"$log_file" 2>&1
    exit_code=$?
    set -e
    status="success"
    ((exit_code == 0)) || status="failure"
  fi

  # Unchanged worktrees are removed now, except while a herdr pane still
  # lives in them (attach must find the files); pane pruning removes those.
  if [[ $worktree_enabled == true ]]; then
    local unchanged=0
    if [[ -z $(git -C "$wt_path" status --porcelain) ]] &&
      [[ $(git -C "$wt_path" rev-list --count "$base_commit"..HEAD) -eq 0 ]]; then
      unchanged=1
    fi
    if ((unchanged)) && [[ -z $pane ]]; then
      remove_worktree "$cwd" "$wt_path" "$wt_branch"
      wt_path=""
      wt_branch=""
    fi
  fi

  finalize_run "$run_id" "$name" "$(jq -nc --argjson ec "$exit_code" --arg st "$status" --arg sid "$sid" \
    --arg mode "$mode" --arg wp "$wt_path" --arg wb "$wt_branch" --arg rd "$run_dir" \
    --arg reason "$reason" --arg pane "$pane" --arg tab "$tab" --arg ws "$ws" --arg agent "$agent_name" \
    --arg base "$base_commit" --arg model "$model" '
    def nn: if . == "" then null else . end;
    {exit_code: $ec, status: $st, session_id: ($sid | nn), permission_mode: ($mode | nn), model: ($model | nn),
     worktree_path: ($wp | nn), worktree_branch: ($wb | nn), cwd: $rd,
     reason: ($reason | nn), pane_id: ($pane | nn), tab_id: ($tab | nn), workspace_id: ($ws | nn),
     agent_name: ($agent | nn), base_commit: (if $wp == "" then null else $base end)}')"
  # Pane retention runs once this run's pane is on record, so exactly
  # herdr_retain panes (newest first) survive per task.
  if [[ -n $pane ]]; then
    set +e
    prune_task_panes "$name" >>"$log_file" 2>&1
    set -e
  fi
  trap - TERM INT HUP
  echo "$run_id $status"
  [[ $status == success ]]
}

boot_id() { cat /proc/sys/kernel/random/boot_id; }

# Fail "running" entries whose process is gone without finalizing (SIGKILL,
# or a trap that never ran): another boot, or a dead pid. Legacy entries (no
# pid) only when provably dead: started before this boot, or a herdr run past
# the longest herdr timeout plus slack (headless runs have no bound).
resolve_orphans() {
  local btime max_min id task pid
  btime=$(awk '/^btime/ {print $2}' /proc/stat)
  max_min=$(jq -r --argjson s "$(setting herdr_timeout_minutes)" '[.tasks[].herdr_timeout // 0, $s] | max' "$TASKS")
  while IFS=$'\t' read -r id task pid; do
    [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null && continue
    echo "omaroutines: run process gone; marked orphaned" >>"$STATE_DIR/logs/$id.out"
    finalize_run "$id" "$task" '{"status": "failure", "reason": "orphaned", "exit_code": 1}'
    echo "$task: run $id orphaned"
  done < <(jq -r --arg boot "$(boot_id)" --argjson btime "$btime" --argjson now "$(now)" \
    --argjson limit "$((max_min * 60 + RESUME_DELAY + 600))" '
    .runs[] | select(.status == "running")
    | if .pid != null then
        if .boot_id != $boot then [.id, .task, ""] else [.id, .task, .pid] end
      elif .start < $btime or (.backend == "herdr" and $now - .start > $limit) then [.id, .task, ""]
      else empty end
    | map(tostring) | @tsv' "$RUNS")
}

remove_worktree() {
  git -C "$1" worktree remove --force "$2" >/dev/null 2>&1 || true
  git -C "$1" branch -D "$3" >/dev/null 2>&1 || true
}

cmd_trigger() {
  local name="${1:-}"
  [[ -z $name ]] && {
    echo "omaroutines: trigger requires a task name" >&2
    return 1
  }
  ensure_store
  require_task "$name"

  local out rc=0
  out=$(run_task "$name" manual) || rc=$?
  local run_id status
  read -r run_id status <<<"$out"
  echo "run $run_id: $status ($(run_handle "$run_id"))"
  return "$rc"
}

# "session <id>" for headless runs, "pane <id>" for herdr runs.
run_handle() {
  jq -r --argjson id "$1" '.runs[] | select(.id == $id)
    | if .backend == "herdr" then "pane \(.pane_id // "none")" else "session \(.session_id)" end' "$RUNS"
}

# Recompute + persist next_due for a task "from now" (under lock). Used after
# every fire/backlog resolution so a task never re-fires on the next sweep.
reschedule_from_now() {
  local name="$1" schedule="$2" next_due
  next_due=$(compute_next_due "$schedule") || next_due=null
  lock
  apply "$TASKS" --arg name "$name" --argjson next_due "${next_due:-null}" '
    .tasks |= map(if .name == $name then .next_due = $next_due else . end)
  '
  unlock
}

# Settle herdr runs left waiting on the user (needs_input): once the agent
# is done/idle (answered and finished) or gone, record the real outcome.
# Still blocked or working: leave it. A failed agent query: try next sweep.
resolve_waiting() {
  local waiting agents_json='[]'
  waiting=$(jq -r '.runs[] | select(.status == "needs_input") | [.id, .task, .agent_name] | @tsv' "$RUNS")
  [[ -z $waiting ]] && return 0
  cache_herdr_session
  # server down: its panes, and so the waiting agents, are gone
  if herdr_server_up; then
    agents_json=$(hdq agent list 2>/dev/null | jq -ce '.result.agents') || return 0
  fi
  local id task agent state result st reason
  while IFS=$'\t' read -r id task agent; do
    state=$(jq -r --arg n "$agent" '[.[] | select(.name == $n)][0].agent_status // empty' <<<"$agents_json")
    [[ $state == blocked || $state == working ]] && continue
    result=$(map_agent_state "$state")
    st=${result%%|*}
    reason=${result#*|}
    {
      echo "omaroutines: settled after waiting for input (agent ${state:-gone})"
      snapshot_transcript "$agent"
    } >>"$STATE_DIR/logs/$id.out" 2>&1
    finalize_run "$id" "$task" "$(jq -nc --arg st "$st" --arg r "$reason" '
      {status: $st, reason: (if $r == "" then null else $r end), exit_code: (if $st == "success" then 0 else 1 end), dismissed: false}')"
    echo "$task: run $id $st"
  done <<<"$waiting"
}

cmd_sweep() {
  ensure_store
  local sweep_now
  sweep_now=$(now)
  resolve_orphans || true
  resolve_waiting || true

  local due
  due=$(jq -r --argjson now "$sweep_now" '
    .tasks[] | select(.enabled == true and .schedule != "manual" and .next_due != null and .next_due <= $now)
    | [.name, .schedule, .next_due, (.backlog_since // "null")] | @tsv
  ' "$TASKS")

  [[ -z $due ]] && return 0

  local pids=()
  local name schedule next_due backlog_since
  while IFS=$'\t' read -r name schedule next_due backlog_since; do
    if [[ $backlog_since != null ]]; then
      if ((sweep_now - backlog_since >= BACKLOG_TIMEOUT)); then
        lock
        apply "$TASKS" --arg name "$name" '.tasks |= map(if .name == $name then .backlog_since = null else . end)'
        # Leave a trace of the unanswered backlog; no agent, no notification.
        apply "$RUNS" --arg task "$name" --argjson now "$sweep_now" '
          .nextRunId as $id | .nextRunId = ($id + 1)
          | .runs += [{
              id: $id, task: $task, trigger: "missed", start: $now, end: $now,
              status: "skipped", exit_code: null, session_id: null,
              permission_mode: null, model: null, worktree_path: null, worktree_branch: null, cwd: null,
              backend: null, reason: "backlog_timeout", pane_id: null, tab_id: null, workspace_id: null, agent_name: null
            }]'
        retain_runs "$name"
        unlock
        reschedule_from_now "$name" "$schedule"
        echo "$name: backlog skipped (no response)"
      fi
      # else: pending, not yet timed out -- leave alone, no re-notify.
      continue
    fi

    local second_occurrence
    second_occurrence=$(compute_next_due "$schedule" "--base-time=@$next_due") || second_occurrence=""
    if [[ -n $second_occurrence ]] && ((second_occurrence <= sweep_now)); then
      lock
      apply "$TASKS" --arg name "$name" --argjson now "$sweep_now" \
        '.tasks |= map(if .name == $name then .backlog_since = $now else . end)'
      unlock
      "$NOTIFY_BIN" -g "$GLYPH" "Omaroutines: missed runs of $name" \
        "Machine was away across several scheduled runs. Click to run the backlog once, or ignore to skip (auto-skip in $((BACKLOG_TIMEOUT / 60)) min)." \
        --exec omaroutines backlog run "$name" >/dev/null 2>&1 || true
      echo "$name: backlog pending (notified)"
    else
      local trig=scheduled
      ((sweep_now - next_due > MISS_GRACE)) && trig=missed
      reschedule_from_now "$name" "$schedule"
      launch_run "$name" "$trig"
      echo "$name: fired ($trig)"
    fi
  done <<<"$due"

  if [[ ${OMAROUTINES_SWEEP_WAIT:-} == 1 && ${#pids[@]} -gt 0 ]]; then
    wait "${pids[@]}" 2>/dev/null || true
  fi
}

# Detach a run from the sweep. Under the systemd oneshot service a plain `&`
# child is killed the moment sweep exits (KillMode=control-group), so there
# each run becomes its own transient unit; elsewhere (tests, a shell) `&` is fine.
launch_run() {
  local name="$1" trigger="$2"
  if [[ -n ${INVOCATION_ID:-} && ${OMAROUTINES_SWEEP_WAIT:-} != 1 ]] && command -v systemd-run >/dev/null; then
    systemd-run --user --quiet --collect --unit "omaroutines-run-$name-$(now)-$$" \
      --setenv=PATH="$PATH" "$(realpath "$0")" run "$name" "$trigger" || {
      echo "omaroutines: systemd-run failed for \"$name\"" >&2
    }
  else
    run_task "$name" "$trigger" >/dev/null 2>&1 &
    pids+=("$!")
  fi
}

cmd_backlog() {
  local verb="${1:-}" name="${2:-}"
  [[ $verb == run || $verb == skip ]] || {
    echo "omaroutines: backlog requires \"run\" or \"skip\" <name>" >&2
    return 1
  }
  [[ -z $name ]] && {
    echo "omaroutines: backlog $verb requires a task name" >&2
    return 1
  }
  ensure_store
  require_task "$name"

  local schedule
  schedule=$(jq -r --arg n "$name" '.tasks[] | select(.name == $n) | .schedule' "$TASKS")

  lock
  apply "$TASKS" --arg name "$name" '.tasks |= map(if .name == $name then .backlog_since = null else . end)'
  unlock
  reschedule_from_now "$name" "$schedule"

  if [[ $verb == skip ]]; then
    echo "$name: backlog skipped"
    return 0
  fi

  local out rc=0
  out=$(run_task "$name" backlog-catchup) || rc=$?
  local run_id status
  read -r run_id status <<<"$out"
  echo "run $run_id: $status ($(run_handle "$run_id"))"
  return "$rc"
}

# Acknowledge a task's failed / waiting latest run so it stops counting.
# `--missed` (all tasks) marks late-run latest runs seen via missed_seen, a
# separate flag so it never hides a failure.
cmd_dismiss() {
  if [[ ${1:-} == --missed ]]; then
    ensure_store
    lock
    apply "$RUNS" '
      ([.runs | group_by(.task)[] | max_by(.id) | select(.trigger == "missed") | .id]) as $ids
      | .runs |= map(if (.id as $i | $ids | index($i)) != null then .missed_seen = true else . end)
    '
    unlock
    echo "missed: acknowledged"
    return
  fi
  local name="${1:-}"
  [[ -z $name ]] && {
    echo "omaroutines: dismiss requires a task name" >&2
    return 1
  }
  ensure_store
  require_task "$name"
  lock
  apply "$RUNS" --arg name "$name" '
    ([.runs[] | select(.task == $name)] | max_by(.id) // {} | .id) as $last
    | .runs |= map(if .id == $last and (.status == "failure" or .status == "needs_input") then .dismissed = true else . end)
  '
  unlock
  echo "$name: dismissed"
}

cmd_log() {
  local name="${1:-}"
  shift || true
  [[ -z $name ]] && {
    echo "omaroutines: log requires a task name" >&2
    return 1
  }
  ensure_store
  require_task "$name"

  if [[ ${1:-} == --json ]]; then
    # log_path is null once the captured output file is gone.
    local logs_json
    logs_json=$(find "$STATE_DIR/logs" -name '*.out' -printf '%f\n' 2>/dev/null | sed 's/\.out$//' | jq -R . | jq -sc .)
    jq -c --arg n "$name" --arg logs "$STATE_DIR/logs" \
      --argjson avail "$(available_sessions_json)" --argjson logs_present "$logs_json" \
      --argjson panes "$(live_panes_json)" '
      [.runs[] | select(.task == $n)
        | .backend = (.backend // "headless") | .reason = (.reason // null) | .pane_id = (.pane_id // null)
        | .session_available = (.session_id as $s | $avail | index($s) != null)
        | .pane_available = (.pane_id as $p | $p != null and ($panes | index($p)) != null)
        | .log_path = ((.id | tostring) as $i | if ($logs_present | index($i)) != null then "\($logs)/\($i).out" else null end)]
      | sort_by(.id) | reverse' "$RUNS"
    return
  fi

  local any=0
  while IFS=$'\t' read -r id start end status trig; do
    any=1
    local start_text end_text
    start_text=$(when_text "$start")
    end_text="-"
    [[ $end != null ]] && end_text=$(when_text "$end")
    printf '  #%-4s %-9s %-20s %-20s %s\n' "$id" "$status" "$start_text" "$end_text" "$trig"
  done < <(jq -r --arg n "$name" '
    [.runs[] | select(.task == $n)] | sort_by(.id) | reverse
    | .[] | [.id, .start, (.end // "null"), .status, .trigger] | @tsv
  ' "$RUNS")

  ((any)) || echo "  no runs yet"
}

cmd_resume() {
  local run_id="${1:-}" terminal=0
  [[ ${2:-} == --terminal ]] && terminal=1
  [[ -z $run_id ]] && {
    echo "omaroutines: resume requires a run id" >&2
    return 1
  }
  ensure_store

  local run
  run=$(jq -c --argjson id "$run_id" '.runs[] | select(.id == $id)' "$RUNS" 2>/dev/null) || run=""
  [[ -z $run ]] && {
    echo "omaroutines: no such run \"$run_id\"" >&2
    return 1
  }

  local sid task_name rcwd
  sid=$(jq -r '.session_id' <<<"$run")
  task_name=$(jq -r '.task' <<<"$run")
  rcwd=$(jq -r '.cwd' <<<"$run")

  [[ $(jq -r '.backend // "headless"' <<<"$run") == herdr ]] && {
    echo "omaroutines: run $run_id is a herdr run; use: omaroutines attach $run_id" >&2
    return 1
  }
  if ! compgen -G "$CLAUDE_HOME/projects/*/${sid}.jsonl" >/dev/null; then
    echo "omaroutines: session no longer available (run $run_id)" >&2
    return 1
  fi

  [[ -d $rcwd ]] || rcwd=$(jq -r --arg n "$task_name" '.tasks[] | select(.name == $n) | .cwd' "$TASKS")
  # --terminal (panel): checks done, hand the actual resume to a detached
  # terminal so the caller returns immediately.
  if ((terminal)); then
    setsid -f "$TERMINAL_BIN" "$(realpath "$0")" resume "$run_id" >/dev/null 2>&1
    return 0
  fi
  cd "$rcwd"
  exec "$CLAUDE_BIN" --resume "$sid"
}

# attach <run-id> [--terminal]: focus the run's agent in the background
# session, then attach a terminal to that session (the herdr counterpart of
# resume). --terminal hands the attach to a detached terminal like resume.
cmd_attach() {
  local run_id="${1:-}" terminal=0
  [[ ${2:-} == --terminal ]] && terminal=1
  [[ -z $run_id ]] && {
    echo "omaroutines: attach requires a run id" >&2
    return 1
  }
  ensure_store
  cache_herdr_session
  local run
  run=$(jq -c --argjson id "$run_id" '.runs[] | select(.id == $id)' "$RUNS" 2>/dev/null) || run=""
  [[ -z $run ]] && {
    echo "omaroutines: no such run \"$run_id\"" >&2
    return 1
  }
  [[ $(jq -r '.backend // "headless"' <<<"$run") == herdr ]] || {
    echo "omaroutines: run $run_id is a headless run; use: omaroutines resume $run_id" >&2
    return 1
  }
  local pane agent
  pane=$(jq -r '.pane_id // empty' <<<"$run")
  agent=$(jq -r '.agent_name // empty' <<<"$run")
  if [[ -z $pane ]] || ! live_panes_json | jq -e --arg p "$pane" 'index($p) != null' >/dev/null; then
    echo "omaroutines: pane not available for run $run_id (pruned, closed, or herdr server down)" >&2
    return 1
  fi
  if ((terminal)); then
    setsid -f "$TERMINAL_BIN" "$(realpath "$0")" attach "$run_id" >/dev/null 2>&1
    return 0
  fi
  [[ -z $agent ]] || hdq agent focus "$agent" >/dev/null 2>&1 || true
  local session
  session=$(herdr_session)
  if [[ $session == default ]]; then
    hd_exec
  fi
  hd_exec session attach "$session"
}
