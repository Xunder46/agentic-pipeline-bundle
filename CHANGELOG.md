# Changelog

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
