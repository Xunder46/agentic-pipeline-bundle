#!/usr/bin/env bash
# The ONLY shell command Copilot agents may run (allowed by .github/copilot/permissions/common.flags).
#
#   .github/copilot/scripts/macos/gateway.sh list
#   .github/copilot/scripts/macos/gateway.sh <check> [args...]      checks: .github/copilot/gateway.conf
#   .github/copilot/scripts/macos/gateway.sh git-status
#   .github/copilot/scripts/macos/gateway.sh git-diff [<ref>] [--stat|--name-only|--name-status|--cached] [-- <path>...]
#   .github/copilot/scripts/macos/gateway.sh git-log [<count>] [<ref>]
#   .github/copilot/scripts/macos/gateway.sh git-show <ref> [--stat|--name-only|--name-status]
#   .github/copilot/scripts/macos/gateway.sh delete-scratch <path>   removes an untracked probe file
#
# Output: a check that prints more than SUMMARY_OVER lines or SUMMARY_BYTES bytes is saved whole under .work/gateway/ and
# shown as a summary (first lines, every line that looks like a failure, the last lines, and the
# path of the full log). Every model request re-sends the agent's whole context, so a 40 KB lint
# dump that the agent then re-reads in chunks costs far more than the check itself. A check with the
# `full-output` option in gateway.conf always prints everything.
#
# Why a gateway: Copilot's shell rules match a command and its first subcommand only, and some
# allowed-looking commands can read outside the repo (`cat ~/…`, `git diff --no-index ~/…`). This
# script runs a fixed menu, never through a shell, with every argument checked to stay inside the
# repository. Exit status: the check's own; 124 on timeout; 2 for a refused request.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "gateway: not inside a git repository" >&2; exit 2; }
cd "$ROOT"
CONF="$ROOT/.github/copilot/gateway.conf"
SUMMARY_OVER=200
SUMMARY_BYTES=16000   # long lines matter too: 196 lint notices are only ~200 lines but 37 KB
# Untracked files whose path starts with this may be removed with delete-scratch (set by the installer).
SCRATCH_PREFIX="{{SCRATCH_PREFIX}}"

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
  echo "Git views: git-status · git-diff [<ref>] [--stat|--name-only|--name-status|--cached] [-- <path>...] · git-log [<count>] [<ref>] · git-show <ref> [--stat|--name-only|--name-status]"
  echo "Cleanup: delete-scratch ${SCRATCH_PREFIX}<name> (an untracked probe file you created)"
  echo "Output over $SUMMARY_OVER lines or $((SUMMARY_BYTES / 1000)) KB is summarised; the full log path is printed (read it with your file tool)."
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
  local ref="$1" opt=""; shift
  check_ref "$ref"
  for a in "$@"; do case "$a" in --stat|--name-only|--name-status) opt="$a" ;; *) refuse "git-show option not allowed: $a" ;; esac; done
  if [[ -n $opt ]]; then exec git --no-pager show "$opt" "$ref"; fi
  exec git --no-pager show "$ref"
}

