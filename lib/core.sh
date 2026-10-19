# Sourced by bin/omaroutines only; not executable.

# --- store -------------------------------------------------------------------

ensure_store() {
  [[ -f $TASKS ]] || echo '{"version":1,"tasks":[]}' >"$TASKS"
  [[ -f $RUNS ]] || echo '{"version":1,"nextRunId":1,"runs":[]}' >"$RUNS"
}

lock() {
  exec 9>"$LOCK"
  flock 9
}

# Release the lock taken by lock(). Safe to call even if not currently held.
# (No extra redirections here: `exec` without a command makes them permanent,
# so `exec 9>&- 2>/dev/null` would silence stderr for the rest of the script.)
unlock() {
  exec 9>&-
}

# Apply a jq filter to a store file and replace it atomically. Held under the
# lock taken by the caller, so read-modify-write cannot interleave. First arg
# is the target file (tasks.json or runs.json); rest is passed to jq.
apply() {
  local target="$1"
  shift
  local tmp
  tmp=$(mktemp "$STATE_DIR/.$(basename "$target").XXXXXX")
  if jq "$@" "$target" >"$tmp"; then
    mv "$tmp" "$target"
  else
    rm -f "$tmp"
    return 1
  fi
}

# --- time --------------------------------------------------------------------

# Frozen clock for deterministic tests; real clock otherwise.
now() { echo "${OMAROUTINES_NOW:-$(date +%s)}"; }

when_text() { date -d "@$1" +'%a %-d %b %H:%M'; }

# Validate + normalize a systemd calendar expression. Prints the normalized
# form on stdout; on failure prints systemd-analyze's own stderr and returns 1.
normalize_schedule() {
  local expr="$1"
  [[ $expr == manual ]] && {
    echo manual
    return 0
  }
  local out
  if ! out=$(systemd-analyze calendar --iterations=1 "$expr" 2>&1); then
    echo "$out" >&2
    return 1
  fi
  grep '^Normalized form:' <<<"$out" | sed 's/^Normalized form: *//'
}

# Compute next_due epoch for a (already-validated) expression. "manual" -> "".
# Optional --base-time=@<epoch> forwarded to systemd-analyze (ticket 05 needs
# it for "occurrence after next_due"); when OMAROUTINES_NOW is set we always
# pass it so tests are deterministic.
compute_next_due() {
  local expr="$1" base="${2:-}"
  [[ $expr == manual ]] && return 0
  if [[ -z $base && -n ${OMAROUTINES_NOW:-} ]]; then
    base="--base-time=@$(now)"
  fi
  local out elapse
  if [[ -n $base ]]; then
    out=$(systemd-analyze calendar --iterations=1 "$base" "$expr" 2>&1)
  else
    out=$(systemd-analyze calendar --iterations=1 "$expr" 2>&1)
  fi
  elapse=$(grep '^    Next elapse:' <<<"$out" | sed 's/^    Next elapse: *//')
  [[ -z $elapse ]] && return 1
  date -d "$elapse" +%s
}

# --- validation ----------------------------------------------------------------

# Same rule as herdr agent names (^[a-z][a-z0-9_-]{0,31}$), capped at 20 so
# "<name>-<run_id>-<retry>" still fits herdr's 32-char limit.
validate_name() {
  local name="$1"
  [[ $name =~ ^[a-z][a-z0-9_-]{0,19}$ ]] || {
    echo "omaroutines: invalid task name \"$name\" (lowercase letter first, then lowercase letters, digits, _ -; max 20 chars)" >&2
    return 1
  }
}

validate_perm_mode() {
  local mode="$1"
  [[ " $PERM_MODES " == *" $mode "* ]] || {
    echo "omaroutines: invalid permission mode \"$mode\" (allowed: ${PERM_MODES// /, })" >&2
    return 1
  }
}

# Model: passed verbatim as `claude --model`; alias or full model id.
validate_model() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || {
    echo "omaroutines: invalid model \"$1\" (an alias like sonnet/opus/fable or a full model id)" >&2
    return 1
  }
}

