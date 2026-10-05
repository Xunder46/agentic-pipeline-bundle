#!/usr/bin/env bash
# The ONLY shell command Copilot agents may run (allowed by .github/copilot/permissions/common.flags).
#
#   .github/copilot/scripts/macos/gateway.sh list
#   .github/copilot/scripts/macos/gateway.sh <check> [args...]      checks: .github/copilot/gateway.conf
#   .github/copilot/scripts/macos/gateway.sh git-status
#   .github/copilot/scripts/macos/gateway.sh git-diff [<ref>] [--stat|--name-only|--name-status|--cached] [-- <path>...]
#   .github/copilot/scripts/macos/gateway.sh git-log [<count>] [<ref>]
#   .github/copilot/scripts/macos/gateway.sh git-show <ref> [--stat]
#
# Why a gateway: Copilot's shell rules match a command and its first subcommand only, and some
# allowed-looking commands can read outside the repo (`cat ~/…`, `git diff --no-index ~/…`). This
# script runs a fixed menu, never through a shell, with every argument checked to stay inside the
# repository. Exit status: the check's own; 124 on timeout; 2 for a refused request.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "gateway: not inside a git repository" >&2; exit 2; }
cd "$ROOT"
CONF="$ROOT/.github/copilot/gateway.conf"

refuse() { echo "gateway: refused: $*" >&2; exit 2; }

# An argument may be a flag or a repo-relative path, never a way out of the repository.
check_arg() {
  local a="$1"
  case "$a" in
    /*|"~"*|\\*) refuse "absolute or home path: $a" ;;
    *=/*|*="~"*|*:/*) refuse "absolute or home path in option: $a" ;;
    ..|../*|*/..|*/../*|*=..*) refuse "parent-directory path: $a" ;;
  esac
  case "$a" in *$'\n'*|*$'\r'*) refuse "control characters in argument" ;; esac
  return 0
}

check_ref() {
  local r="$1"
  case "$r" in -*) refuse "a ref cannot start with '-': $r" ;; esac
  git rev-parse --verify --quiet "${r}^{commit}" > /dev/null || refuse "not a commit in this repository: $r"
}

# Run "$@" in its own process group with a timeout; exit 124 on timeout (same as with-timeout.sh).
run_with_timeout() {
  local secs="$1"; shift
  exec perl -e '
    my $secs = shift @ARGV;
    my $pid = fork(); die "fork: $!\n" unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or do { print STDERR "gateway: cannot run $ARGV[0]: $!\n"; exit 127 } }
    $SIG{ALRM} = sub { kill "TERM", -$pid; sleep 5; kill "KILL", -$pid; waitpid($pid, 0);
                       print STDERR "gateway: TIMEOUT after ${secs}s: @ARGV\n"; exit 124 };
    for my $s (qw(INT TERM HUP)) { $SIG{$s} = sub { kill $s, -$pid; waitpid($pid, 0); exit 130 } }
    alarm $secs; waitpid($pid, 0); my $st = $?;
    exit(($st & 127) ? 128 + ($st & 127) : ($st >> 8));
  ' "$secs" "$@"
}

conf_entries() {
  [[ -f $CONF ]] || refuse "missing $CONF"
  grep -vE '^[[:space:]]*(#|$)' "$CONF" || true
}

list_checks() {
  echo "Checks (gateway.conf):"
  conf_entries | awk -F'|' '{ gsub(/^ +| +$/, "", $1); gsub(/^ +| +$/, "", $2); gsub(/^ +| +$/, "", $3); gsub(/^ +| +$/, "", $4)
    printf "  %-14s %5ss  %s%s\n", $1, $2, $3, ($4 == "" ? "" : "  [" $4 "]") }'
  echo "Git views: git-status · git-diff [<ref>] [--stat|--name-only|--name-status|--cached] [-- <path>...] · git-log [<count>] [<ref>] · git-show <ref> [--stat]"
}

git_diff() {
  local opts=() ref="" paths=() seen_dashdash=0 a
  for a in "$@"; do
    if [[ $seen_dashdash -eq 1 ]]; then check_arg "$a"; paths+=("$a"); continue; fi
    case "$a" in
      --) seen_dashdash=1 ;;
      --stat|--name-only|--name-status|--cached|--staged) opts+=("$a") ;;
      -*) refuse "git-diff option not allowed: $a" ;;
      *) [[ -z $ref ]] || refuse "git-diff takes at most one ref"; check_ref "$a"; ref="$a" ;;
    esac
  done
  local cmd=(git --no-pager diff)
  if [[ ${#opts[@]} -gt 0 ]]; then cmd+=("${opts[@]}"); fi
  if [[ -n $ref ]]; then cmd+=("$ref"); fi
  cmd+=(--)
  if [[ ${#paths[@]} -gt 0 ]]; then cmd+=("${paths[@]}"); fi
  exec "${cmd[@]}"
}

git_log() {
  local count=20 ref="" a
  for a in "$@"; do
    if [[ $a =~ ^[0-9]+$ ]]; then count="$a"; [[ $count -le 500 ]] || refuse "git-log count above 500"
    else check_ref "$a"; ref="$a"; fi
  done
  if [[ -n $ref ]]; then exec git --no-pager log --oneline -n "$count" "$ref"; fi
  exec git --no-pager log --oneline -n "$count"
}

git_show() {
  [[ $# -ge 1 ]] || refuse "git-show needs a ref"
  local ref="$1" stat=(); shift
  check_ref "$ref"
  for a in "$@"; do case "$a" in --stat) stat=(--stat) ;; *) refuse "git-show option not allowed: $a" ;; esac; done
  if [[ ${#stat[@]} -gt 0 ]]; then exec git --no-pager show --stat "$ref"; fi
  exec git --no-pager show "$ref"
}

run_check() {
  local name="$1"; shift
  local line
  line="$(conf_entries | awk -F'|' -v n="$name" '{ k = $1; gsub(/^ +| +$/, "", k); if (k == n) { print; exit } }')"
  [[ -n $line ]] || { echo "gateway: unknown check '$name'." >&2; list_checks >&2; exit 2; }
  local secs cmd opts
  secs="$(echo "$line" | awk -F'|' '{ gsub(/ /, "", $2); print $2 }')"
  cmd="$(echo "$line" | awk -F'|' '{ gsub(/^ +| +$/, "", $3); print $3 }')"
  opts="$(echo "$line" | awk -F'|' '{ gsub(/^ +| +$/, "", $4); print $4 }')"
  [[ $secs =~ ^[0-9]+$ ]] || refuse "bad timeout for '$name' in gateway.conf"
  [[ -n $cmd ]] || refuse "no command for '$name' in gateway.conf"
  local a
  for a in "$@"; do check_arg "$a"; done
  if [[ $opts == *requires-args* && $# -eq 0 ]]; then
    refuse "'$name' needs explicit file arguments (it must never run on the whole tree)"
  fi
  local parts=()
  read -r -a parts <<< "$cmd"
  echo "gateway: $name (timeout ${secs}s): ${parts[*]} $*" >&2
  run_with_timeout "$secs" "${parts[@]}" "$@"
}

[[ $# -ge 1 ]] || { list_checks; exit 0; }
action="$1"; shift
case "$action" in
  list|-h|--help) list_checks ;;
  git-status) [[ $# -eq 0 ]] || refuse "git-status takes no arguments"; exec git --no-pager status --short --branch ;;
  git-diff) git_diff "$@" ;;
  git-log) git_log "$@" ;;
  git-show) git_show "$@" ;;
  *) run_check "$action" "$@" ;;
esac
