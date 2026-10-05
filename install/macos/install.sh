#!/usr/bin/env bash
# Installs (or updates) the agentic pipeline into a target git repository — macOS / Linux.
# (Windows: install/windows/install.ps1, same options.)
#
#   bash install/macos/install.sh --config <file> <target-repo> [--only github] [--force] [--dry-run]
#
# --config       a filled-in copy of pipeline.config.example
# --only github  install only the GitHub Copilot part (.github/agents, .github/copilot) — e.g. to add
#                Copilot agents to a repo that already has its .claude/ pipeline
# --force        overwrite pipeline files that differ from the bundle. Never touches your
#                conventions doc, docs index, plans or .work/.
# --dry-run      show what would be written, change nothing
#
# It stages the template, resolves every {{PLACEHOLDER}} from the config, refuses to continue if any
# placeholder is left, then copies into the target. Existing settings.json, AGENTS.md and CLAUDE.md
# are merged, not replaced. Needs bash, perl and git; python3 (optional) merges settings.json.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "$HERE/../.." && pwd)"
TEMPLATE="$BUNDLE/template"
VERSION="$(cat "$BUNDLE/VERSION" 2>/dev/null || echo unknown)"
CONFIG="" TARGET="" FORCE=0 DRY=0 ONLY=""

die() { echo "install: $*" >&2; exit 1; }
say() { echo "  $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 ;;
    --only) ONLY="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) [[ -z $TARGET ]] || die "unexpected argument: $1"; TARGET="$1"; shift ;;
  esac
done
[[ -n $CONFIG && -n $TARGET ]] || die "usage: install.sh --config <file> <target-repo> [--only github] [--force] [--dry-run]"
case "$ONLY" in ""|github) ;; *) die "--only accepts: github" ;; esac
[[ -f $CONFIG ]] || die "config not found: $CONFIG"
[[ -d $TARGET ]] || die "target not found: $TARGET"
TARGET="$(cd "$TARGET" && git rev-parse --show-toplevel 2>/dev/null)" || die "target is not inside a git repository"
command -v perl >/dev/null || die "perl is required"

# ---- Load and validate the config ----------------------------------------------------------------
# shellcheck disable=SC1090
source "$CONFIG"
for k in PROJECT_NAME STACK BASE_BRANCH LINT_CMD TEST_CMD PLANS_ROOT CONVENTIONS_DOC PLANNER_AGENT; do
  eval "v=\${$k-}"
  [[ -n $v ]] || die "$k is required in $CONFIG"
done
case "$PLANNER_AGENT" in conductor|conductor-v2) ;; *) die "PLANNER_AGENT must be conductor or conductor-v2" ;; esac
: "${PLATFORM:=macos}"
case "$PLATFORM" in macos|windows) ;; *) die "PLATFORM must be macos or windows" ;; esac
PLANS_ROOT="${PLANS_ROOT%/}"
: "${DOCS_ROOT:=docs/architecture/}"
: "${DOCS_INDEX:=${DOCS_ROOT%/}/README.md}"
: "${LONG_CMD_TIMEOUT:=300}" "${TEST_TIMEOUT:=900}" "${MAX_AGENT_MINUTES:=90}"
: "${WAIT_MINUTES:=15}" "${MAX_RUN_MINUTES:=120}" "${STALL_MINUTES:=30}" "${REPEAT_STOP:=40}"
: "${COPILOT_WRAPPER=}" "${GATEWAY_EXTRA=}"
for k in LONG_CMD_TIMEOUT TEST_TIMEOUT MAX_AGENT_MINUTES WAIT_MINUTES MAX_RUN_MINUTES STALL_MINUTES REPEAT_STOP; do
  eval "v=\${$k}"
  [[ $v =~ ^[0-9]+$ ]] || die "$k must be a whole number (got '$v')"
done

# Platform-specific commands.
if [[ $PLATFORM == macos ]]; then
  RUNNER="bash .claude/scripts/macos/run-agent.sh"
  TIMEOUT_WRAPPER="bash .claude/scripts/macos/with-timeout.sh"
  GATEWAY=".github/copilot/scripts/macos/gateway.sh"
  case "$COPILOT_WRAPPER" in ""|with-opencode.sh) ;; with-opencode.ps1) COPILOT_WRAPPER=with-opencode.sh ;; *) die "COPILOT_WRAPPER must be empty or with-opencode.sh" ;; esac
else
  RUNNER="pwsh -NoProfile -File .claude/scripts/windows/run-agent.ps1"
  TIMEOUT_WRAPPER="pwsh -NoProfile -File .claude/scripts/windows/with-timeout.ps1"
  GATEWAY=".github/copilot/scripts/windows/gateway.ps1"
  case "$COPILOT_WRAPPER" in ""|with-opencode.ps1) ;; with-opencode.sh) COPILOT_WRAPPER=with-opencode.ps1 ;; *) die "COPILOT_WRAPPER must be empty or with-opencode.ps1" ;; esac
