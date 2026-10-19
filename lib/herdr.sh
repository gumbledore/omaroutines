# Sourced by bin/omaroutines only; not executable.

# --- herdr ---------------------------------------------------------------------

# Session name from settings. hd() mostly runs inside $(...), where a cache
# assignment would be lost, so entry points that make several herdr calls
# set HERDR_SESSION_NAME once up front (see cache_herdr_session).
herdr_session() {
  [[ -n ${HERDR_SESSION_NAME:-} ]] && echo "$HERDR_SESSION_NAME" || setting herdr_session
}
cache_herdr_session() { HERDR_SESSION_NAME=$(setting herdr_session); }

# Run herdr against the configured session. HERDR_SOCKET_PATH/HERDR_ENV are
# scrubbed: inherited from a herdr pane they override HERDR_SESSION and point
# at the foreground server. "default" means the foreground session.
hd() {
  local session
  session=$(herdr_session)
  if [[ $session == default ]]; then
    env -u HERDR_SESSION -u HERDR_SOCKET_PATH -u HERDR_ENV "$HERDR_BIN" "$@"
  else
    env -u HERDR_SOCKET_PATH -u HERDR_ENV HERDR_SESSION="$session" "$HERDR_BIN" "$@"
  fi
}

# Bounded variants (a hung server must not hang `list` or strand a run):
# re-enter this script so `timeout` wraps hd(); the `_herdr` entry execs
# herdr, so the signal reaches it rather than an orphaned child.
hdq() { timeout "$HERDR_QUICK" "$HERDR_BIN_WRAP" _herdr "$@"; }
hdm() { timeout "$HERDR_MUTATE" "$HERDR_BIN_WRAP" _herdr "$@"; }
hd_exec() {
  local session
  session=$(herdr_session)
  if [[ $session == default ]]; then
    exec env -u HERDR_SESSION -u HERDR_SOCKET_PATH -u HERDR_ENV "$HERDR_BIN" "$@"
  else
    exec env -u HERDR_SOCKET_PATH -u HERDR_ENV HERDR_SESSION="$session" "$HERDR_BIN" "$@"
  fi
}

herdr_server_up() {
  hdq status server --json 2>/dev/null | jq -e '.running == true' >/dev/null 2>&1
}

# Start + enable the background unit if the server is down, then wait for the
# socket. The foreground ("default") session is never started by us.
ensure_herdr_server() {
  herdr_server_up && return 0
  if [[ $(herdr_session) == default ]]; then
    echo "omaroutines: herdr server is not running (herdr_session is \"default\": start herdr first)" >&2
    return 1
  fi
  "$SYSTEMCTL_BIN" --user start "$HERDR_UNIT" || {
    echo "omaroutines: could not start $HERDR_UNIT (run install.sh?)" >&2
    return 1
  }
  "$SYSTEMCTL_BIN" --user enable "$HERDR_UNIT" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + HERDR_START_WAIT))
  while ((SECONDS < deadline)); do
    herdr_server_up && return 0
    sleep 0.25
  done
  echo "omaroutines: herdr server did not come up within ${HERDR_START_WAIT}s" >&2
  return 1
}

# JSON array of live pane ids ([] when the server is down / unreachable).
live_panes_json() {
  local out
  out=$(hdq pane list 2>/dev/null) && jq -c '[.result.panes[].pane_id]' <<<"$out" 2>/dev/null && return 0
  echo '[]'
}

# Unattended flags per agent kind, copied from omarchy-agent (keep in sync).
# $2: optional task permission-mode override, honored only by the kinds that
# take --permission-mode (claude, grok); other kinds keep their fixed flag.
unattended_flags() {
  local override="${2:-}"
  case "$1" in
  claude) echo "--permission-mode ${override:-auto}" ;;
  codex) echo "--approve-for-me" ;;
  gemini) echo "--yolo" ;;
  opencode) echo "--auto" ;;
  copilot) echo "--allow-all" ;;
  omp) echo "--auto-approve" ;;
  grok) echo "--permission-mode ${override:-bypassPermissions}" ;;
  *) echo "" ;;
  esac
}

