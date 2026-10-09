#!/usr/bin/env bash
# Runs a GitHub Copilot CLI custom agent in the background and prints a compact summary (status,
# changed files, health, log tail) for the governing Claude Code session.
#   bash .claude/scripts/macos/run-agent.sh start  <agent> <prompt-file> [model]   (returns at once)
#   bash .claude/scripts/macos/run-agent.sh wait   <RUN_ID>     (blocks up to WAIT_MINUTES; run it in the background)
#   bash .claude/scripts/macos/run-agent.sh status <RUN_ID>     (returns at once)
#   bash .claude/scripts/macos/run-agent.sh stop   <RUN_ID>
#   bash .claude/scripts/macos/run-agent.sh list
#
# Each run gets .work/runs/<RUN_ID>/ with the full log, exit code, git-status snapshot and, when the
# OpenCode proxy is used, a proxy log (one line per model request). Settings come from
# .claude/pipeline.env; an environment variable of the same name overrides the file.
#
# Agents are the Copilot editions in .github/agents/<agent>.agent.md. Tool permissions come ONLY from
# .github/copilot/permissions/common.flags + <agent>.flags: the runner never passes --allow-all-tools,
# refuses to start an agent that has no profile, and refuses any profile that grants everything.
# Written for the bash 3.2 that ships with macOS; needs git, perl and pgrep, nothing from Homebrew.
set -euo pipefail

CONFIG_KEYS="WAIT_MINUTES TAIL_LINES POLL_SECONDS COPILOT_BIN COPILOT_WRAPPER MAX_RUN_MINUTES STALL_MINUTES REPEAT_STOP NO_WRITE_STOP LONG_RUN_MINUTES COPILOT_NO_CUSTOM_INSTRUCTIONS COPILOT_REASONING_EFFORT HUNG_CHILD_MINUTES PLANNER_MODEL DEVELOPER_MODEL REVIEWER_MODEL"

ORIG_PWD="$PWD"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
RUNS="$REPO_ROOT/.work/runs"
mkdir -p "$RUNS"

load_config() {
  local file="$REPO_ROOT/.claude/pipeline.env" k
  if [[ -f $file ]]; then
    for k in $CONFIG_KEYS; do
      if eval "[[ -n \${$k+x} ]]"; then eval "__env_$k=\"\$$k\"; __has_$k=1"; fi
    done
    # shellcheck disable=SC1090
    source "$file"
    for k in $CONFIG_KEYS; do
      if eval "[[ -n \${__has_$k+x} ]]"; then eval "$k=\"\$__env_$k\""; fi
    done
  fi
  # Keep WAIT_MINUTES below Claude Code's Bash timeout so every call returns on its own.
  : "${WAIT_MINUTES:=25}"
  : "${TAIL_LINES:=40}"
  : "${POLL_SECONDS:=15}"
  : "${COPILOT_BIN:=copilot}"
  # Wrapper each Copilot run goes through: "with-opencode.sh" for OpenCode Go/Zen, "" to call
  # Copilot directly (GitHub-hosted models, or a BYOK provider that needs no extra headers).
  : "${COPILOT_WRAPPER=}"
  : "${MAX_RUN_MINUTES:=120}"     # hard cap per run; 0 = off
  : "${STALL_MINUTES:=30}"        # stop when log AND diff are both idle this long; 0 = off
  : "${REPEAT_STOP:=40}"          # stop when one agent action repeats this often; 0 = off
  : "${NO_WRITE_STOP:=20}"        # stop an implementer that has changed no file after this long; 0 = off
  : "${LONG_RUN_MINUTES:=30}"     # warn when an implementer run passes this long (one concern per run); 0 = off
  : "${COPILOT_NO_CUSTOM_INSTRUCTIONS:=1}"  # 1 = agents do not auto-load AGENTS.md / CLAUDE.md (see worker)
  : "${COPILOT_REASONING_EFFORT=}"        # none|minimal|low|medium|high|xhigh|max; empty = model default
  case "$COPILOT_REASONING_EFFORT" in ""|none|minimal|low|medium|high|xhigh|max) ;;
    *) echo "COPILOT_REASONING_EFFORT must be empty or one of none|minimal|low|medium|high|xhigh|max (got '$COPILOT_REASONING_EFFORT')" >&2; exit 2 ;;
  esac
  : "${HUNG_CHILD_MINUTES:=10}"   # report a child process idle (≈0% CPU) this long
  : "${PLANNER_MODEL=}" "${DEVELOPER_MODEL=}" "${REVIEWER_MODEL=}"   # empty = provider default
}
load_config