fi
PLANS_GLOB="$PLANS_ROOT/**"
DOCS_GLOB="${DOCS_ROOT%/}/**"
# Probe files an agent may remove with `gateway delete-scratch`: untracked <test root>/zz_<name>.
if [[ -n ${TEST_ROOT-} ]]; then SCRATCH_PREFIX="${TEST_ROOT%/}/zz_"; else SCRATCH_PREFIX="zz_"; fi
PLANNER_MODEL_RAW="${PLANNER_MODEL-}" DEVELOPER_MODEL_RAW="${DEVELOPER_MODEL-}" REVIEWER_MODEL_RAW="${REVIEWER_MODEL-}"

# The gateway's checks: lint/typecheck/test/build from the config, then GATEWAY_EXTRA
# ("name|seconds|command[|options]" entries separated by ';'). An extra entry replaces a default
# of the same name.
GATEWAY_ENTRIES=""
gw_add() { GATEWAY_ENTRIES="${GATEWAY_ENTRIES}$1"$'\n'; }
extra_names=" "
IFS=';' read -r -a extras <<< "$GATEWAY_EXTRA"
for e in ${extras[@]+"${extras[@]}"}; do
  e="$(printf '%s' "$e" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n $e ]] || continue
  n="$(printf '%s' "$e" | cut -d'|' -f1 | tr -d ' ')"; t="$(printf '%s' "$e" | cut -d'|' -f2 | tr -d ' ')"
  c="$(printf '%s' "$e" | cut -d'|' -f3)"
  [[ $n =~ ^[a-z][a-z0-9-]*$ && $t =~ ^[0-9]+$ && -n ${c// /} ]] || die "bad GATEWAY_EXTRA entry '$e' (expected name|seconds|command[|options])"
  case "$n" in list|git-*) die "GATEWAY_EXTRA name '$n' is reserved" ;; esac
  extra_names="$extra_names$n "
done
for pair in "lint|$LONG_CMD_TIMEOUT|${LINT_CMD-}" "typecheck|$LONG_CMD_TIMEOUT|${TYPECHECK_CMD-}" "test|$TEST_TIMEOUT|${TEST_CMD-}" "build|$LONG_CMD_TIMEOUT|${BUILD_CMD-}"; do
  n="${pair%%|*}"; c="${pair#*|*|}"
  [[ -n $c ]] || continue
  [[ $extra_names == *" $n "* ]] && continue
  gw_add "$(printf '%-10s | %-4s | %s' "$n" "$(echo "$pair" | cut -d'|' -f2)" "$c")"
done
for e in ${extras[@]+"${extras[@]}"}; do
  e="$(printf '%s' "$e" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -n $e ]] && gw_add "$e"
done
GATEWAY_ENTRIES="${GATEWAY_ENTRIES%$'\n'}"

# What an empty value becomes. Runner knobs stay empty; everything else is spelled out so no rule
# silently points at nothing.
empty_text() {
  case "$1" in
    COPILOT_WRAPPER|*_MODEL_RAW) echo "" ;;
    INVARIANT_CHECKS) echo "none configured yet — add them to pipeline.config and re-run the installer" ;;
    *) echo "(not used in this project)" ;;
  esac
}

# ---- Stage the files -----------------------------------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
OTHER_PLANNER=conductor; [[ $PLANNER_AGENT == conductor ]] && OTHER_PLANNER=conductor-v2

# GitHub Copilot part.
mkdir -p "$STAGE/.github/copilot/scripts"
cp -R "$TEMPLATE/github/agents" "$STAGE/.github/"
cp -R "$TEMPLATE/github/copilot/permissions" "$STAGE/.github/copilot/"
cp "$TEMPLATE/github/copilot/gateway.conf" "$TEMPLATE/github/copilot/pr-scope-budget.md" "$STAGE/.github/copilot/"
cp -R "$TEMPLATE/github/copilot/scripts/$PLATFORM" "$STAGE/.github/copilot/scripts/"
rm -f "$STAGE/.github/agents/$OTHER_PLANNER.agent.md" "$STAGE/.github/copilot/permissions/$OTHER_PLANNER.flags"

# Claude Code part.
if [[ -z $ONLY ]]; then
  mkdir -p "$STAGE/.claude/scripts"
  cp -R "$TEMPLATE/claude/agents" "$TEMPLATE/claude/commands" "$TEMPLATE/claude/skills" "$STAGE/.claude/"
  cp -R "$TEMPLATE/claude/scripts/$PLATFORM" "$TEMPLATE/claude/scripts/common" "$STAGE/.claude/scripts/"
  cp "$TEMPLATE/claude/pipeline.env" "$TEMPLATE/claude/settings.json" "$STAGE/.claude/"
  rm -f "$STAGE/.claude/agents/$OTHER_PLANNER.md"
  cp "$TEMPLATE/AGENTS.pipeline.md" "$STAGE/AGENTS.pipeline.md"
  mkdir -p "$STAGE/docs"
  cp "$TEMPLATE/docs/conventions.md" "$STAGE/docs/conventions.md"
  cp "$TEMPLATE/docs/architecture-index.md" "$STAGE/docs/architecture-index.md"