# Kinds whose herdr unattended flags accept a permission-mode override.
perm_override_kind() {
  case "$1" in claude | grok) return 0 ;; *) return 1 ;; esac
}

# Kinds whose CLI takes `--model <value>` (checked against each one's --help;
# omp, opencode, grok and copilot expose no model flag). A task --model is
# passed verbatim to these; the settings default applies to claude only
# since model names are per vendor.
model_flag_kind() {
  case "$1" in claude | pi | codex | gemini) return 0 ;; *) return 1 ;; esac
}

# Agent lifecycle state by name via `agent list`; "" when absent.
herdr_agent_state() {
  hdq agent list 2>/dev/null | jq -r --arg n "$1" '.result.agents[] | select(.name == $n) | .agent_status' 2>/dev/null | head -1
}

# Map an observed state to "<status>|<reason>" per the spec.
map_agent_state() {
  case "$1" in
  done | idle) echo "success|" ;;
  blocked) echo "needs_input|blocked" ;;
  working) echo "failure|timeout" ;;
  *) echo "failure|exited" ;;
  esac
}

# Serialize herdr launches process-wide: block until at least
# herdr_launch_stagger_seconds have passed since the previous launch began.
# Concurrent scheduled/manual triggers (e.g. several tasks due in the same
# sweep tick) otherwise hit the herdr session at the same instant and its
# per-pane readiness check can time out (agent_prompt_stalled) under the
# resulting contention, even though each launch is individually well-formed.
herdr_throttle() {
  local stagger last wait_for
  stagger="${OMAROUTINES_HERDR_STAGGER:-$(setting herdr_launch_stagger_seconds)}"
  [[ $stagger =~ ^[0-9]+$ ]] || stagger=5
  ((stagger == 0)) && return 0
  exec 8>"$HERDR_LAUNCH_LOCK"
  flock 8
  last=$(cat "$HERDR_LAUNCH_STAMP" 2>/dev/null) || last=0
  [[ $last =~ ^[0-9]+$ ]] || last=0
  wait_for=$((last + stagger - $(now)))
  ((wait_for > 0)) && sleep "$wait_for"
  now >"$HERDR_LAUNCH_STAMP"
  exec 8>&-
}

# One recovery for a stalled prompt: Enter if the prompt text sits unsubmitted
# in the input box, else resubmit. Succeeds once the prompt registered
# (working/blocked/done); the settled `agent wait` JSON lands in HERDR_RECOVER_OUT
# (empty on a wait timeout, so the caller's live state lookup reports it).
herdr_recover_stall() {
  local agent="$1" prompt="$2" remaining="$3" pane needle
  HERDR_RECOVER_OUT=""
  ((remaining > 0)) || return 1
  pane=$(hdq agent read "$agent" --source recent --format text 2>/dev/null) || pane=""
  needle=$(head -n1 <<<"$prompt")
  needle=${needle:0:40}
  # Claude may collapse a long paste to "[Pasted text #N ...]" in the input box
  if [[ (-n $needle && $pane == *"$needle"*) || $pane == *"[Pasted text"* ]]; then
    echo "omaroutines: stalled prompt sits in the input box; recovery: Enter"
    hdm agent send-keys "$agent" enter >/dev/null 2>&1 || return 1
  else
    echo "omaroutines: stalled prompt was lost; recovery: resubmit"
    hdm agent prompt "$agent" "$prompt" >/dev/null 2>&1 || return 1
  fi
  # Confirm registration first: idle is also a finished agent's state, so
  # waiting on idle alone would "succeed" instantly.
  timeout 40 "$HERDR_BIN_WRAP" _herdr agent wait "$agent" --until working --until blocked --until done --timeout 30000 >/dev/null 2>&1 || return 1
  remaining=$((remaining - 30))
  ((remaining > 0)) || remaining=1
  HERDR_RECOVER_OUT=$(timeout "$((remaining + 60))" "$HERDR_BIN_WRAP" _herdr agent wait "$agent" --until idle --until done --until blocked --timeout "$((remaining * 1000))" 2>&1) || HERDR_RECOVER_OUT=""
  return 0
}

