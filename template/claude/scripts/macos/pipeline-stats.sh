#!/usr/bin/env bash
# Economics of the Copilot runs in a time window, from .work/runs and git. For /retro and the
# /feature wrap-up: what the work cost, where the tokens went, and how much code it produced.
#
#   bash .claude/scripts/macos/pipeline-stats.sh [--since "YYYY-MM-DD HH:MM"] [--until "YYYY-MM-DD HH:MM"]
#
# Default window: the last 24 hours. Code produced = lines added + deleted in commits made in the
# window under STATS_PATHS (pipeline.env; ":"-separated, default the source and test roots), so
# uncommitted work is not counted. Run types come from the agent name and the brief's file name
# (a brief named *review*, *fix* or *plan*; everything else an implementer builds).
set -u   # not -e: a run log missing a section (no reads, no token line) must not end the report

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
since="" until=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) since="${2:-}"; shift 2 ;;
    --until) until="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n $since ]] || since="$(date -v-24H '+%Y-%m-%d %H:%M' 2>/dev/null || date -d '-24 hours' '+%Y-%m-%d %H:%M')"
[[ -n $until ]] || until="$(date '+%Y-%m-%d %H:%M')"
# RUN_IDs are YYYYMMDD-HHMMSS-<agent>: compare them as strings against the window.
to_id() { printf '%s' "$1" | sed -E 's/[^0-9]//g' | awk '{ s = $0 "000000000000"; printf "%s-%s", substr(s, 1, 8), substr(s, 9, 6) }'; }
from_id="$(to_id "$since")" to_id_="$(to_id "$until")"

STATS_PATHS=""
[[ -f .claude/pipeline.env ]] && STATS_PATHS="$(sed -n 's/^STATS_PATHS=//p' .claude/pipeline.env | tail -1 | tr -d '"')"
[[ -n $STATS_PATHS ]] || STATS_PATHS="{{SOURCE_ROOT}}:{{TEST_ROOT}}"
paths=()
IFS=':' read -r -a cand <<< "$STATS_PATHS"
for p in "${cand[@]}"; do [[ -n $p && -e $p ]] && paths+=("$p"); done
[[ ${#paths[@]} -gt 0 ]] || paths=(.)

runs="$(ls .work/runs 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}-' | awk -v f="$from_id" -v t="$to_id_" '$0 >= f && $0 < t' || true)"
if [[ -z $runs ]]; then echo "No runs between $since and $until."; exit 0; fi

for d in $runs; do
  r=.work/runs/$d; o=$r/output.log; [[ -f $o ]] || continue
  agent="$(cat "$r/agent" 2>/dev/null || echo ?)"
  brief="$(basename "$(cat "$r/prompt_file" 2>/dev/null || echo -)")"
  kind=build
  case "$agent" in conductor|conductor-v2) kind=plan ;; code-reviewer) kind=review ;; esac
  case "$brief" in *review*) kind=review ;; *fix*) kind=fix ;; *plan*) kind=plan ;; esac
  req=$(grep -c ' -> ' "$r/proxy.log" 2>/dev/null || true); req=${req:-0}
  calls=$(grep -a -c -E '^(●|✗|/ )' "$o" || true)
  [[ -f $r/started_epoch ]] || continue
  min=$(awk -v s="$(cat "$r/started_epoch")" -v e="$(stat -f %m "$o" 2>/dev/null || stat -c %Y "$o")" 'BEGIN { printf "%.1f", (e - s) / 60 }')
  impl=0; case "$agent" in conductor|conductor-v2|code-reviewer) ;; *) impl=1 ;; esac
  first=-1
  if [[ $impl == 1 && $calls -ge 10 ]]; then
    n=$(grep -a -E '^(●|✗|/ )' "$o" | grep -n -E '^● (Edit|Create)' | head -1 | cut -d: -f1 || true)
    [[ -n $n ]] || n=$calls
    first=$(awk -v f="$n" -v t="$calls" -v m="$min" 'BEGIN { printf "%.1f", m * f / t }')
  fi
  topread=$( { grep -a -A1 -E '^● Read ' "$o" || true; } | { grep -a -E '^  │ ' || true; } | sort | uniq -c | sort -rn | head -1 | awk '{ print $1 + 0 }')
  tok="$(grep -a -E '^Tokens' "$o" | tail -1 || true)"
  echo "$kind|$impl|$req|$calls|$min|$first|${topread:-0}|$(cat "$r/stop_reason" 2>/dev/null || echo -)|$tok"
