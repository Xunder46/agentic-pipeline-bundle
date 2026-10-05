# Agents and configuration reference

The pipeline's agents, in two editions:

- `template/claude/agents/<name>.md` → `.claude/agents/`: Claude Code subagents (Mode A).
- `template/github/agents/<name>.agent.md` → `.github/agents/`: GitHub Copilot CLI agents (Mode B),
  with Copilot tool names, a Copilot-mode preamble (non-interactive, gateway-only shell, the role's
  write scope) and every check routed through the gateway. Copilot prefers these over the `.claude/`
  files of the same name.

The installer copies both and replaces every `{{PLACEHOLDER}}` with the value from your config file.
You never edit placeholders by hand.

This file sits outside the agent folders on purpose: Copilot CLI loads every `.md` file in
`.claude/agents/` and `.github/agents/` as an agent, and logs a frontmatter error for anything that
isn't one.

## The pipeline

```
planner ──▶ data-architect ──▶ developer ──▶ code-reviewer ──▶ you
 (plan)        (data layer)      (logic/UI)     (verify)        (decide)
```

| Agent | Owns | Never does |
|---|---|---|
| **conductor-v2** (recommended planner) | The plan file: a decision ledger, fixture-enumerated scenarios, per-phase Done Criteria and Predicted Files | Write source code |
| **conductor** (lighter planner) | The same role without the decision ledger; for small teams or short-lived work | Write source code |
| **data-architect** | Models, the persistence interface and its implementations, migrations, seed/fixture data | UI, state logic |
| **developer** | State and business logic, screens, components, navigation, and the tests for them (test-first from the plan's scenarios) | Schema, persistence implementations |
| **code-reviewer** | Verifies against the plan, the conventions doc and the architecture; plans fixes | Edit source code; it stops for you |

Set `PLANNER_AGENT` in your config. The installer copies only that planner.

## Copilot permissions per agent

| Agent | Copilot tools | May write | Shell |
|---|---|---|---|
| planner (`conductor-v2` / `conductor`) | view, grep, glob, create, edit, execute, update_todo | `PLANS_ROOT/**`, `DOCS_ROOT/**` | gateway only |
| `data-architect`, `developer` | same | the whole repo except `.claude/`, `.github/agents/`, `.github/copilot/`, `.github/workflows/`, `.git/`, `AGENTS.md`, `CLAUDE.md` | gateway only |
| `code-reviewer` | same | `PLANS_ROOT/**` (the review file and the plan's Feedback) | gateway only |

Profiles live in `.github/copilot/permissions/` (`common.flags` applies to every run). The runner
refuses to start an agent without a profile, and refuses any profile that grants everything or allows
an interpreter.

## Before the first run

1. **Write the conventions doc** (`CONVENTIONS_DOC`). Every agent uses it as a checklist on every
   task. The installer creates a skeleton if the file doesn't exist; fill in at least layering,
   persistence parity, tests and the invariant checks. Without it the agents guess.
2. **Choose models.** Claude Code editions: the `model:` field (`sonnet`, `opus`, `haiku`, `inherit`).
   Copilot editions: `PLANNER_MODEL` / `DEVELOPER_MODEL` / `REVIEWER_MODEL` in your config (Copilot
   ignores `model:` in agent files when you bring your own provider key, so the runner passes
   `--model` per role). Planning and review repay a stronger model.
3. **Review the gateway checks** in `.github/copilot/gateway.conf`: they are the only commands
   Copilot agents can run. Add what your agents need (code generation, a formatter with
   `requires-args new-files-only`) through `GATEWAY_EXTRA`, never as a shell allow rule. Besides the
   checks and git views, the gateway offers `delete-scratch` (an agent removes its own untracked
   `TEST_ROOT/zz_*` probe file) and summarises output over 200 lines or 16 KB, keeping the full log in
   `.work/gateway/`.
4. **Tune the scope budget** in `.github/copilot/pr-scope-budget.md` if your PRs are naturally larger
   or smaller; the `pr-scope-guard` skill applies it at each checkpoint.

## Configuration keys

Every key below is a line in your config file (see `pipeline.config.example`). Leave a key empty when
the concept doesn't exist in your project: the installer writes "(not used in this project)" and the
agents skip rules about it.

### Project layout and commands

| Key | Meaning | Example |
|---|---|---|
| `PROJECT_NAME` * | The application | `Acme Ledger` |
| `STACK` * | Language, framework, main libraries | `TypeScript + React, Vitest` |
| `BASE_BRANCH` * | Branch features start from and PRs target | `main` |
| `SOURCE_ROOT` | Application source root | `src/` |
| `TEST_ROOT` | Test root; agents' probe files are `TEST_ROOT/zz_*` (removable with `gateway delete-scratch`) | `tests/` |
| `DOCS_ROOT` | Agent-facing architecture docs | `docs/architecture/` |
| `DOCS_INDEX` | The index the planner reads first (skeleton created if absent) | `docs/architecture/README.md` |
| `PLANS_ROOT` * | Plan files, no trailing slash | `docs/plans` |
| `CONVENTIONS_DOC` * | The standing cross-cutting rules (skeleton created if absent) | `docs/conventions.md` |
| `DOC_STANDARD` | What docs may and may not contain (optional) | `docs/doc-standard.md` |
| `MODEL_DIR` | Domain models / entities | `src/domain/models/` |
| `PERSISTENCE_DIR` | Repositories / data access | `src/data/` |
| `STATE_DIR` | State / application logic | `src/state/` |
| `UI_DIR` | Screens / pages / views | `src/features/` |
| `SHARED_UI_DIR` | Reusable presentational components | `src/components/` |
| `CORE_DIR` | Cross-cutting utilities and constants | `src/core/` |
| `DATA_INTERFACE` | The persistence abstraction | `LedgerRepository` |
| `PRIMARY_IMPL` | Production implementation | `PostgresLedgerRepository` |
| `TEST_IMPL` | Test/dev implementation | `InMemoryLedgerRepository` |
| `SCHEMA_ARTIFACT` | Schema contract file, if any | `db/schema.sql` |
| `SEED_FILE` | Seed / fixture data | `src/data/seed.ts` |
| `DESIGN_SYSTEM_DOC` | Component and theming rules | `docs/design-system.md` |
| `LINT_CMD` * | Lint / static analysis | `npm run lint` |
| `TYPECHECK_CMD` | Type check, if separate | `npm run typecheck` |
| `TEST_CMD` * | Full test suite | `npm test` |
| `BUILD_CMD` | Build (the governor's verify step; also the gateway's `build` check) | `npm run build` |
| `RUN_CMD` | Run locally | `npm run dev` |

\* required

### Pipeline behaviour

| Key | Meaning | Default |
|---|---|---|
| `PLANNER_AGENT` * | `conductor-v2` or `conductor` | — |
| `PLATFORM` | `macos` (also Linux) or `windows`: which scripts are installed | `macos` (`windows` in install.ps1) |
| `GATEWAY_EXTRA` | Extra gateway checks, `name\|seconds\|command[\|options]` separated by `;`; options: `requires-args`, `new-files-only`, `full-output` | empty |
| `INVARIANT_CHECKS` | One line of markdown: the greps/commands every change must leave clean | none |
| `LONG_CMD_TIMEOUT` | Seconds for installs, code generation and builds (`with-timeout.sh`) | `300` |
| `TEST_TIMEOUT` | Seconds for the full test suite | `900` |
| `MAX_AGENT_MINUTES` | The governor's cap on total agent time per feature | `90` |
| `PLANNER_MODEL` / `DEVELOPER_MODEL` / `REVIEWER_MODEL` | Copilot model per role (written to `pipeline.env`); empty = provider default | empty |

### Runner (written to `.claude/pipeline.env`)

| Key | Meaning | Default |
|---|---|---|
| `COPILOT_WRAPPER` | `with-opencode.sh` (`.ps1` on Windows) for OpenCode Go/Zen; empty otherwise | empty |
| `WAIT_MINUTES` | Each `start`/`wait` call returns after this long | `15` |
| `MAX_RUN_MINUTES` | Hard stop per run (0 = off) | `120` |
| `STALL_MINUTES` | Stop when the log and the diff are both idle this long (0 = off) | `30` |
| `REPEAT_STOP` | Stop when one tool call repeats, or this many calls are denied; filler text stops at `max(200, 5×)` this (0 = off) | `40` |

## Conventions the agents share

- **The plan file is the contract.** One folder per plan under `PLANS_ROOT`, read at the start of every
  agent session and written back at the end. The plan carries requirements, decisions, scenarios,
  phases, one-line progress and feedback; `<plan>.evidence.md` holds suite outputs and red→green tables,
  and `<plan>.review.md` the reviewer's findings, so the plan every agent re-reads stays short. Agents
  coordinate through it, not through chat history.
- **Scope budget.** A plan over budget (`.github/copilot/pr-scope-budget.md`) is split into PRs instead
  of growing; the governor measures, planners never count lines.
- **Stable IDs.** Decisions are `D-1, D-2 …` and scenarios `S-001, S-002 …`. Both are numbered across
  features, never reused, and referenced from code comments and test names.
- **Verification is observed output, not inference.** Lint passing is not a test run. A completion
  claim requires pasted pass/fail counts. A new test for a bug fix must be shown to fail without the
  fix.
- **Decide-and-log.** Implementers never stall on ambiguity: they pick the option most consistent
  with the recorded decisions, log the choice and the reasoning in the plan's Assumption Log, and
  continue. The planner or reviewer ratifies or reverts it later.
- **Output discipline.** Surgical edits, no full-file rewrites, no echoing unchanged code, structured
  handoff summaries only.
- **Every defect class becomes a permanent guard.** A fix without a test that makes the defect
  impossible to reintroduce is not a finished fix.
- **(owner) checks.** Anything only a human can verify (a physical device, a store dashboard, real
  fixtures) is marked **(owner)** in the plan and recorded there when done. It never blocks an agent
  phase.