# Run one task under herdr: workspace by cwd label, new unfocused tab, agent
# start with unattended flags, prompt --wait, settle -> status/reason,
# transcript snapshot. Sets HERDR_RESULT="status|reason", HERDR_PANE,
# HERDR_TAB, HERDR_WS. Everything it prints goes to the run log.
herdr_run() {
  local name="$1" run_id="$2" kind="$3" prompt="$4" cwd="$5" run_dir="$6" timeout_s="$7" perm_mode="${8:-}" settings="${9:-}" model="${10:-}"
  HERDR_RESULT="failure|exited"
  HERDR_AGENT=""
  HERDR_PANE=""
  HERDR_TAB=""
  HERDR_WS=""

  herdr_throttle
  ensure_herdr_server || return 0

  local label out
  label=$(basename "$cwd")
  HERDR_WS=$(hdq workspace list 2>/dev/null | jq -r --arg l "$label" '[.result.workspaces[] | select(.label == $l)][0].workspace_id // empty') || HERDR_WS=""
  if [[ -z $HERDR_WS ]]; then
    out=$(hdm workspace create --cwd "$cwd" --label "$label" 2>&1) || {
      echo "omaroutines: could not create herdr workspace: $out"
      return 0
    }
    HERDR_WS=$(jq -r '.result.workspace.workspace_id' <<<"$out")
  fi
  out=$(hdm tab create --workspace "$HERDR_WS" --cwd "$run_dir" --no-focus 2>&1) || {
    echo "omaroutines: could not open a herdr tab: $out"
    return 0
  }
  HERDR_PANE=$(jq -r '.result.root_pane.pane_id' <<<"$out")
  HERDR_TAB=$(jq -r '.result.tab.tab_id' <<<"$out")

  local agent="${name}-${run_id}" flags state
  # shellcheck disable=SC2206
  flags=($(unattended_flags "$kind" "$perm_mode"))
  # Appended unsplit: a JSON literal may contain spaces. Claude only.
  [[ -n $settings && $kind == claude ]] && flags+=(--settings "$settings")
  [[ -n $model ]] && model_flag_kind "$kind" && flags+=(--model "$model")
  out=$(hdm agent start "$agent" --kind "$kind" --pane "$HERDR_PANE" --timeout "$HERDR_AGENT_START_MS" -- "${flags[@]}" 2>&1) || {
    if [[ $out == *agent_name_taken* ]]; then
      agent="${agent}-$RANDOM"
      out=$(hdm agent start "$agent" --kind "$kind" --pane "$HERDR_PANE" --timeout "$HERDR_AGENT_START_MS" -- "${flags[@]}" 2>&1) || true
    fi
  }
  HERDR_AGENT="$agent"
  state=$(jq -r '.result.agent.agent_status // empty' <<<"$out" 2>/dev/null) || state=""
  if [[ -z $state ]]; then
    # start failed or timed out; the pane, not the exit code, is the truth
    echo "omaroutines: herdr agent start: $out"
    state=$(herdr_agent_state "$agent") || state=""
    if [[ $state != idle && $state != done ]]; then
      HERDR_RESULT=$(map_agent_state "$state")
      snapshot_transcript "$agent"
      return 0
    fi
  fi

  local t0=$SECONDS
  out=$(timeout "$((timeout_s + 60))" "$HERDR_BIN_WRAP" _herdr agent prompt "$agent" "$prompt" --wait --timeout "$((timeout_s * 1000))" 2>&1) || true
  if [[ $(jq -r '.error.code // empty' <<<"$out" 2>/dev/null) == agent_prompt_stalled ]]; then
    # herdr never saw the pane register the prompt (agent still booting). The
    # agent sits "idle" exactly as after a normal finish, so a live state
    # query can't tell; recover once, else report the stall.
    echo "omaroutines: herdr agent prompt: $out"
    if ! herdr_recover_stall "$agent" "$prompt" "$((timeout_s - (SECONDS - t0)))"; then
      HERDR_RESULT="failure|stalled"
      snapshot_transcript "$agent"
      return 0
    fi
    out=$HERDR_RECOVER_OUT
  fi
  state=$(jq -r '.result.agent.agent_status // empty' <<<"$out" 2>/dev/null) || state=""
  if [[ -z $state ]]; then
    echo "omaroutines: herdr agent prompt: $out"
    state=$(herdr_agent_state "$agent") || state=""
  fi
  HERDR_RESULT=$(map_agent_state "$state")
  snapshot_transcript "$agent"
  return 0
}

