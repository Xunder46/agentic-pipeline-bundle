# Changelog

## 1.7.1 — 2026-10-09

- **`WAIT_MINUTES` defaults to 25** (was 15). Every `wait` return wakes the governing Claude session for
  a full turn, which re-sends the whole session; in a day-long session those turns dominate Claude's
  cost. The runner stops broken runs by itself (loop, denied, filler, no_write, stalled), so mid-run
  check-ins add little. Keep it under the Bash timeout in `.claude/settings.json` (60 minutes).

## 1.7.0 — 2026-10-08

- **`start` returns at once** with the RUN_ID; `wait` blocks (run it in the background). A governor
  that loses the "run in the background" rule, for example when its context is compacted, now loses
  seconds instead of freezing its session for up to `WAIT_MINUTES`.
- **`COPILOT_REASONING_EFFORT` defaults to unset** (the model's default). Measured on
  deepseek-v4.1-flash, `max` raised output per request 582 -> 959 tokens (reasoning 372 -> 723) and
  doubled the uncached share of input: about twice the cost per request, with no visible quality gain.
- **Briefs quote the code to change**: for an item that changes existing logic, the brief carries the
  current lines (up to ~20). Every no-write stop so far had file-and-line pointers only, and each
  re-brief with the code written out wrote files within minutes.
- First seeded plans: planners kept every seeded entry and raised 2 seed inaccuracies as Open
  questions; seeded planner runs took 17 and 26 min against 45 min for the last unseeded one.

## 1.6.0 — 2026-10-07

- **The governor seeds each plan** (`/feature` step 2): it writes the Goal, Decision Ledger, core
  scenarios (fixture, expected outcome, why it fails without the change), phase outline and code
  pointers, about 100–150 lines, before the Copilot planner expands the rest. Every plan revision
  measured so far traced to a decision or a scenario the governor then had to find by reading code;
  the seed puts that work first. The planner keeps seeded entries as written (agent-rules.md), the
  governor checks them against `.work/<slug>/seed.md`, and the friction SUMMARY records "Seeded".
- **`pipeline-stats.sh`** (macOS/Linux): what a window of runs cost and produced. `/feature` pastes it
  into each unit's SUMMARY; `/retro` starts from it. `STATS_PATHS` in `pipeline.env` sets which code
  counts as produced.

## 1.5.0 — 2026-10-07

- **Reasoning effort is a setting** (`COPILOT_REASONING_EFFORT`, default `max`; empty = the model's
  default), passed as `--reasoning-effort` to every agent run. Reasoning is billed as output and slows
  requests; max suits a cheap, fast model. Verify the provider accepts it with one small run.
- Regression suite: 36 checks.

## 1.4.0 — 2026-10-07

- **Agents run with `--no-custom-instructions`** (setting `COPILOT_NO_CUSTOM_INSTRUCTIONS`, default 1).
  Copilot otherwise loads `AGENTS.md` (and related files such as `CLAUDE.md`) into every model request,
  although agents already get their rules from `agent-rules.md` and project facts from their agent
  file. The one section only `AGENTS.md` holds, "Known long-running or hanging commands", is injected
  into the prompt by the runner. Expected saving: the size of those files on every request (a few
  percent of each request). Set 0 to restore the old behaviour.
- Confirmed on Copilot CLI (`copilot instruction list`): agent runs were loading both `AGENTS.md` and
  `CLAUDE.md`, about 4,300 tokens on every request in the project measured (~7% of a request).
- Agents also run with `--disable-builtin-mcps` (no GitHub MCP server: agents never need GitHub
  access) and `--usage-output-file .work/runs/<RUN_ID>/usage.json` (exact usage, even for stopped runs).
- Regression suite: 33 checks.

## 1.3.1 — 2026-10-07

- `tests/macos/regression.sh`: one command that installs the bundle into a throwaway repo and checks
  every gateway and runner guard added in 1.1–1.3 (28 checks). The Windows scripts remain unexecuted.
- Measured after 1.3 (one night, 15 runs): fix rounds fell from 19% to 10% of tokens, no run briefed
  under 1.3 lasted 45 minutes, `prove-red` caught two tests that proved nothing before review, and the
  no-write stop fired once. Tokens per changed line stayed at ~27k, as in every version so far.

## 1.3.0 — 2026-10-06

Measured on a full day after 1.2: the same output as the previous day for 14% fewer tokens per PR,
briefs fully compliant, far fewer runs reading without writing. The remaining waste: fix rounds (19%
of tokens, mostly tests that proved nothing), runs of 55–61 minutes (24%), and repeated test runs.

- **`prove-red`** (gateway): runs the named check on a temporary checkout of a commit (usually HEAD)
  with the agent's test files carried over. RED AT proves the test detects the change; GREEN AT means
  it proves nothing (exit 1). An optional `base-setup` check prepares the checkout. Agents must paste
  the verdicts; the reviewer spot-checks with it; the governor treats a missing or GREEN verdict as a
  failed verify.
- **One concern per run:** a `LONG_RUN` warning past `LONG_RUN_MINUTES` (30); briefs never cover two
  phases; plans keep phases to 8 items; implementers stop at a finished item when unplanned work grows.
- **Test economy:** while working, run only the touched tests; the full suite once at the end and
  again only after a fix; another suite only if its sources changed.

## 1.2.0 — 2026-10-06

From measuring 30 runs after 1.1: reliability improved (no loops, no degenerated runs, every phase
green on first verify, chunked re-reads of spilled output 162 → 6), cost per line of change was flat,
and per-run efficiency got worse in four ways this release addresses.

- **Standing rules in one file.** `.github/copilot/agent-rules.md` (by role) is appended to every
  prompt by the runner; `/feature` no longer has a paste-in footer. After 1.1, the governor kept
  copying an outdated footer from earlier briefs (24 of 24 implementer briefs), so the new cost rules
  never reached agents.
- **No-write stop.** The runner stops an implementer that has changed no file after `NO_WRITE_STOP`
  (default 20) minutes, and HEALTH shows `FIRST_WRITE` and `TOP_READ` (most re-read file across line
  ranges). One run read for 30 minutes (plan 27×, two files 20× each) and wrote nothing.
- **Built-in searches count** in loop detection (`/ Search` lines); with shell grep denied they grew 15×.
- **Deletions through checks are reverted.** The gateway restores tracked files a check deleted and
  fails the check; agents list needed deletions as "Governor actions" and the governor makes them. An
  agent had deleted files by running a throwaway test through the gateway.
- **Code pointers.** Briefs give file + symbol (+ line) per item; plan items name file and symbol.
  The stalled phase's retry with pointers wrote files within 10 minutes.

## 1.1.1 — 2026-10-05

Restored rules found missing by a line-by-line regression check of a project's migration to the bundle
(old agent files against new, by meaning):

- Reviewer: scope triage at review (more than 6 findings → fix critical and mechanical ones, plan the
  rest, never review → fix → review); read one intent doc (the cap does not limit 4d); a
  zero-implicated 4d result means the step was skipped; the handoff's Docs section is checked; cited
  tests are looked up by exact group and test name.
- Implementers: finish or roll back the item in progress before a scope stop.
- Planners: re-invoked with scope moved out of an oversized PR, plan only that scope.
- `/feature`: the governor's own "verification is observed output" rule; start from the docs index.
- `/run-pipeline`: scope checks after each implementation agent and after the review.
- Runner (macOS): `STRAY_LOOPS` health line for orphaned busy-loop shells.
- Permissions: agents may not write `.github/workflows/**`.

## 1.1.0 — 2026-10-04

Lessons from a project running this pipeline, plus fixes from an analysis of its run
logs and friction log (see RECOMMENDATIONS.md §2 for the measurements).

**Runner**
- Loop detection keys shell calls on the command and reads on path + line range, and counts failed
  and denied calls (`✗`). The old title-based counter missed a 536-repeat loop and a 652-retry denial loop.
- New auto-stops: `denied` (REPEAT_STOP denials) and `filler` (one prose line repeated
  max(200, 5 × REPEAT_STOP) times: a degenerated model).
- HEALTH adds `DENIED`, `TOP_TEXT_REPEAT`, `TOKENS` (Copilot's totals) and `HIGH_LOAD`.

**Gateway**
- Output over 200 lines or 16 KB is summarised (first lines, failure-looking lines, last lines); the full log
  is kept in `.work/gateway/`. Option `full-output` opts a check out.
- Option `new-files-only`: refuse tracked files (for formatters while the repo is not format-clean).
- `delete-scratch <TEST_ROOT>/zz_<name>`: an agent removes its own untracked probe file.
- `git-show` accepts `--name-only` and `--name-status`.
- (follow-up) The summary also triggers above 16 KB: 196 lint notices are only ~200 lines but 37 KB.

**Plans and scope**
- One folder per plan: `<plan>.md`, `<plan>.evidence.md`, `<plan>.review.md`. The governor creates
  the folder (Copilot's create tool cannot make directories).
- New `.github/copilot/pr-scope-budget.md` and the `pr-scope-guard` skill, run at plan, phase and
  review checkpoints by `/feature`, `/plan` and `/run-pipeline`.

**Governor (`/feature`)**
- New Cost section: one concern per run, plan sections instead of whole plans, closed fix briefs,
  never asking an agent to verify what its tools cannot check.
- Plan validation by re-derivation (re-implement rules, check every fixture number, read the function
  behind framework claims, mutation checks name their seed).
- Hard rules for decision ownership, scope, and machine hygiene; planners never count lines.
- One phase per run is now the default.
- Short ordered review briefs; the reviewer creates its review file first. Test-name comparison in
  the governor's own review.
- Footer: no filler turns, no re-reads, denied commands never retried, no probe files, minimal edits
  checked by diff, no real-clock thresholds, exact-restore mutation checks, stop when an unpredicted
  existing test goes red, decisions win over step text, evidence out of the plan.
- Friction SUMMARY records model requests.

**Agents**
- Copilot preamble: gateway spelled exactly, no `cd` or chains, summarised output, never retry a
  denial, every turn calls a tool, no re-reads.
- Implementers: "Edits, Probes and Tests" section; evidence goes to the evidence file; scope stop.
- Planners: plan folder and budget; anti-patterns from real plan defects; one phase ≈ one ten-step run.
- Reviewer: writes `<plan>.review.md` (created first). The Claude edition gains `Write`, without
  which it could not create the file.
- `/retro` ranks runs by model requests.