AGENTS_DIR="$REPO_ROOT/.github/agents"
PERMISSIONS_DIR="$REPO_ROOT/.github/copilot/permissions"

# Reads common.flags + <agent>.flags into PERM_FLAGS (one flag per line, '#' comments). Fails closed:
# no profile → no run; a flag that grants everything, or lets an interpreter run arbitrary code,
# → no run. This is the only source of tool permissions for a Copilot run.
PERM_FLAGS=()
load_permissions() {
  local agent="$1" file line
  PERM_FLAGS=()
  for file in "$PERMISSIONS_DIR/common.flags" "$PERMISSIONS_DIR/$agent.flags"; do
    [[ -f $file ]] || { echo "No permission profile: ${file#"$REPO_ROOT"/} — refusing to run '$agent' (install the github/ part of the pipeline, or write the profile)." >&2; exit 2; }
    while IFS= read -r line || [[ -n $line ]]; do
      line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -z $line || $line == \#* ]] && continue
      case "$line" in
        --allow-all-tools*|--allow-all|--allow-all=*|--yolo*|--allow-all-paths*|--allow-all-urls*)
          echo "Refusing to run: ${file#"$REPO_ROOT"/} grants everything ($line). Grant tools one by one." >&2; exit 2 ;;
        *"shell(bash"*|*"shell(sh"*|*"shell(zsh"*|*"shell(fish"*|*"shell(pwsh"*|*"shell(powershell"*|*"shell(cmd"*|\
        *"shell(python"*|*"shell(node"*|*"shell(perl"*|*"shell(ruby"*|*"shell(env"*|*"shell(xargs"*|*"shell(eval"*|*"shell(exec"*)
          case "$line" in --deny-tool=*) ;; *)
            echo "Refusing to run: ${file#"$REPO_ROOT"/} allows an interpreter ($line), which can run anything. Route the command through the gateway instead." >&2; exit 2 ;;
          esac ;;
        --*) ;;
        *) echo "Refusing to run: ${file#"$REPO_ROOT"/} has a line that is not a flag: $line" >&2; exit 2 ;;
      esac
      PERM_FLAGS+=("$line")
    done < "$file"
  done
}

# Implementers write code; planners and the reviewer legitimately change few or no files.
is_implementer() { case "$1" in conductor|conductor-v2|code-reviewer) return 1 ;; *) return 0 ;; esac; }

# The standing rules for one agent: the sections of .github/copilot/agent-rules.md headed
# "## Every agent" or naming the agent in parentheses. Appended to every prompt, so briefs never carry
# (possibly stale) copies of them.
agent_rules() {
  local agent="$1" file="$REPO_ROOT/.github/copilot/agent-rules.md"
  [[ -f $file ]] || return 0
  awk -v a="$agent" '
    /^<!--/ { c = 1 } c { if (/-->/) c = 0; next }
    /^## / { inc = ($0 ~ /^## Every agent/)
             if (match($0, /\([^)]*\)/)) { n = split(substr($0, RSTART + 1, RLENGTH - 2), w, /[ ,]+/)
               for (i = 1; i <= n; i++) if (w[i] == a) inc = 1 }
             if (inc) print; next }
    inc { print }' "$file"
}