# Task `settings`: a JSON literal or a path to a settings file, passed to
# claude as --settings. Claude accepts both; we only reject obvious mistakes.
validate_settings() {
  local v="${1#"${1%%[![:space:]]*}"}"
  if [[ $v == \{* ]]; then
    jq -e . <<<"$v" >/dev/null 2>&1 || {
      echo "omaroutines: --settings is not valid JSON" >&2
      return 1
    }
  elif [[ ! -f $v ]]; then
    echo "omaroutines: --settings \"$v\" is neither a JSON object nor an existing file" >&2
    return 1
  fi
}

task_exists() {
  ensure_store
  jq -e --arg n "$1" '.tasks[] | select(.name == $n)' "$TASKS" >/dev/null
}

require_task() {
  task_exists "$1" || {
    echo "omaroutines: no such task \"$1\"" >&2
    return 1
  }
}

# JSON array of session ids that still have a transcript under
# $CLAUDE_HOME/projects — the panel dims Resume from this without a round trip.
available_sessions_json() {
  find "$CLAUDE_HOME/projects" -name '*.jsonl' -printf '%f\n' 2>/dev/null |
    sed 's/\.jsonl$//' | jq -R . | jq -sc .
}

# --- settings ------------------------------------------------------------------

# Merged settings JSON: shipped defaults ⊕ user file, schema_version always the
# shipped one (omagit-config semantics). Missing keys are written back; a file
# that is not JSON is left alone and defaults are used with a warning.
settings_json() {
  local defaults user merged
  defaults=$(jq -c . "$DEFAULTS")
  if [[ -f $SETTINGS ]]; then
    if ! user=$(jq -c . "$SETTINGS" 2>/dev/null); then
      echo "omaroutines: $SETTINGS is not valid JSON, using defaults until it is fixed" >&2
      echo "$defaults"
      return 0
    fi
    merged=$(jq -c -s '.[0].schema_version as $v | .[0] * .[1] | .schema_version = $v' <<<"$defaults"$'\n'"$user")
    [[ $merged == "$user" ]] || write_settings "$merged"
    echo "$merged"
  else
    write_settings "$defaults"
    echo "$defaults"
  fi
}

write_settings() {
  mkdir -p "$CONFIG_DIR"
  local tmp
  tmp=$(mktemp "$CONFIG_DIR/.settings.json.XXXXXX")
  jq . <<<"$1" >"$tmp" && mv "$tmp" "$SETTINGS"
}

setting() { settings_json | jq -r --arg k "$1" '.[$k] // empty'; }

validate_agent() {
  [[ " $AGENT_KINDS " == *" $1 "* ]] || {
    echo "omaroutines: unsupported agent \"$1\" (allowed: ${AGENT_KINDS// /, })" >&2
    return 1
  }
}

validate_execution() {
  [[ " $EXECUTIONS " == *" $1 "* ]] || {
    echo "omaroutines: invalid execution \"$1\" (allowed: ${EXECUTIONS// /, })" >&2
    return 1
  }
}

# Resolve the agent kind: task override -> settings -> omarchy default. Prints
# "<kind>|<source>" where source is task|settings|omarchy|none ("" kind = none).
resolve_agent() {
  local task_agent="$1" kind
  if [[ -n $task_agent ]]; then
    echo "$task_agent|task"
    return
  fi
  kind=$(setting agent)
  if [[ -n $kind ]]; then
    echo "$kind|settings"
    return
  fi
  kind=$("$DEFAULT_AGENT_BIN" 2>/dev/null) || kind=""
  if [[ -n $kind ]]; then
    echo "$kind|omarchy"
  else
    echo "|none"
  fi
}

# Model: task override -> settings -> "" (claude picks its own default).
# Prints "<model>|<source>", source task|settings|none.
resolve_model() {
  local task_model="$1" m
  [[ -n $task_model ]] && { echo "$task_model|task"; return; }
  m=$(setting model)
  [[ -n $m ]] && { echo "$m|settings"; return; }
  echo "|none"
}

resolve_execution() {
  local task_exec="$1"
  [[ -n $task_exec ]] && { echo "$task_exec"; return; }
  setting execution
}

# The only backend/agent combination we refuse: headless with a non-claude
# kind. Used at add/edit/settings set and again at fire time.
check_combo() {
  local kind="$1" source="$2" execution="$3"
  [[ -z $kind || $execution != headless || $kind == claude ]] && return 0
  echo "omaroutines: headless execution supports claude only (agent \"$kind\" comes from $source); use --execution herdr or --agent claude" >&2
  return 1
}

# JSON array of accepted agent kinds whose executable is on PATH (the panel's
# add form offers these).
installed_agent_kinds_json() {
  local k out=""
  for k in $AGENT_KINDS; do
    command -v "$k" >/dev/null 2>&1 && out+="$k"$'\n'
  done
  printf '%s' "$out" | jq -R . | jq -sc .
}