# Clean worktree with no commits past the recorded base.
worktree_unchanged() {
  local wt="$1" base="$2"
  [[ -d $wt && -n $base ]] || return 1
  [[ -z $(git -C "$wt" status --porcelain 2>/dev/null) ]] &&
    [[ $(git -C "$wt" rev-list --count "$base"..HEAD 2>/dev/null) -eq 0 ]]
}

# Pane retention for one task, run after a new pane is recorded: panes that
# vanished are reconciled; beyond `herdr_retain` live panes (newest first)
# the settled ones are closed (working/blocked never are). A closed pane's
# unchanged worktree goes with it; the run entry and log stay.
prune_task_panes() {
  local task="$1" retain live agents_json kept=0
  retain=$(setting herdr_retain)
  live=$(live_panes_json)
  agents_json=$(hdq agent list 2>/dev/null | jq -c '.result.agents // []' 2>/dev/null) || agents_json='[]'
  local id pane tab agent wt_path wt_branch base state
  # \x1f-separated: empty fields (no tab_id on a legacy run) must not collapse
  while IFS=$'\x1f' read -r id pane tab agent wt_path wt_branch base; do
    [[ -z $id ]] && continue
    if jq -e --arg p "$pane" 'index($p) != null' <<<"$live" >/dev/null; then
      if ((kept < retain)); then
        kept=$((kept + 1))
        continue
      fi
      state=$(jq -r --arg n "$agent" --arg p "$pane" '[.[] | select(.name == $n or .pane_id == $p)][0].agent_status // empty' <<<"$agents_json")
      [[ $state == working || $state == blocked || -z $tab ]] && continue
      hdm tab close "$tab" </dev/null >/dev/null 2>&1 || {
        echo "omaroutines: could not close pane $pane (run $id); keeping it"
        continue
      }
      echo "omaroutines: closed pane $pane (run $id, retain $retain)"
    fi
    local drop_wt=false
    if [[ $wt_path != null ]] && worktree_unchanged "$wt_path" "$base"; then
      remove_worktree "$(dirname "$(dirname "$wt_path")")" "$wt_path" "$wt_branch"
      drop_wt=true
    fi
    lock
    apply "$RUNS" --argjson id "$id" --argjson drop_wt "$drop_wt" '
      .runs |= map(if .id == $id then .pane_id = null | .tab_id = null
        | (if $drop_wt then .worktree_path = null | .worktree_branch = null else . end) else . end)'
    unlock
  done < <(jq -r --arg t "$task" '
    [.runs[] | select(.task == $t and .pane_id != null)] | sort_by(.id) | reverse | .[]
    | [.id, .pane_id, (.tab_id // ""), (.agent_name // ""), (.worktree_path // "null"),
       (.worktree_branch // ""), (.base_commit // "")] | map(tostring) | join("\u001f")' "$RUNS")
  lock
  retain_runs "$task"
  unlock
}

snapshot_transcript() {
  echo "--- transcript ($1) ---"
  hdq agent read "$1" --source recent --format text 2>/dev/null || echo "(agent no longer present)"
}
