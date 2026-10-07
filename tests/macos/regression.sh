#!/usr/bin/env bash
# Regression test for the macOS gateway and runner: installs the bundle into a throwaway git repo and
# checks every guard (output summaries, exit codes, timeouts, formatter and deletion guards, prove-red,
# the runner's loop / denied / filler / no_write stops, LONG_RUN, and rules injection).
#   bash tests/macos/regression.sh          (from the bundle root; needs bash, perl, git)
# Run it after any change to install/, template/claude/scripts/ or template/github/copilot/.
set -u
B="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$(mktemp -d)"
trap 'for p in $(cat "$S"/.work/runs/*/pid 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -rf "$S"' EXIT
pass=0; fail=0
ok() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1 (expected '$3', got '$2')"; fi; }
cd "$S" || exit 1
git init -q && git commit -q --allow-empty -m init
cat > cfg <<'EOF'
PROJECT_NAME="Regr"
STACK="bash"
BASE_BRANCH="main"
LINT_CMD="./lint.sh"
TEST_CMD="./runtests.sh"
PLANS_ROOT="docs/plans"
CONVENTIONS_DOC="docs/conventions.md"
PLANNER_AGENT="conductor-v2"
PLATFORM="macos"
TEST_ROOT="tests/"
GATEWAY_EXTRA="slow|2|./slow.sh; full|30|./noisy.sh|full-output; fmt|30|./ok.sh|requires-args new-files-only; del|30|./del.sh; base-setup|30|./setup.sh"
EOF
bash "$B/install/macos/install.sh" --config cfg . > /dev/null 2>&1 || { echo "install failed"; exit 1; }
printf '.work/\n.setup-done\n' >> .gitignore
mkdir -p lib tests
echo bug > lib/x.txt; echo keep > lib/a.txt
cat > runtests.sh <<'EOF'
#!/bin/bash
[[ -f .setup-done ]] || { echo "setup missing"; exit 9; }
rc=0; for t in "$@"; do bash "$t" && echo "PASS $t" || { echo "FAIL $t"; rc=1; }; done; exit $rc
EOF
printf '#!/bin/bash\nfor i in $(seq 300); do echo "info line $i"; done; echo "error: boom"; exit 1\n' > lint.sh
printf '#!/bin/bash\nfor i in $(seq 300); do echo "noise $i"; done; exit 0\n' > noisy.sh
printf '#!/bin/bash\nsleep 30\n' > slow.sh
printf '#!/bin/bash\nexit 0\n' > ok.sh
printf '#!/bin/bash\nrm -f lib/a.txt; exit 0\n' > del.sh
printf '#!/bin/bash\ntouch .setup-done\n' > setup.sh
chmod +x ./*.sh
git add -A > /dev/null && git -c user.email=a@b -c user.name=t commit -qm base
touch .setup-done
GW=.github/copilot/scripts/macos/gateway.sh
R=".claude/scripts/macos/run-agent.sh"

echo "gateway"
out=$($GW lint 2>/dev/null); code=$?
ok "long output is summarised" "$(echo "$out" | grep -c 'full output:')" "2"
ok "summary keeps the failure line" "$(echo "$out" | grep -c 'error: boom')" "2"
ok "check exit code preserved" "$code" "1"
ok "full-output prints everything" "$($GW full 2>/dev/null | wc -l | tr -d ' ')" "300"
$GW slow > /dev/null 2>&1; ok "timeout exits 124" "$?" "124"
$GW fmt lib/x.txt > /dev/null 2>&1; ok "new-files-only refuses a tracked file" "$?" "2"
$GW fmt > /dev/null 2>&1; ok "requires-args refuses no args" "$?" "2"
touch tests/zz_probe.sh; $GW delete-scratch tests/zz_probe.sh > /dev/null 2>&1; ok "delete-scratch removes a probe" "$([[ -f tests/zz_probe.sh ]] && echo present || echo gone)" "gone"
$GW delete-scratch lib/x.txt > /dev/null 2>&1; ok "delete-scratch refuses other paths" "$?" "2"
$GW del > /dev/null 2>&1; code=$?
ok "a check that deletes a tracked file fails" "$code" "3"
ok "the deleted file is restored" "$([[ -f lib/a.txt ]] && echo present || echo gone)" "present"
$GW git-show HEAD --name-only > /dev/null 2>&1; ok "git-show --name-only allowed" "$?" "0"
$GW git-diff --no-index /etc/passwd > /dev/null 2>&1; ok "git-diff outside options refused" "$?" "2"
$GW test /etc/passwd > /dev/null 2>&1; ok "absolute path refused" "$?" "2"
echo ok > lib/x.txt
printf '[[ $(cat lib/x.txt) == ok ]]\n' > tests/t_real.sh; printf '[[ -f lib/x.txt ]]\n' > tests/t_vac.sh
$GW prove-red HEAD test tests/t_real.sh > /dev/null 2>&1; ok "prove-red: a real guard is RED (exit 0)" "$?" "0"
$GW prove-red HEAD test tests/t_vac.sh > /dev/null 2>&1; ok "prove-red: a vacuous test is GREEN (exit 1)" "$?" "1"
ok "prove-red leaves no worktree" "$(git worktree list | wc -l | tr -d ' ')" "1"
ok "prove-red leaves the main tree alone" "$(cat lib/x.txt)" "ok"

echo "runner"
fp=$({ git -c core.quotepath=off diff --numstat; git -c core.quotepath=off ls-files --others --exclude-standard; } | { grep -vE '(^|[[:space:]])\.work/' || true; } | cksum | awk '{ print $1 }')
mk() { d=.work/runs/$1; mkdir -p "$d"; echo "$2" > "$d/agent"; : > "$d/model"; local e=$(( $(date +%s) - $3*60 )); echo $e > "$d/started_epoch"
       if [[ $4 == wrote ]]; then echo $((e+60)) > "$d/diff_changed_epoch"; else echo $e > "$d/diff_changed_epoch"; fi
       echo "$fp" > "$d/diff_fp"; touch "$d/started"; : > "$d/before"; printf '%s' "$5" > "$d/output.log"; sleep 120 & echo $! > "$d/pid"; }
loop=""; for i in $(seq 45); do loop+=$'● Triple check '"$i"$' (shell)\n  │ grep -n "X" lib/x.txt\n\n'; done
den=""; for i in $(seq 45); do den+=$'✗ Try '"$i"$' (shell)\n  │ node -e "'"$i"$'"\n  └ Permission to run this tool was denied due to the following rules: `shell(node)`\n\n'; done
fil=$'● Read a\n  │ lib/a.txt\n'; for i in $(seq 230); do fil+=$'Let me read the model file.\n'; done
srch=""; for i in $(seq 45); do srch+=$'/ Search (grep)\n  │ "samePattern"\n  └ 3 lines found\n\n'; done
mk loop developer 2 wrote "$loop"; mk den developer 2 wrote "$den"; mk fil developer 2 wrote "$fil"; mk srch developer 2 wrote "$srch"
mk nowrite developer 21 none $'● Read a\n'; mk long developer 31 wrote $'● Read a\n'; mk healthy developer 10 wrote $'● Read a\n'; mk rev code-reviewer 40 none $'● Read a\n'
st() { bash $R status "$1" 2>/dev/null; }
ok "loop stop (same command, new titles)" "$(st loop | sed -n 's/^STOP_REASON: //p')" "loop"
ok "denied stop (explicit deny rule)" "$(st den | sed -n 's/^STOP_REASON: //p')" "denied"
ok "filler stop" "$(st fil | sed -n 's/^STOP_REASON: //p')" "filler"
ok "repeated built-in search stops as a loop" "$(st srch | sed -n 's/^STOP_REASON: //p')" "loop"
ok "no_write stop for an implementer" "$(st nowrite | sed -n 's/^STOP_REASON: //p')" "no_write"
ok "LONG_RUN warning past 30 min" "$(st long | grep -c 'LONG_RUN:')" "1"
ok "a healthy implementer keeps running" "$(st healthy | sed -n 's/^STATUS: //p')" "RUNNING"
ok "a reviewer is exempt from no_write" "$(st rev | sed -n 's/^STATUS: //p')" "RUNNING"
for r in long healthy rev; do kill "$(cat .work/runs/$r/pid)" 2> /dev/null; done
# Rules injection through the real worker, with a stand-in for copilot that records its prompt.
printf '#!/bin/bash\nwhile [[ $# -gt 0 ]]; do if [[ $1 == -p ]]; then printf "%%s\\n" "$2"; shift; else printf "ARG %%s\\n" "$1"; fi; shift; done\n' > stub.sh; chmod +x stub.sh
printf '\n- `./slow.sh` hangs for 30 s: never run it twice.\n' >> AGENTS.md
mkdir -p .work/t; echo "Do X." > .work/t/brief.md
COPILOT_BIN="$PWD/stub.sh" COPILOT_WRAPPER= bash $R start developer .work/t/brief.md > /dev/null 2>&1
o=.work/runs/$(cat .work/runs/latest.txt)/output.log
ok "rules injected for an implementer" "$(grep -c '^## Implementers' "$o")" "1"
ok "no unresolved placeholder in the prompt" "$(grep -c '{{' "$o")" "0"
ok "agents run with --no-custom-instructions" "$(grep -c '^ARG --no-custom-instructions$' "$o")" "1"
ok "built-in GitHub MCP server disabled" "$(grep -c '^ARG --disable-builtin-mcps$' "$o")" "1"
ok "usage written to the run folder" "$(grep -c '^ARG --usage-output-file$' "$o")" "1"
ok "AGENTS.md known hangs injected into the prompt" "$(grep -c 'slow.sh. hangs for 30 s' "$o")" "1"
COPILOT_NO_CUSTOM_INSTRUCTIONS=0 COPILOT_BIN="$PWD/stub.sh" COPILOT_WRAPPER= bash $R start developer .work/t/brief.md > /dev/null 2>&1
o=.work/runs/$(cat .work/runs/latest.txt)/output.log
ok "COPILOT_NO_CUSTOM_INSTRUCTIONS=0 turns it off" "$(grep -c '^ARG --no-custom-instructions$' "$o")" "0"
echo "passed $pass, failed $fail"
[[ $fail -eq 0 ]]
