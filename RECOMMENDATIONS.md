# Design notes and recommendations

Multi-agent pipelines tend to fail in a few predictable ways:
- a test suite passes while the change is still wrong
- a command hangs, or an agent loops on the same failing step
- a brief prescribes a fix that can't work
- a tool rewrites files nobody asked it to touch
- status and checklists drift out of date

The first section shows how this bundle guards against each. The second lists improvements worth considering once it's running in your project.

## 1. What the bundle already does, and why

| # | Mechanism | Failure it prevents |
|---|---|---|
| 1 | **The governor re-runs every check itself** (lint, tests, build, invariant checks) and runs an independent review before shipping | Agents report "all green" on work that doesn't pass, or passes for the wrong reason |
| 2 | **A standing review focus in every review brief**: one computation per figure shown in two places, no test asserting the buggy behaviour, accessibility/interaction tests for rewritten UI, injected seams used everywhere, docs still true | The defect classes that most often survive a green test suite |
| 3 | **`install.sh` resolves every placeholder and fails if one is left** | An agent given an unresolved `{{PLACEHOLDER}}` invents a path, and the pipeline silently forks |
| 4 | **`AGENTS.md` is the single source of project facts**, imported into `CLAUDE.md` with `@AGENTS.md` | Claude Code and Copilot working from different instructions |
| 5 | **Two agent editions generated from one source**: `.claude/agents/` for Claude Code, `.github/agents/` for Copilot (Copilot tool names and a Copilot-mode preamble) | Copilot agents inheriting Claude-only assumptions (asking the user, tools they don't have) |
| 5b | **Least-privilege Copilot runs**: per-agent permission profiles, the gateway as the only shell command, explicit denies for the read-only commands Copilot auto-approves, path-scoped writes, secrets stripped from the shell; the runner refuses allow-all | An agent with every tool can read anything (including `~` files) and write anything |
| 6 | **The runner auto-stops runs** on a max runtime, on one action repeated too often (a loop), and when both the log and the diff go idle (a hang) | Hung code generators and retry loops burning an hour before a human notices |
| 7 | **The runner prints a HEALTH block** (log/diff idle time, the most repeated action, hung child processes, model requests and errors), plus `status` and `list` | The governor spending many tool calls (and context) gathering run health by hand |
| 8 | **`with-timeout.sh`** kills the command's whole process group and exits 124 | Long commands blocking an agent forever; orphaned compiler or test processes after a timeout |
| 9 | **Fix briefs state the goal and the acceptance test, not a mechanism** | A governor prescribing a fix that turns out to be impossible, and the developer either following it or silently ignoring it |
| 10 | **"Never run a formatter or rewriting tool on a directory or the tree"** in every brief, plus a diff-size check | One tool call reformatting hundreds of unrelated files |
| 11 | **Git belongs to the governor**: agents are denied commit, push, reset, switch and checkout; the governor never merges or force-pushes | Agents rewriting history or shipping unreviewed work |
| 12 | **(owner) checks are listed at the start of every feature, and status is checked at wrap-up** | Human-only checks piling up unseen; plan headers and project-state docs going stale |
| 13 | **Friction is recorded during a run and acted on only through `/retro`** | Process changes made mid-run, by the agent being governed |
| 14 | **One planner installed**, chosen in the config | Two planners with overlapping instructions |
| 15 | **Per-role models** (planner / developer / reviewer) | Paying top-model prices for routine implementation, or skimping on the review |

## 2. Improvements worth considering

1. **Spend your strongest model on review.** In practice, independent review is the stage that keeps
   finding real defects behind passing tests. Either set `REVIEWER_MODEL` to your provider's
   strongest model, or, in `/feature` step 5, use the Claude `code-reviewer` subagent instead of the
   Copilot reviewer, keeping Copilot for planning and implementation. Track the effect with the
   friction SUMMARY's "review found blocker/major behind green" field.
2. **Retire the OpenCode proxy if your Copilot version allows it.** Copilot CLI supports
   `COPILOT_PROVIDER_HEADERS` (custom headers sent to a BYOK endpoint). Try
   `COPILOT_PROVIDER_BASE_URL=https://opencode.ai/zen/go/v1` with
   `COPILOT_PROVIDER_HEADERS=$'x-opencode-session: <per-run id>\nUser-Agent: copilot-governor/1.0'`
   and `COPILOT_WRAPPER=""`. If OpenCode accepts it (some clients can't override User-Agent), the
   Node dependency and one moving part disappear. The runner would then need to set the per-run
   session header itself.
3. **Make CI the permanent guard.** One workflow running lint, tests and your `INVARIANT_CHECKS` on
   every push catches what an agent or a governor forgets to run. Use the OS your snapshot/golden
   tests are generated on. When `/retro` has a choice, prefer "add a CI check" over "add an
   instruction".
4. **Make the repo formatter-clean once, then enforce it.** One `chore: format` commit, its hash in
   `.git-blame-ignore-revs`, and a `--set-exit-if-changed`-style check in CI remove the risk behind
   rule 10 entirely.
5. **One developer run per phase for long plans.** A single run across many phases is cheaper in
   governor turns, but a failure late in the run costs everything before it. A phase per run gives a
   verify-and-commit checkpoint after each phase and cheaper fix rounds.
6. **Keep a first-class owner-check register** (e.g. `docs/owner-checks.md`) once more than a handful
   accumulate. The preflight grep in `/feature` is a stopgap.
7. **Re-verify the permission model after each Copilot CLI upgrade.** The deny list in
   `common.flags` exists because Copilot auto-approves some read-only commands and its path check
   misses `~`. A new version may change either. A ten-minute check with a decoy file in your home
   folder (`cat ~/decoy`, `git diff --no-index ~/decoy /dev/null`, plus a gateway call) tells you
   whether the profiles still hold. Never test with a real secrets file.
8. **Use a fresh Claude Code session per feature or batch of features.** The plan file, briefs and
   friction log carry everything the next session needs, and `/resume` re-derives the actual state
   from the repo.
9. **Version your fork of the bundle.** Bump `VERSION` when you change templates. `install.sh` stamps
   `.claude/pipeline.version` in each project, so you can tell which ones run an older pipeline.
