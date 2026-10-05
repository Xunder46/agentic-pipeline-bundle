#!/usr/bin/env bash
# Portable command timeout for agents and the governor (macOS ships no `timeout`).
#
#   bash .claude/scripts/macos/with-timeout.sh <seconds> <command> [args...]
#
# Runs the command in its own process group, so a timeout also ends the children it spawned
# (test runners, compilers, code generators). Exit status: the command's own, or 124 on timeout
# (the same convention as GNU timeout), with a one-line TIMEOUT message on stderr.
set -euo pipefail

if [[ $# -lt 2 ]] || ! [[ $1 =~ ^[0-9]+$ ]]; then
  echo "usage: with-timeout.sh <seconds> <command> [args...]" >&2
  exit 2
fi

exec perl -e '
  my $secs = shift @ARGV;
  my $pid = fork();
  die "with-timeout: fork failed: $!\n" unless defined $pid;
  if ($pid == 0) {
    setpgrp(0, 0);
    exec { $ARGV[0] } @ARGV or do { print STDERR "with-timeout: cannot run $ARGV[0]: $!\n"; exit 127 };
  }
  $SIG{ALRM} = sub {
    kill "TERM", -$pid;
    sleep 5;
    kill "KILL", -$pid;
    waitpid($pid, 0);
    print STDERR "with-timeout: TIMEOUT after ${secs}s: @ARGV\n";
    exit 124;
  };
  for my $sig (qw(INT TERM HUP)) {
    $SIG{$sig} = sub { kill $sig, -$pid; waitpid($pid, 0); exit 130 };
  }
  alarm $secs;
  waitpid($pid, 0);
  my $st = $?;
  exit(($st & 127) ? 128 + ($st & 127) : ($st >> 8));
' "$@"