fi

# Resolve placeholders: every {{KEY}} found in the staged files, from the config (or empty_text).
keys="$(grep -rhoE '\{\{[A-Z_]+\}\}' "$STAGE" | tr -d '{}' | sort -u)"
unused=""
for k in $keys; do
  eval "v=\${$k-}"
  if [[ -z $v ]]; then
    v="$(empty_text "$k")"
    case "$k" in COPILOT_WRAPPER|*_MODEL_RAW) ;; *) unused="$unused $k" ;; esac
  fi
  export "PL_$k=$v"
done
while IFS= read -r -d '' f; do
  perl -pi -e 's/\{\{([A-Z_]+)\}\}/exists $ENV{"PL_$1"} ? $ENV{"PL_$1"} : $&/ge' "$f"
done < <(find "$STAGE" -type f -print0)
left="$(grep -rnE '\{\{[A-Z_]+\}\}' "$STAGE" || true)"
[[ -z $left ]] || die "unresolved placeholders remain:
$left"
if [[ -f $STAGE/.claude/settings.json ]] && command -v python3 >/dev/null; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$STAGE/.claude/settings.json" \
    || die "settings.json is not valid JSON after substitution (a command in the config contains a double quote?)"
fi
find "$STAGE" -name '*.sh' -exec chmod +x {} +