done > "${TMPDIR:-/tmp}/pipeline-stats.$$"

changed="$(git log --since="$since" --until="$until" --format=%h -- "${paths[@]}" | while read -r h; do
  git show --shortstat --format= "$h" -- "${paths[@]}" | tail -1; done \
  | awk '{ for (i = 1; i <= NF; i++) if ($(i) ~ /^(insertion|deletion)/) n += $(i - 1) } END { print n + 0 }')"
commits="$(git log --since="$since" --until="$until" --format=%h | wc -l | tr -d ' ')"

CHANGED="$changed" COMMITS="$commits" SINCE="$since" UNTIL="$until" perl -F'\|' -lane '
  sub n { my ($v, $u) = @_; $u eq "m" ? $v * 1e6 : $u eq "k" ? $v * 1e3 : $v }
  my ($kind, $impl, $req, $calls, $min, $first, $tr, $stop, $tok) = @F;
  $N++; $R += $req; $M += $min; push @reqs, $req; $stops{$stop}++ if $stop ne "-";
  if ($tok =~ /↑ ([\d.]+)([mk]?) \(([\d.]+)([mk]?) cached\) • ↓ ([\d.]+)([mk]?)/) {
    my $in = n($1, $2); $I += $in; $C += n($3, $4); $O += n($5, $6); $K{$kind} += $in; $NT++;
    $long++ , $LT += $in if $impl && $min >= 45;
  } else { $missing++ }
  if ($impl && $first >= 0) { push @f, $first; push @t, $tr; $slow++ if $first >= 15 }
  END {
    my $med = sub { my @a = sort { $a <=> $b } @_; @a ? $a[int($#a / 2)] : 0 };
    my $avg = sub { my $x = 0; $x += $_ for @_; @_ ? $x / @_ : 0 };
    my $lines = $ENV{CHANGED} || 0;
    printf "Window: %s -> %s\n", $ENV{SINCE}, $ENV{UNTIL};
    printf "Runs: %d (%d without a token total) · agent time %.0f min · model requests %d (median %d per run)\n", $N, $missing, $M, $R, $med->(@reqs);
    printf "Input tokens: %.1fM (%.0f%% cache reads) · output %.2fM · %.0fk per request\n", $I / 1e6, $I ? 100 * $C / $I : 0, $O / 1e6, $R ? $I / $R / 1e3 : 0;
    printf "Code produced: %d lines changed in %d commits · %s\n", $lines, $ENV{COMMITS}, $lines ? sprintf("%.1fk input tokens per changed line", $I / $lines / 1e3) : "no committed code in the window";
    printf "Where the tokens went: %s\n", join(" · ", map { sprintf "%s %.0f%%", $_, $I ? 100 * $K{$_} / $I : 0 } sort { $K{$b} <=> $K{$a} } keys %K);
    printf "Implementers: first edit median %.1f min (%d of %d runs read 15+ min first) · most re-read file %.1f reads on average · runs of 45+ min: %d (%.0f%% of tokens)\n",
      $med->(@f), $slow, scalar(@f), $avg->(@t), $long, $I ? 100 * $LT / $I : 0;
    printf "Automatic stops: %s\n", (join(", ", map { "$_ $stops{$_}" } sort keys %stops) || "none");
  }' < "${TMPDIR:-/tmp}/pipeline-stats.$$"
rm -f "${TMPDIR:-/tmp}/pipeline-stats.$$"
