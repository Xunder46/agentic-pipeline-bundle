## Development pipeline

This repository is built by a planned, multi-agent pipeline. **Claude Code** reads this file through
`CLAUDE.md` (`@AGENTS.md`), and **GitHub Copilot CLI** reads it directly, so the facts below bind both.
Agents come in two editions: `.claude/agents/<name>.md` for Claude Code subagents, and
`.github/agents/<name>.agent.md` for GitHub Copilot CLI (which prefers them over the `.claude/` files).

### Project variables

| Variable | Value |
|---|---|
| Project / stack | {{PROJECT_NAME}} — {{STACK}} |
| Source / tests | `{{SOURCE_ROOT}}` / `{{TEST_ROOT}}` |
| Architecture docs / index | `{{DOCS_ROOT}}` / `{{DOCS_INDEX}}` |
| Conventions (binding rule source) | `{{CONVENTIONS_DOC}}` |
| Doc standard | `{{DOC_STANDARD}}` |
| Plans | `{{PLANS_ROOT}}/<feature>-plan/<feature>-plan.md` |
| Layers | models `{{MODEL_DIR}}` · persistence `{{PERSISTENCE_DIR}}` · state `{{STATE_DIR}}` · screens `{{UI_DIR}}` · shared UI `{{SHARED_UI_DIR}}` · core `{{CORE_DIR}}` |
| Persistence interface | `{{DATA_INTERFACE}}` — production `{{PRIMARY_IMPL}}`, tests `{{TEST_IMPL}}` |
| Schema artifact / seed | `{{SCHEMA_ARTIFACT}}` / `{{SEED_FILE}}` |
| Design system | `{{DESIGN_SYSTEM_DOC}}` |
| Lint / typecheck / test | `{{LINT_CMD}}` / `{{TYPECHECK_CMD}}` / `{{TEST_CMD}}` |
| Build / run | `{{BUILD_CMD}}` / `{{RUN_CMD}}` |
| Base branch | `{{BASE_BRANCH}}` |

"(not used in this project)" means the concept does not exist here: skip every rule that mentions it.

### Invariant checks (every change must leave these clean)

{{INVARIANT_CHECKS}}

### Rules for every agent

- **The plan file is the contract.** Read `{{PLANS_ROOT}}/<feature>-plan/<feature>-plan.md` before writing anything;
  write Progress, the Assumption Log and Feedback back to it. Coordinate through the plan, never through
  chat history. Decisions are `D-n`, scenarios `S-n`; both are stable and never reused. Evidence goes in
  `<feature>-plan.evidence.md` and review findings in `<feature>-plan.review.md`, beside the plan; the
  plan stays within `.github/copilot/pr-scope-budget.md`.
- **Git belongs to the governor.** Never commit, push, reset, switch or check out branches.
- **Shell commands.** Copilot agents: the gateway `{{GATEWAY}}` is the only shell command they may
  run (everything else is denied by `.github/copilot/permissions/`). Claude Code agents: wrap long
  commands in `{{TIMEOUT_WRAPPER}} <seconds> <cmd…>` — {{LONG_CMD_TIMEOUT}} s for installs, code
  generation and builds, {{TEST_TIMEOUT}} s for the full test suite. Exit 124 = timed out: diagnose,
  never re-run unchanged.
- **Never run a formatter or rewriting tool on a directory or the whole tree** — only on files you
  created or changed, by explicit path.
- **Verification is observed output.** Paste real pass/fail counts; "compiles" is not "passes"; a
  bug-fix test must be shown to fail without the fix.
- **If a fix fails twice, stop and report.** Never run the same failing command a third time.
- Do not edit `.claude/`, `.github/agents/`, `.github/copilot/` or this file.

### Where things live

| Path | What |
|---|---|
| `.claude/agents/` | Claude Code editions of the agents (planner, data-architect, developer, code-reviewer) |
| `.github/agents/` | GitHub Copilot CLI editions of the same agents |
| `.github/copilot/` | Copilot permission profiles (`permissions/`), the gateway and its checks (`gateway.conf`, `scripts/`) |
| `.claude/commands/` | `/feature` (governor), `/plan`, `/implement`, `/review`, `/resume`, `/run-pipeline`, `/retro` |
| `.claude/skills/pr-scope-guard/` | applies the PR scope budget (`.github/copilot/pr-scope-budget.md`) at each checkpoint |
| `.claude/scripts/` | the Copilot runner, timeout wrapper and OpenCode wrapper ({{PLATFORM}} edition), plus the shared proxy |
| `.claude/pipeline.env` | runner settings (no secrets) |
| `.work/` (gitignored) | briefs, run logs (`.work/runs/<RUN_ID>/`), full gateway output (`.work/gateway/`), `friction.md` |
| `{{PLANS_ROOT}}/` | one folder per plan: plan, evidence and review files (committed) |

Project-specific timeouts and known hangs: see **Known long-running or hanging commands** below this
block.