# ---- Plan the copy -------------------------------------------------------------------------------
cd "$TARGET"
conflicts="" writes=""
while IFS= read -r -d '' f; do
  rel="${f#"$STAGE"/}"
  case "$rel" in AGENTS.pipeline.md|docs/*|.claude/settings.json) continue ;; esac
  if [[ -f $rel ]] && ! cmp -s "$f" "$rel"; then conflicts="$conflicts
    $rel"; fi
  writes="$writes $rel"
done < <(find "$STAGE" -type f -print0)
if [[ -n $conflicts && $FORCE -eq 0 ]]; then
  die "these files exist and differ from the bundle (re-run with --force to overwrite):$conflicts"
fi

echo "Installing agentic pipeline $VERSION ($PLATFORM${ONLY:+, only $ONLY}) into $TARGET"
if [[ $DRY -eq 1 ]]; then
  echo "(dry run — nothing written)"
  for rel in $writes; do say "write $rel"; done
  if [[ -z $ONLY ]]; then
    say "merge .claude/settings.json · AGENTS.md block · CLAUDE.md import"
    [[ -f $CONVENTIONS_DOC ]] || say "create $CONVENTIONS_DOC (skeleton)"
    [[ -f $DOCS_INDEX ]] || say "create $DOCS_INDEX (skeleton)"
  fi
  exit 0
fi

# ---- Copy ----------------------------------------------------------------------------------------
for rel in $writes; do
  mkdir -p "$(dirname "$rel")"
  cp -p "$STAGE/$rel" "$rel"
done
say "Copilot agents, permission profiles and gateway → .github/ (planner: $PLANNER_AGENT)"
[[ -n $ONLY ]] || say "Claude agents, commands, skills, scripts and pipeline.env → .claude/"

if [[ -z $ONLY ]]; then
  # settings.json: write, or merge (union of allow/deny; existing env values win).
  if [[ ! -f .claude/settings.json ]]; then
    cp "$STAGE/.claude/settings.json" .claude/settings.json
    say "created .claude/settings.json"
  elif command -v python3 >/dev/null; then
    python3 - "$STAGE/.claude/settings.json" .claude/settings.json <<'PY'
import json, sys
new = json.load(open(sys.argv[1])); path = sys.argv[2]; cur = json.load(open(path))
for k, v in new.get("env", {}).items():
    cur.setdefault("env", {}).setdefault(k, v)
perms = cur.setdefault("permissions", {})
for key in ("allow", "deny"):
    have = perms.setdefault(key, [])
    for rule in new["permissions"].get(key, []):
        if rule not in have:
            have.append(rule)
json.dump(cur, open(path, "w"), indent=2); open(path, "a").write("\n")
PY
    say "merged permissions into existing .claude/settings.json"
  else
    cp "$STAGE/.claude/settings.json" .claude/settings.pipeline.json
    say "python3 not found: wrote .claude/settings.pipeline.json — merge it into settings.json by hand"
  fi

  # AGENTS.md: replace the managed block, or append it.
  BEGIN='<!-- agentic-pipeline:begin — managed by the installer; change pipeline.config and re-run -->'
  block="$(printf '%s\n%s\n%s\n' "$BEGIN" "$(cat "$STAGE/AGENTS.pipeline.md")" '<!-- agentic-pipeline:end -->')"
  if [[ -f AGENTS.md ]] && grep -qF 'agentic-pipeline:begin' AGENTS.md; then
    BLOCK="$block" perl -0pi -e 's/<!-- agentic-pipeline:begin.*?<!-- agentic-pipeline:end -->\n?/$ENV{BLOCK}\n/s' AGENTS.md
    say "updated the pipeline block in AGENTS.md"
  elif [[ -f AGENTS.md ]]; then
    printf '\n%s\n' "$block" >> AGENTS.md
    say "appended the pipeline block to AGENTS.md"
  else
    printf '# %s\n\n%s\n' "$PROJECT_NAME" "$block" > AGENTS.md
    say "created AGENTS.md"
  fi
  # Your own notes, outside the managed block, added once and never rewritten.
  if ! grep -qF '## Known long-running or hanging commands' AGENTS.md; then
    cat >> AGENTS.md <<'NOTES'

## Known long-running or hanging commands

<!-- Yours to edit; the installer never rewrites this section. List commands that run long or have
     hung, the timeout to use, and the known cause. For Copilot agents, add such commands as gateway
     checks (GATEWAY_EXTRA in pipeline.config) with a timeout. -->
NOTES
    say "added the 'Known long-running or hanging commands' section to AGENTS.md (yours to edit)"
  fi

  # CLAUDE.md imports AGENTS.md so both tools read one source.
  if [[ -f CLAUDE.md ]]; then
    if ! grep -qE '^@AGENTS\.md[[:space:]]*$' CLAUDE.md; then
      printf '\n@AGENTS.md\n' >> CLAUDE.md
      say "added '@AGENTS.md' import to CLAUDE.md"
    fi
  else
    printf '# %s\n\n@AGENTS.md\n' "$PROJECT_NAME" > CLAUDE.md
    say "created CLAUDE.md (imports AGENTS.md)"
  fi

  # Docs skeletons, only when absent.
  if [[ ! -f $CONVENTIONS_DOC ]]; then
    mkdir -p "$(dirname "$CONVENTIONS_DOC")"; cp "$STAGE/docs/conventions.md" "$CONVENTIONS_DOC"
    say "created $CONVENTIONS_DOC (skeleton — fill it in before the first run)"
  fi
  if [[ ! -f $DOCS_INDEX ]]; then
    mkdir -p "$(dirname "$DOCS_INDEX")"; cp "$STAGE/docs/architecture-index.md" "$DOCS_INDEX"
    say "created $DOCS_INDEX (skeleton)"
  fi
  printf 'agentic-pipeline %s (%s) installed %s from %s\n' "$VERSION" "$PLATFORM" "$(date +%Y-%m-%d)" "$(basename "$CONFIG")" > .claude/pipeline.version
fi

mkdir -p "$PLANS_ROOT"
[[ -n "$(ls -A "$PLANS_ROOT" 2>/dev/null)" ]] || touch "$PLANS_ROOT/.gitkeep"

# .work/ is scratch: briefs, run logs, friction log. Never committed.
touch .gitignore
grep -qxE '/?\.work/?' .gitignore || { printf '\n# agentic pipeline scratch (briefs, run logs)\n.work/\n' >> .gitignore; say "added .work/ to .gitignore"; }
mkdir -p .work
[[ -f .work/friction.md ]] || printf '# Friction log\n\n' > .work/friction.md

# A README in .claude/agents/ or .github/agents/ makes Copilot CLI log a malformed-agent error.
for d in .claude/agents .github/agents; do
  [[ -f $d/README.md ]] && say "WARNING: $d/README.md exists — Copilot CLI treats it as a malformed agent; move it out"
done

echo
echo "Done. Next:"
if [[ -z $ONLY ]]; then
  echo "  1. Fill in $CONVENTIONS_DOC and the 'Known long-running or hanging commands' section of AGENTS.md."
  echo "  2. Set up the Copilot model provider (README §3) and run the smoke test (README §5)."
  echo "  3. Review and commit: git add .claude .github AGENTS.md CLAUDE.md .gitignore $CONVENTIONS_DOC $DOCS_INDEX $PLANS_ROOT"
else
  echo "  1. Point your runner at .github/copilot/permissions/ (the bundle's runner does) and remove --allow-all-tools."
  echo "  2. Review and commit: git add .github"
fi
echo "  Gateway checks for Copilot agents: $GATEWAY list"
if [[ -n $unused ]]; then
  echo
  echo "Marked '(not used in this project)':$unused"
  echo "  Agents skip rules about these. If one does exist in your project, set it in the config and re-run."
fi