# Lets an agent remove its OWN probe file: only an untracked regular file under SCRATCH_PREFIX.
delete_scratch() {
  [[ $# -eq 1 ]] || refuse "delete-scratch takes exactly one path"
  local p="$1" name
  check_arg "$p"
  name="${p#"$SCRATCH_PREFIX"}"
  [[ $p == "$SCRATCH_PREFIX"* && -n $name && $name =~ ^[A-Za-z0-9_.-]+$ ]] \
    || refuse "delete-scratch only removes ${SCRATCH_PREFIX}<name> probe files: $p"
  if git ls-files --error-unmatch -- "$p" > /dev/null 2>&1; then refuse "delete-scratch will not remove a tracked file: $p"; fi
  [[ -f $p && ! -L $p ]] || refuse "no such file: $p"
  rm -- "$p"
  echo "gateway: removed $p" >&2
}

# Like run_with_timeout, but the output goes to a log under .work/gateway/ and is printed whole only
# when it is short; otherwise as a summary that points at the log.
run_summarized() {
  local name="$1" secs="$2"; shift 2
  local dir="$ROOT/.work/gateway" log
  mkdir -p "$dir"
  find "$dir" -name '*.log' -mtime +0 -delete 2> /dev/null || true
  log="$dir/$name-$(date +%Y%m%d-%H%M%S)-$$.log"
  exec perl -e '
    my ($secs, $log, $rel, $over, $bytes) = splice(@ARGV, 0, 5); $| = 1;
    my $pid = fork(); die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
      setpgrp(0, 0);
      open(STDOUT, ">", $log) or die "gateway: cannot write $log: $!\n"; open(STDERR, ">&STDOUT");
      exec { $ARGV[0] } @ARGV or do { print STDERR "gateway: cannot run $ARGV[0]: $!\n"; exit 127 } }
    my $timed_out = 0;
    $SIG{ALRM} = sub { $timed_out = 1; kill "TERM", -$pid; sleep 5; kill "KILL", -$pid };
    for my $s (qw(INT TERM HUP)) { $SIG{$s} = sub { kill $s, -$pid; waitpid($pid, 0); exit 130 } }
    alarm $secs; waitpid($pid, 0); my $st = $?; alarm 0;
    open(my $fh, "<", $log); my @l = <$fh>; close $fh;
    my $cut = sub { my $s = shift; chomp $s; length($s) > 300 ? substr($s, 0, 300) . " ..." : $s };
    my $size = 0; $size += length($_) for @l;
    if (@l <= $over && $size <= $bytes) { print $cut->($_), "\n" for @l }
    else {
      my $fail = qr/\b(error|errors|fail|failed|failure|failing|exception|panic|traceback|assert\w*|expected|actual|timed? ?out)\b|\[E\]|\xE2\x9C\x97/i;
      my @hits = grep { $l[$_] =~ $fail } 0 .. $#l;
      my $more = @hits > 120 ? @hits - 120 : 0; splice(@hits, 120) if $more;
      print "gateway: $ARGV[0] printed ", scalar(@l), " lines; full output: $rel\n";
      print "--- first 5 lines\n"; print $cut->($_), "\n" for @l[0 .. ($#l < 4 ? $#l : 4)];
      print "--- lines that look like failures (", scalar(@hits) + $more, ")", ($more ? ", first 120" : ""), "\n";
      printf "%6d: %s\n", $_ + 1, $cut->($l[$_]) for @hits;
      print "--- last 40 lines\n"; print $cut->($_), "\n" for @l[($#l < 39 ? 0 : $#l - 39) .. $#l];
      print "--- full output: $rel (read it with your file tool, by line range)\n";
    }
    if ($timed_out) { print STDERR "gateway: TIMEOUT after ${secs}s: @ARGV\n"; exit 124 }
    exit(($st & 127) ? 128 + ($st & 127) : ($st >> 8));
  ' "$secs" "$log" "${log#"$ROOT"/}" "$SUMMARY_OVER" "$SUMMARY_BYTES" "$@"
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
  if [[ $opts == *new-files-only* ]]; then
    for a in "$@"; do
      case "$a" in -*) continue ;; esac
      if git ls-files --error-unmatch -- "$a" > /dev/null 2>&1; then
        refuse "'$name' only runs on files this change created; '$a' is already tracked by git. Edit existing files with small edits instead"
      fi
    done
  fi
  local parts=()
  read -r -a parts <<< "$cmd"
  echo "gateway: $name (timeout ${secs}s): ${parts[*]} $*" >&2
  if [[ $opts == *full-output* ]]; then run_with_timeout "$secs" "${parts[@]}" "$@"; fi
  run_summarized "$name" "$secs" "${parts[@]}" "$@"
}

[[ $# -ge 1 ]] || { list_checks; exit 0; }
action="$1"; shift
case "$action" in
  list|-h|--help) list_checks ;;
  git-status) [[ $# -eq 0 ]] || refuse "git-status takes no arguments"; exec git --no-pager status --short --branch ;;
  git-diff) git_diff "$@" ;;
  git-log) git_log "$@" ;;
  git-show) git_show "$@" ;;
  delete-scratch) delete_scratch "$@" ;;
  *) run_check "$action" "$@" ;;
esac
