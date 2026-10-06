# Design notes and recommendations

Multi-agent pipelines tend to fail in a few predictable ways:
- a test suite passes while the change is still wrong
- a command hangs, or an agent loops on the same failing step
- a brief prescribes a fix that can't work
- a tool rewrites files nobody asked it to touch
- status and checklists drift out of date

The first section shows how this bundle guards against each. The second shows where the tokens go in practice. The third lists improvements worth considering once it's running in your project.

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
| 16 | **Loop detection keyed on what the agent does, not what it says.** Shell calls are counted by command, reads by path and line range, failed and denied calls included; denials and repeated prose stop a run too | A model that retitles the same `grep` 536 times ("Triple check thirty-first time"), retries a denied command 652 times, or writes 30,000 lines of filler, all unseen by a title-based counter |
| 17 | **The gateway summarises long output** and keeps the full log in `.work/gateway/` | A 37 KB lint report (mostly pre-existing notices) saved to a temp file and re-read in chunks: 98 such reads in one day |
| 18 | **`new-files-only` formatters and `delete-scratch`** in the gateway | A formatter turning a 4-line edit into a 400-line diff; probe files the agent cannot delete left for the owner |
| 19 | **One folder per plan, with evidence and review files beside it, and a scope budget** (`pr-scope-budget.md`, `pr-scope-guard`) | Plans growing to thousands of lines of evidence and review text that every agent then re-reads; one PR that should have been three |
| 20 | **Plan validation by re-derivation**: the governor re-implements non-trivial rules in a script and checks every fixture number, reads the function behind each "the framework does X" claim | Circular definitions, wrong arithmetic and wrong ordering claims reaching implementers, who then loop trying to satisfy an impossible scenario |
| 21 | **Standing agent rules in one file the runner injects** (`agent-rules.md`) | A rule change never reaching agents because each brief copies the previous brief's footer |
| 22 | **No-write stop and `TOP_READ`**: an implementer that has written nothing after 20 minutes is stopped | Runs that read the same plan and files dozens of times and write nothing |
| 23 | **The gateway reverts deletions made through a check**; the governor makes planned deletions | An agent routing around "no deletions" by writing a test that deletes files |

## 2. Where the tokens go

Measured on a real project running this pipeline, one day of Copilot runs (28 finished runs, all on one
fast model):

- **Cost is the number of model requests.** Every request re-sends the agent's whole context: 52k
  tokens on average, about 25–30k of it fixed (Copilot's own prompt, the agent file, the project's
  instruction files). 96% of input tokens were cache hits, so caching softens the price but not the
  shape: a 24-request fix cost 0.7M input tokens, a 193-request phase 10.6M.
- **The single biggest cost was one loop:** 577 requests (about 29M tokens, a fifth of the day) on
  the same `grep`, which the old title-based loop counter could not see. The runner now catches it at
  40 (§1, row 16).
- **Re-reading is the next biggest.** Agents re-read the plan 8–40 times in a run, and re-read large
  tool output (a 37 KB lint report) from temp files in chunks. Short plans, briefs that name the plan
  sections to read, and the gateway's summaries (row 17) all cut requests.
- **Open-ended briefs are expensive.** A one-line fix whose brief also said "look for similar
  mistakes" ran 22 minutes and 100 requests, mostly reading compiler and SDK files it had no way to
  check. Closed fix briefs and "never ask an agent to verify what its tools cannot check" are now in
  `/feature`.
- **Rules only help if they reach the agent.** After a rules change, governors kept pasting the
  previous brief's footer into new briefs, so none of the new rules arrived. The runner now injects the
  rules itself.
- **Reading without writing is the next waste after loops.** With exact-repeat loops caught, the costly
  runs became ones that re-read the plan and a few files 20–27 times without editing. Concrete code
  pointers in the brief fixed the one measured case within 10 minutes.
- **Plan defects cost the most time.** Most re-runs traced back to the plan: circular definitions,
  wrong fixture arithmetic, ordering claims nobody had read the code for, scenarios a rule's own floors
  made unreachable. Two implementer runs degenerated into filler trying to satisfy one of them.

## 3. Improvements worth considering

1. **Spend your strongest model on planning and review.** Review is the stage that keeps finding
   real defects behind passing tests, and plan defects are the largest source of re-runs (§2). Set
   `PLANNER_MODEL` and `REVIEWER_MODEL` to your provider's strongest model and keep
   `DEVELOPER_MODEL` fast: planners and reviewers make few requests per feature, implementers make
   most of them. Or, in `/feature` step 5, use the Claude `code-reviewer` subagent instead of the
   Copilot reviewer. Track the effect with the friction SUMMARY's "review found blocker/major behind
   green" and "Plan revisions" fields.
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
5. **Keep agent files and project instructions short.** Copilot loads the agent file and the
   project's instruction files (`AGENTS.md`, `CLAUDE.md`) into every request. Long code samples and
   project history in those files are paid for on every one of a run's requests; point at docs
   instead.
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
