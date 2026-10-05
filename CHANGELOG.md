# Changelog

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
- Output over 200 lines is summarised (first lines, failure-looking lines, last lines); the full log
  is kept in `.work/gateway/`. Option `full-output` opts a check out.
- Option `new-files-only`: refuse tracked files (for formatters while the repo is not format-clean).
- `delete-scratch <TEST_ROOT>/zz_<name>`: an agent removes its own untracked probe file.
- `git-show` accepts `--name-only` and `--name-status`.

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