# The "Known long-running or hanging commands" section of AGENTS.md (project knowledge an agent needs
# that no agent file or rule carries), without its HTML comment. Injected into the prompt because
# agents run with --no-custom-instructions.
known_hangs() {
  local file="$REPO_ROOT/AGENTS.md"
  [[ -f $file ]] || return 0
  awk '/^## Known long-running or hanging commands/ { on = 1; next } on && /^## / { exit }
       on && /<!--/ { c = 1 } on && c { if (/-->/) c = 0; next } on { print }' "$file" | sed '/^[[:space:]]*$/d'
}

# The model for an agent's role, from .claude/pipeline.env (empty = provider default).
role_model() {
  case "$1" in
    conductor|conductor-v2) printf '%s' "$PLANNER_MODEL" ;;
    code-reviewer) printf '%s' "$REVIEWER_MODEL" ;;
    *) printf '%s' "$DEVELOPER_MODEL" ;;
  esac
}

usage() {
  sed -n '4,8p' "$SCRIPT" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

now() { date +%s; }
mtime() { perl -e 'my @s = stat(shift); print $s[9] // 0' "$1" 2>/dev/null || echo 0; }
minutes_since() { awk -v s="$1" -v n="$(now)" 'BEGIN { printf "%.1f", (n - s) / 60 }'; }

status_lines() { git -c core.quotepath=off status --porcelain=v1 -uall; }

# A cheap fingerprint of the working tree's changes (content-sensitive for tracked files).
diff_fingerprint() {
  { git -c core.quotepath=off diff --numstat 2>/dev/null
    git -c core.quotepath=off ls-files --others --exclude-standard 2>/dev/null
  } | { grep -vE '(^|[[:space:]])\.work/' || true; } | cksum | awk '{ print $1 }'
}

run_dir_for() {
  local dir="$RUNS/$1"
  if [[ ! -d $dir ]]; then echo "Unknown run id: $1" >&2; exit 2; fi
  echo "$dir"
}

worker_alive() {
  local pid_file="$1/pid"
  [[ -f $pid_file ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

descendants() {
  local p
  for p in $(pgrep -P "$1" || true); do
    echo "$p"
    descendants "$p"
  done
}

worker() {
  # Runs in the detached background process.
  local dir="$1" agent prompt_file model code
  agent="$(cat "$dir/agent")"
  prompt_file="$(cat "$dir/prompt_file")"
  model="$(cat "$dir/model")"
  local prompt="Your task brief is in the file ${prompt_file}. Read the whole file and carry it out. You cannot ask the user questions in this run. If something is unclear, make the most reasonable choice and list each such choice under an Open questions heading at the end of your final response."
  local rules
  rules="$(agent_rules "$agent")"
  if [[ -n $rules ]]; then
    prompt="${prompt}

Standing rules for every run (a brief may add to them, never relax them):

${rules}"
  fi
  load_permissions "$agent"
  # Agents get their rules from the prompt (agent-rules.md) and project facts from their agent file,
  # so Copilot's automatic loading of AGENTS.md / CLAUDE.md into every request only adds tokens.
  local hangs
  hangs="$(known_hangs)"
  if [[ -n $hangs ]]; then
    prompt="${prompt}

Known long-running or hanging commands in this repository:

${hangs}"
  fi
  local args=(-p "$prompt" --agent "$agent" --no-ask-user "${PERM_FLAGS[@]}")
  if [[ $COPILOT_NO_CUSTOM_INSTRUCTIONS == 1 ]]; then args+=(--no-custom-instructions); fi
  # Agents never need GitHub access (git and PRs belong to the governor): no built-in GitHub MCP
  # server, so neither its tools nor its instructions reach the agent. Exact usage goes to a file,
  # which also covers runs that end without printing their token line.
  args+=(--disable-builtin-mcps --usage-output-file "$dir/usage.json")
  if [[ -n $model ]]; then args+=(--model "$model"); fi
  if [[ -n $COPILOT_REASONING_EFFORT ]]; then args+=(--reasoning-effort "$COPILOT_REASONING_EFFORT"); fi
  export OPENCODE_SESSION="copilot-$(basename "$dir")"   # one stable session per run
  export OPENCODE_PROXY_LOG="$dir/proxy.log"              # kept with the run (with-opencode.sh)
  local cmd=()
  if [[ $MAX_RUN_MINUTES -gt 0 ]]; then
    cmd+=(bash "$SCRIPT_DIR/with-timeout.sh" "$((MAX_RUN_MINUTES * 60))")
  fi
  if [[ -n $COPILOT_WRAPPER ]]; then cmd+=(bash "$SCRIPT_DIR/$COPILOT_WRAPPER"); fi
  cmd+=("$COPILOT_BIN" "${args[@]}")
  set +e
  "${cmd[@]}" > "$dir/output.log" 2>&1 < /dev/null
  code=$?
  set -e
  if [[ -f $dir/exit ]]; then return 0; fi          # stopped by `stop` meanwhile
  if [[ $code -eq 124 && $MAX_RUN_MINUTES -gt 0 ]]; then
    echo max_runtime > "$dir/stop_reason"
    echo stopped > "$dir/exit"
  else
    echo "$code" > "$dir/exit"
  fi
}

start_run() {
  local agent="$1" prompt_file="$2" model="${3:-}"
  local abs="$prompt_file"
  if [[ $abs != /* ]]; then abs="$ORIG_PWD/$prompt_file"; fi
  if [[ ! -f $abs ]]; then echo "Prompt file not found: $prompt_file" >&2; exit 2; fi
  abs="$(cd "$(dirname "$abs")" && pwd)/$(basename "$abs")"
  local rel="${abs#"$REPO_ROOT"/}"
  if [[ ! -f $AGENTS_DIR/$agent.agent.md ]]; then
    echo "No Copilot agent .github/agents/$agent.agent.md — refusing to run (the .claude/ edition has no Copilot permissions)." >&2
    exit 2
  fi
  load_permissions "$agent"   # validate now, so a bad profile fails before anything starts
  if [[ -z $model ]]; then model="$(role_model "$agent")"; fi

  local id dir
  id="$(date +%Y%m%d-%H%M%S)-$(printf '%s' "$agent" | tr -cd 'A-Za-z0-9_-')"
  dir="$RUNS/$id"
  mkdir -p "$dir"
  printf '%s' "$agent" > "$dir/agent"
  printf '%s' "$rel" > "$dir/prompt_file"
  printf '%s' "$model" > "$dir/model"
  printf '%s' "${COPILOT_WRAPPER:-none}" > "$dir/wrapper"
  status_lines > "$dir/before"
  now > "$dir/started_epoch"
  diff_fingerprint > "$dir/diff_fp"
  now > "$dir/diff_changed_epoch"
  touch "$dir/started"
  echo "$id" > "$RUNS/latest.txt"

  nohup bash "$SCRIPT" __worker "$dir" > /dev/null 2>&1 &
  echo $! > "$dir/pid"
  echo "$id"
}

# --- Health -------------------------------------------------------------------------------------

# Loop signals from the agent log. Prints three lines:
#   action <count> <key>   the most repeated tool call. Copilot logs each call as "● <title>" (or
#                          "✗ <title>" when it failed or was denied) followed by "  │ <command or
#                          path>". The model rewrites the title freely ("Triple check thirty-first
#                          time"), so a shell call is keyed on its command and a read on its path and
#                          line range; edits keep their title, because many edits to one plan are normal.
#   denied <count>         calls refused by the permission profile (each retry counts).
#   text <count> <line>    the most repeated line of prose: a degenerating model writes the same
#                          filler line ("Let me read the model file.") thousands of times, no tool calls.
log_stats() {
  local log="$1"
  if [[ ! -f $log ]]; then printf 'action 0 -\ndenied 0\ntext 0 -\nread 0 -\n'; return; fi
  LC_ALL=C awk '
    function sq(s) { gsub(/[[:space:]]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
    function flush() { if (key != "") { act[key]++; key = "" } }
    /^(● |✗ |\/ )/ {
      flush()
      title = $0; sub(/^(● |✗ |\/ )/, "", title); sub(/[[:space:]]+[0-9.]+m?s[[:space:]]*$/, "", title)
      t = tolower(sq(title)); gsub(/[0-9]+/, "#", t); split(t, w, " ")
      kind = (t ~ /\(shell\)$/) ? "shell" : w[1]
      key = t; stage = (kind == "edit" || kind == "create") ? 0 : 1
      next
    }
    stage == 1 && /^  │ / { c = $0; sub(/^  │ /, "", c); key = kind ": " sq(c); if (kind == "read") reads[sq(c)]++; stage = 2; next }
    stage == 2 && /^  └ L[0-9]+:[0-9]+/ { r = $0; sub(/^  └ /, "", r); sub(/ .*/, "", r); key = key " " r; stage = 0; next }
    /Permission denied and could not request permission|Permission to run this tool was denied/ { denied++ }
    /^[[:space:]]*$/ || /^  [│└]/ { next }
    { stage = 0; x = tolower(sq($0)); if (length(x) >= 8) text[x]++ }
    END {
      flush()
      ba = "-"; ma = 0; for (k in act) if (act[k] > ma) { ma = act[k]; ba = k }
      bt = "-"; mt = 0; for (k in text) if (text[k] > mt) { mt = text[k]; bt = k }
      br = "-"; mr = 0; for (k in reads) if (reads[k] > mr) { mr = reads[k]; br = k }
      printf "action %d %s\ndenied %d\ntext %d %s\nread %d %s\n", ma, substr(ba, 1, 100), denied + 0, mt, substr(bt, 1, 80), mr, substr(br, 1, 100)
    }' "$log"
}
# Prose repeats this often count as degeneration (well above any real report's repeated lines).
filler_limit() { local n=$((REPEAT_STOP * 5)); [[ $n -ge 200 ]] || n=200; echo "$n"; }

# Child processes idle for HUNG_CHILD_MINUTES+ at ~0% CPU, excluding the agent itself, the proxy,
# and the shells/wrappers that merely wait on a child.
hung_children() {
  local dir="$1" wpid pids
  worker_alive "$dir" || return 0
  wpid="$(cat "$dir/pid")"
  pids="$(descendants "$wpid" | tr '\n' ',' | sed 's/,$//')"
  [[ -n $pids ]] || return 0
  { ps -o pid=,etime=,pcpu=,command= -p "$pids" 2>/dev/null || true; } | awk -v lim="$HUNG_CHILD_MINUTES" '
    function mins(e,   d, a, p, n) { d = 0
      if (index(e, "-")) { split(e, a, "-"); d = a[1]; e = a[2] }
      n = split(e, p, ":")
      if (n == 3) return d * 1440 + p[1] * 60 + p[2]
      if (n == 2) return d * 1440 + p[1]
      return 0 }
    { pid = $1; et = $2; cpu = $3; $1 = $2 = $3 = ""; cmd = substr($0, 4)
      if (cmd ~ /(^|\/)(copilot|node|bash|sh|zsh|perl|nohup)( |$)/) next
      if (cmd ~ /opencode-proxy|with-opencode|run-agent|with-timeout/) next
      if (mins(et) >= lim && cpu + 0 < 1.0) printf "%s %sm %s\n", pid, mins(et), substr(cmd, 1, 120) }'
}

# True while the run has changed no file in the working tree (its diff fingerprint never moved).
no_write_yet() { [[ "$(cat "$1/diff_changed_epoch" 2>/dev/null)" == "$(cat "$1/started_epoch" 2>/dev/null)" ]]; }

# Updates the diff fingerprint, then applies the automatic stop rules (loop, stall).
check_health() {
  local dir="$1" fp old
  fp="$(diff_fingerprint)"
  old="$(cat "$dir/diff_fp" 2>/dev/null || true)"
  if [[ $fp != "$old" ]]; then
    echo "$fp" > "$dir/diff_fp"
    now > "$dir/diff_changed_epoch"
  fi
  [[ -f $dir/exit ]] && return 0
  worker_alive "$dir" || return 0

  local stats repeat_count denied text_count log_idle diff_idle
  stats="$(log_stats "$dir/output.log")"
  repeat_count="$(echo "$stats" | awk '$1 == "action" { print $2 }')"
  denied="$(echo "$stats" | awk '$1 == "denied" { print $2 }')"
  text_count="$(echo "$stats" | awk '$1 == "text" { print $2 }')"
  if [[ $REPEAT_STOP -gt 0 ]]; then
    if [[ $repeat_count -ge $REPEAT_STOP ]]; then stop_run "$(basename "$dir")" loop > /dev/null; return 0; fi
    if [[ $denied -ge $REPEAT_STOP ]]; then stop_run "$(basename "$dir")" denied > /dev/null; return 0; fi
    if [[ $text_count -ge $(filler_limit) ]]; then stop_run "$(basename "$dir")" filler > /dev/null; return 0; fi
  fi
  if [[ $NO_WRITE_STOP -gt 0 ]] && is_implementer "$(cat "$dir/agent")" && no_write_yet "$dir"; then
    if awk -v e="$(minutes_since "$(cat "$dir/started_epoch")")" -v s="$NO_WRITE_STOP" 'BEGIN { exit !(e >= s) }'; then
      stop_run "$(basename "$dir")" no_write > /dev/null; return 0
    fi
  fi
  if [[ $STALL_MINUTES -gt 0 && -f $dir/output.log ]]; then
    log_idle="$(minutes_since "$(mtime "$dir/output.log")")"
    diff_idle="$(minutes_since "$(cat "$dir/diff_changed_epoch")")"
    if awk -v a="$log_idle" -v b="$diff_idle" -v s="$STALL_MINUTES" 'BEGIN { exit !(a >= s && b >= s) }'; then
      stop_run "$(basename "$dir")" stalled > /dev/null
    fi
  fi
}

print_health() {
  local dir="$1" log="$1/output.log" lines=0 log_idle="-" stats repeat text hung files requests tokens
  if [[ -f $log ]]; then
    lines="$(wc -l < "$log" | tr -d ' ')"
    log_idle="$(minutes_since "$(mtime "$log")")"
  fi
  stats="$(log_stats "$log")"
  repeat="$(echo "$stats" | sed -n 's/^action //p')"
  text="$(echo "$stats" | sed -n 's/^text //p')"
  files="$(status_lines | grep -cv ' \.work/' || true)"
  echo "HEALTH:"
  echo "  LOG_LINES: $lines · LOG_IDLE_MIN: $log_idle"
  echo "  DIFF_FILES: $files · DIFF_IDLE_MIN: $(minutes_since "$(cat "$dir/diff_changed_epoch" 2>/dev/null || now)")"
  echo "  TOP_REPEAT: ${repeat%% *}× \"${repeat#* }\" (auto-stop at ${REPEAT_STOP:-0}; 0 = off)"
  echo "  DENIED: $(echo "$stats" | sed -n 's/^denied //p') · TOP_TEXT_REPEAT: ${text%% *}× (auto-stop at $(filler_limit))"
  local topread; topread="$(echo "$stats" | sed -n 's/^read //p')"
  echo "  TOP_READ: ${topread%% *}× \"${topread#* }\" (one file, any line range)"
  if is_implementer "$(cat "$dir/agent" 2>/dev/null)" && no_write_yet "$dir" && [[ ! -f $dir/exit ]]; then
    echo "  FIRST_WRITE: none yet after $(minutes_since "$(cat "$dir/started_epoch")") min (auto-stop at ${NO_WRITE_STOP:-0}; 0 = off)"
  fi
  # Runs over ~30 minutes cost the most (a 60-minute run cost as much as five short ones) and are
  # where scope piles up: two phases in one brief, or a 1,000-line test file. Not stopped: say so
  # in the next brief, and split.
  local elapsed; elapsed="$(minutes_since "$(cat "$dir/started_epoch")")"
  if [[ ${LONG_RUN_MINUTES:-0} -gt 0 && ! -f $dir/exit ]] && is_implementer "$(cat "$dir/agent" 2>/dev/null)" \
     && awk -v e="$elapsed" -v l="$LONG_RUN_MINUTES" 'BEGIN { exit !(e >= l) }'; then
    echo "  LONG_RUN: $elapsed min, past $LONG_RUN_MINUTES; split the remaining work into its own run next time"
  fi
  if [[ -f $dir/proxy.log ]]; then
    requests="$(grep -c ' -> ' "$dir/proxy.log" || true)"
    echo "  MODEL_REQUESTS: $requests (errors: $(grep -cE ' -> [45][0-9][0-9]' "$dir/proxy.log" || true))"
  fi
  # Copilot prints its token totals when a run ends; every model request re-sends the whole context,
  # so cost tracks the number of requests far more than the size of the change.
  tokens="$( { grep -a '^Tokens ' "$log" 2>/dev/null || true; } | tail -n 1 | sed 's/^Tokens *//')"
  if [[ -n $tokens ]]; then echo "  TOKENS: $tokens"; fi
  hung="$(hung_children "$dir")"
  if [[ -n $hung ]]; then
    echo "$hung" | sed 's/^/  HUNG_CHILD: /'
  fi
  # A load average far above the core count (often stray processes from an earlier experiment)
  # makes every test timing and agent run look slow for no reason of their own.
  local strays load cores
  # Busy-loop shells re-parented to init: a stopped background stress experiment leaves them behind
  # (40 once ran for 14 hours and made every test suite 3x slower).
  strays="$(ps -eo ppid=,command= 2>/dev/null | awk '$1 == 1 && /while :; do :; done/ { n++ } END { print n + 0 }')"
  if [[ $strays -gt 0 ]]; then
    echo "  STRAY_LOOPS: $strays busy-loop shell(s) are running outside any run; stop them (ps -eo pid,ppid,command | grep 'while :')"
  fi
  load="$(uptime 2>/dev/null | sed -E 's/.*load averages?: *//; s/[ ,].*//')"
  cores="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  if awk -v l="${load:-0}" -v c="$cores" 'BEGIN { exit !(l + 0 > c * 2) }'; then
    echo "  HIGH_LOAD: load average $load on $cores cores; timings are unreliable until it drops (look for stray processes with ps)"
  fi
}

# --- Summary ------------------------------------------------------------------------------------

summary() {
  local id="$1" dir status code="" elapsed
  dir="$(run_dir_for "$id")"
  elapsed="$(minutes_since "$(cat "$dir/started_epoch")")"

  if [[ -f $dir/exit ]]; then
    code="$(cat "$dir/exit")"
    case "$code" in
      0) status=DONE ;;
      stopped) status=STOPPED ;;
      *) status=FAILED ;;
    esac
  elif worker_alive "$dir"; then
    status=RUNNING
  else
    status=FAILED
    code="none (worker exited without recording an exit code)"
  fi

  echo "RUN_ID: $id"
  echo "AGENT: $(cat "$dir/agent")$( [[ -s $dir/model ]] && echo " (model: $(cat "$dir/model"))" )"
  echo "STATUS: $status"
  if [[ $status == STOPPED ]]; then echo "STOP_REASON: $(cat "$dir/stop_reason" 2>/dev/null || echo user)"; fi
  if [[ -n $code && $status != STOPPED ]]; then echo "EXIT_CODE: $code"; fi
  echo "ELAPSED_MIN: $elapsed"
  echo "LOG: .work/runs/$id/output.log"
  print_health "$dir"

  if [[ $status == RUNNING ]]; then
    echo "NEXT: still running. Call again with: wait $id"
    return 0
  fi

  # Files the run created or touched, ignoring .work/ and anything already dirty and untouched.
  echo "FILES_CHANGED_DURING_RUN:"
  local any=0 line path
  while IFS= read -r line; do
    if [[ -z $line ]]; then continue; fi
    path="${line:3}"
    if [[ $path == *" -> "* ]]; then path="${path##* -> }"; fi
    path="${path#\"}"; path="${path%\"}"
    if [[ $path == .work/* ]]; then continue; fi
    if ! grep -qxF -- "$line" "$dir/before" || { [[ -e $path ]] && [[ $path -nt $dir/started ]]; }; then
      echo "  $line"
      any=1
    fi
  done < <(status_lines)
  if [[ $any -eq 0 ]]; then echo "  (none)"; fi

  echo "--- LOG TAIL (last $TAIL_LINES lines) ---"
  if [[ -f $dir/output.log ]]; then tail -n "$TAIL_LINES" "$dir/output.log"; else echo "(no log written)"; fi
}

wait_run() {
  local id="$1" dir deadline
  dir="$(run_dir_for "$id")"
  deadline=$(( $(now) + WAIT_MINUTES * 60 ))
  while [[ ! -f $dir/exit ]] && [[ $(now) -lt $deadline ]]; do
    if ! worker_alive "$dir"; then
      sleep 2   # let the worker finish writing its exit code
      break
    fi
    check_health "$dir"
    [[ -f $dir/exit ]] && break
    sleep "$POLL_SECONDS"
  done
  summary "$id"
}

stop_run() {
  local id="$1" reason="${2:-user}" dir wpid tree
  dir="$(run_dir_for "$id")"
  if worker_alive "$dir"; then
    wpid="$(cat "$dir/pid")"
    tree="$(descendants "$wpid")"   # collect the whole tree before anything is re-parented
    echo "$reason" > "$dir/stop_reason"
    echo stopped > "$dir/exit"
    kill -TERM "$wpid" 2>/dev/null || true
    if [[ -n $tree ]]; then kill -TERM $tree 2>/dev/null || true; fi
    sleep 1
  elif [[ ! -f $dir/exit ]]; then
    echo "$reason" > "$dir/stop_reason"
    echo stopped > "$dir/exit"
  fi
  summary "$id"
}

list_runs() {
  local d id status code
  printf '%-32s %-16s %-8s %s\n' RUN_ID AGENT STATUS ELAPSED_MIN
  for d in "$RUNS"/*/; do
    [[ -d $d ]] || continue
    d="${d%/}"; id="$(basename "$d")"
    if [[ -f $d/exit ]]; then
      code="$(cat "$d/exit")"
      case "$code" in 0) status=DONE ;; stopped) status=STOPPED ;; *) status=FAILED ;; esac
    elif worker_alive "$d"; then status=RUNNING; else status=FAILED; fi
    printf '%-32s %-16s %-8s %s\n' "$id" "$(cat "$d/agent" 2>/dev/null)" "$status" \
      "$(minutes_since "$(cat "$d/started_epoch" 2>/dev/null || now)")"
  done
}

cmd="${1:-}"
if [[ $# -gt 0 ]]; then shift; fi
case "$cmd" in
  # start returns at once: a governor that forgets to background the call loses seconds, not the
  # session (a foreground wait blocks it for up to WAIT_MINUTES and stopping it kills the agent).
  start)    if [[ $# -lt 2 ]]; then usage; fi; id="$(start_run "$@")"
            printf 'RUN_ID: %s\nSTATUS: STARTED\nNEXT: Started. Wait for it in the background (run_in_background: true): bash %s wait %s\n' "$id" "${SCRIPT#"$REPO_ROOT"/}" "$id" ;;
  wait)     if [[ $# -ne 1 ]]; then usage; fi; wait_run "$1" ;;
  status)   if [[ $# -ne 1 ]]; then usage; fi; d="$(run_dir_for "$1")"; check_health "$d"; summary "$1" ;;
  stop)     if [[ $# -ne 1 ]]; then usage; fi; stop_run "$1" user ;;
  list)     list_runs ;;
  __worker) worker "$1" ;;
  *)        usage ;;
esac
