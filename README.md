# Agentic pipeline: Claude Code governing GitHub Copilot CLI agents

A portable, installable development pipeline. Claude Code plans, governs and verifies; GitHub Copilot
CLI agents draft plans and write the code, each with **only the tools and paths its role needs**.
It is project-agnostic: every project-specific value is a `{{PLACEHOLDER}}` that the installer
resolves from one config file. macOS/Linux and Windows are both supported.

```
                       you (owner): answer one batched question round, own the PR merge
                                 │
                   ┌─────────────▼──────────────┐
                   │  Claude Code — governor    │  /feature: briefs agents, verifies every claim,
                   │  (.claude/commands/)       │  reviews the diff, owns git, logs friction
                   └──┬──────────┬──────────┬───┘
     runner + profile ┘          │          └ runner + profile
            ▼                    ▼                      ▼
  Copilot --agent          Copilot --agent        Copilot --agent
  conductor-v2 (plan)  →   data-architect /   →   code-reviewer (verify)
  writes: plans, docs      developer (build)      writes: plan folder only
                           writes: repo code
            └──── all coordinate through {{PLANS_ROOT}}/<feature>-plan/<feature>-plan.md ────┘
```

- **Two editions of every agent.** `.claude/agents/<name>.md` for Claude Code subagents, and
  `.github/agents/<name>.agent.md` for Copilot CLI (Copilot tool names, Copilot-mode instructions).
  Copilot prefers the `.github` edition when both exist.
- **Least privilege for Copilot.** The runner never passes `--allow-all-tools`. Each run gets the
  flags in `.github/copilot/permissions/common.flags` + `<agent>.flags`: the planner may write plans
  and docs, the reviewer only the plan file, builders the repo minus pipeline files. The only shell
  command any Copilot agent may run is the **gateway**, a fixed menu of checks (lint, test, build…)
  and read-only git views.
- **The plan file is the contract.** Decisions (`D-n`), fixture-enumerated scenarios (`S-n`),
  per-phase Done Criteria and Predicted Files. Every agent reads it and writes progress back.
- **The governor trusts nothing it hasn't run.** It re-runs the checks itself, reads the core files,
  runs an independent review, and only then commits and opens a PR (never merges).

---

## Contents

| Path | What it is |
|---|---|
| `install/macos/install.sh` | Installer for macOS and Linux |
| `install/windows/install.ps1` | Installer for Windows (PowerShell 7) |
| `pipeline.config.example` | The one file you fill in: project layout, commands, platform, limits |
| `examples/python-api.config` | A second worked example (a Python API with no UI layer) |
| `env/macos/copilot-provider.example.sh` | Copilot model-provider environment for macOS/Linux |
| `env/windows/copilot-provider.example.ps1` | The same for Windows |
| `template/claude/agents/` | Claude Code editions: `conductor-v2` / `conductor` (planner), `data-architect`, `developer`, `code-reviewer` |
| `template/claude/commands/` | `/feature` (governor), `/plan`, `/implement`, `/review`, `/resume`, `/run-pipeline`, `/retro` |
| `template/claude/skills/pr-scope-guard/` | Applies the PR scope budget when a plan is written, after each phase and after review |
| `template/claude/scripts/macos/`, `windows/` | The Copilot runner, timeout wrapper and OpenCode wrapper, per OS |
| `template/claude/scripts/common/` | `opencode-proxy.mjs` (Node, both OSes) |
| `template/claude/settings.json`, `pipeline.env` | Claude Code permissions; runner settings |
| `template/github/agents/` | Copilot CLI editions of the same agents |
| `template/github/copilot/permissions/` | Per-agent Copilot permission profiles (`common.flags` + one per agent) |
| `template/github/copilot/gateway.conf` | The gateway's checks (generated from your config) |
| `template/github/copilot/pr-scope-budget.md` | The PR scope budget: when a plan is too big, and how to split it |
| `template/github/copilot/agent-rules.md` | The standing rules for every agent run, by role; the runner appends them to each prompt, so briefs never carry copies |
| `template/github/copilot/scripts/macos/`, `windows/` | The gateway, per OS |
| `template/AGENTS.pipeline.md` | Project-facts block written into `AGENTS.md` (read by both tools) |
| `template/docs/` | Skeletons for the conventions doc and architecture index (created only if absent) |
| `docs/agents.md` | Agent roster, configuration-key reference, shared conventions |
| `RECOMMENDATIONS.md` | Why the pipeline works the way it does, and improvements worth considering |

`template/claude/` and `template/github/` are installed as `.claude/` and `.github/`. They are stored
without the dot so neither tool loads the unresolved templates in the repo that holds the bundle.
Only your platform's scripts are installed.

---

## 1. Two ways to run it

| Mode | Command | Who does the work | Needs |
|---|---|---|---|
| **A: Claude only** | `/plan` → `/implement` → `/review`, or `/run-pipeline` | Claude Code subagents (`.claude/agents/`) | Claude Code |
| **B: Claude governs Copilot** | `/feature <request>` | Copilot CLI agents (`.github/agents/`); Claude verifies and ships | Claude Code, Copilot CLI and a model provider, `gh` |

---

## 2. Prerequisites

| Tool | macOS / Linux | Windows | Check |
|---|---|---|---|
| git | Xcode Command Line Tools / package manager | Git for Windows (also gives Claude Code its Bash) | `git --version` |
| Script runtime | bash + perl (preinstalled) | PowerShell 7 (`winget install Microsoft.PowerShell`) | `perl -v` / `pwsh -v` |
| python3 (optional) | merges an existing `.claude/settings.json` | not needed | `python3 --version` |
| Claude Code | desktop app, or `npm install -g @anthropic-ai/claude-code` | same | `claude --version` |
| Node.js (Mode B) | current LTS | current LTS | `node --version` |
| GitHub Copilot CLI (Mode B) | `npm install -g @github/copilot` | same | `copilot --version` |
| GitHub CLI (PRs) | `brew install gh` | `winget install GitHub.cli` | `gh --version` |

Windows: PowerShell 7's default execution policy (RemoteSigned) runs the repo's local scripts. If
yours is stricter, run once: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

---

## 3. Keys, accounts and settings

### 3.1 Accounts and keys (never committed)

| What | How | Used by |
|---|---|---|
| **Claude Code login** | Open Claude Code (or run `claude`) and sign in with `/login` | the governor; Mode A |
| **Copilot model access** | **Option A:** a GitHub Copilot plan: run `copilot`, then `/login`. **Option B/C:** your own key through `COPILOT_PROVIDER_*` variables | Mode B agents |
| **Provider API key** (BYOK) | In a secret store, read through `COPILOT_PROVIDER_API_KEY_COMMAND`: the macOS keychain, or PowerShell SecretManagement on Windows (see `env/`). A plaintext `COPILOT_PROVIDER_API_KEY` also works | Mode B agents |
| **GitHub CLI** | `gh auth login` (HTTPS, with repo scope) | the governor's `git push` and `gh pr create` |

### 3.2 Copilot provider variables

Copy **one** option from `env/macos/copilot-provider.example.sh` into `~/.zshrc` (or
`~/.bash_profile`), or run the lines of `env/windows/copilot-provider.example.ps1` once on Windows.
Then open a new terminal **and restart Claude Code**. `copilot help environment` documents them all.

| Variable | Example value (Option B, OpenCode Go/Zen) | Meaning |
|---|---|---|
| `COPILOT_OFFLINE` | `true` | no GitHub login, telemetry or auto-update |
| `COPILOT_PROVIDER_TYPE` | `openai` | `openai` (any OpenAI-compatible API), `azure`, `anthropic` |
| `COPILOT_PROVIDER_BASE_URL` | **don't set it:** the OpenCode wrapper sets it per run | endpoint for other providers (Option C) |
| `COPILOT_PROVIDER_API_KEY_COMMAND` | macOS: `security find-generic-password -a "$USER" -s opencode-api-key -w` | prints the key on demand |
| `COPILOT_MODEL` / `COPILOT_PROVIDER_MODEL_ID` / `COPILOT_PROVIDER_WIRE_MODEL` | the model id from your provider's list | the default model; per-role models go in `pipeline.config` |
| `OPENCODE_UPSTREAM` (optional) | `https://opencode.ai/zen` | switch from Go (the default) to Zen |

### 3.3 Settings in the repo (committed, no secrets)

| File | What it holds | Notes |
|---|---|---|
| `pipeline.config` (yours) | Project layout, commands, `PLATFORM`, planner, gateway checks, models, limits | Re-run the installer after changing it |
| `.claude/pipeline.env` | Runner knobs: `WAIT_MINUTES`, `COPILOT_WRAPPER`, `MAX_RUN_MINUTES`, `REPEAT_STOP`, `STALL_MINUTES`, per-role models | An environment variable of the same name overrides it for one run |
| `.claude/settings.json` | Claude Code permissions and Bash timeouts | Allows the runner and timeout wrapper; denies force-push, pushing the base branch, merging, and calling `copilot` directly |
| `.github/copilot/permissions/*.flags` | Copilot permissions per agent | See §4 |
| `.github/copilot/gateway.conf` | The gateway's checks: `name \| timeout \| command [\| requires-args]` | Generated from `LINT_CMD`, `TYPECHECK_CMD`, `TEST_CMD`, `BUILD_CMD` and `GATEWAY_EXTRA` |
| `AGENTS.md` | The managed pipeline block (don't edit inside the markers), plus your own sections | Copilot reads it; `CLAUDE.md` imports it with `@AGENTS.md` |

---

## 4. How Copilot agents are confined

| Layer | What it does | Where |
|---|---|---|
| Agent `tools:` | Only `view`, `grep`, `glob`, `create`, `edit`, `execute` (shell) and `update_todo` are offered to the model | `.github/agents/*.agent.md` |
| Shell allow | Exactly one command: the gateway, by its path | `common.flags` |
| Shell deny | Copilot **auto-approves some read-only commands** (`cat`, `grep`, `git diff`…) with no allow rule, and its path check misses `~` paths, so these are denied explicitly | `common.flags` |
| Write allow | Planner: plans + docs. Reviewer: plans. Builders: anywhere in the repo | `<agent>.flags` |
| Write deny | `.claude/`, `.github/agents/`, `.github/copilot/`, `.github/workflows/` (CI runs with the repo's secrets), `.git/`, `AGENTS.md`, `CLAUDE.md` | `common.flags` |
| Secrets | Provider and GitHub tokens are stripped from the agent's shell environment | `common.flags` (`--secret-env-vars`) |
| Gateway | Fixed checks with timeouts; tracked files a check deletes are restored and the check fails; arguments must stay inside the repo (no absolute, `~` or `..` paths); read-only git views with validated refs; `requires-args` stops formatters running on the whole tree and `new-files-only` keeps them off existing files; `delete-scratch` removes only an untracked `TEST_ROOT/zz_*` probe; output over 200 lines or 16 KB is summarised, full log in `.work/gateway/` | `.github/copilot/scripts/<os>/gateway.*` |
| Runner | Never passes `--allow-all-tools`; refuses an agent with no profile; refuses a profile containing allow-all or a rule that allows an interpreter (`bash`, `pwsh`, `python`, `node`…) | `.claude/scripts/<os>/run-agent.*` |

These rules were verified against Copilot CLI's actual behaviour: unapproved tools are denied
automatically in non-interactive runs; a compound command (`&&`, `;`, `|`, `$(…)`) needs every part
approved; redirections are denied; shell rules match a command plus its first subcommand only.

Need another command for agents? Add it as a gateway check (`GATEWAY_EXTRA` in the config), never as a
shell allow rule. Need different write access? Edit the agent's `.flags` file (or have `/retro`
propose it).

---

## 5. Install into a project

Run from the directory that contains `agentic-pipeline/`.

macOS / Linux:
```bash
cp agentic-pipeline/pipeline.config.example my-project.config     # then edit it (PLATFORM="macos")
bash agentic-pipeline/install/macos/install.sh --config my-project.config /path/to/repo --dry-run
bash agentic-pipeline/install/macos/install.sh --config my-project.config /path/to/repo
```

Windows (PowerShell 7):
```powershell
Copy-Item agentic-pipeline\pipeline.config.example my-project.config   # then edit it (PLATFORM="windows")
pwsh -NoProfile -File agentic-pipeline\install\windows\install.ps1 -Config my-project.config -Target C:\path\to\repo -DryRun
pwsh -NoProfile -File agentic-pipeline\install\windows\install.ps1 -Config my-project.config -Target C:\path\to\repo
```

The installer:
1. Substitutes every `{{PLACEHOLDER}}` from the config (an empty value becomes "(not used in this
   project)" and agents skip rules about it) and **fails** if any placeholder survives.
2. Copies both agent editions (only the planner you chose), the commands, the `pr-scope-guard` skill,
   your platform's scripts, the permission profiles, the gateway and the scope budget. It refuses to overwrite a file you changed unless you pass
   `--force` / `-Force`.
3. Merges `.claude/settings.json`, writes a managed block into `AGENTS.md`, and adds `@AGENTS.md` to
   `CLAUDE.md`.
4. Creates the conventions doc, docs index and plans folder **only if they don't exist**, adds
   `.work/` to `.gitignore`, and starts `.work/friction.md`.

`--only github` (`-Only github`) installs just the Copilot part, `.github/agents` and `.github/copilot`,
into a repo that already has its `.claude/` pipeline.

Before the first run: write the conventions doc (every agent treats it as a checklist), fill in "Known
long-running or hanging commands" in `AGENTS.md`, review `gateway.conf`, and commit `.claude`,
`.github`, `AGENTS.md`, `CLAUDE.md` and `.gitignore`. To update later, re-run the same command.

---

## 6. Smoke test (Mode B)

In the target repo's root. The runner command depends on the OS:

| | macOS / Linux | Windows |
|---|---|---|
| Runner | `bash .claude/scripts/macos/run-agent.sh` | `pwsh -NoProfile -File .claude/scripts/windows/run-agent.ps1` |
| Gateway | `.github/copilot/scripts/macos/gateway.sh` | `.github/copilot/scripts/windows/gateway.ps1` |

1. **The gateway works:** `<gateway> list`, then `<gateway> lint`.
2. **Copilot reaches your model:** `copilot -p "Reply with the single word: ready" --no-ask-user`.
   With OpenCode, wrap it: `bash .claude/scripts/macos/with-opencode.sh copilot -p …` or
   `pwsh -NoProfile -File .claude/scripts/windows/with-opencode.ps1 copilot -p …`.
3. **The runner, agents and profiles work end to end:** write `.work/smoke/brief.md` containing "Run
   the gateway's git-status and lint checks, report the results, and change nothing.", then run
   `<runner> start developer .work/smoke/brief.md`.

Expected: `STATUS: DONE` and `FILES_CHANGED_DURING_RUN: (none)`, with the gateway output in the log
tail. If Copilot says the agent isn't found, run `copilot` once interactively in the repo root and
**trust the folder**.

---

## 7. Using it

### 7.1 `/feature <request>`: the governed cycle (Mode B)

In Claude Code, in the target repo, on a clean tree: `/feature Add CSV export of the orders list`.

| Step | Governor does | You |
|---|---|---|
| 0 Preflight | Checks the tree is clean, creates `feature/<slug>`, lists outstanding **(owner)** checks | Note the backlog |
| 1 Understand | Reads the touched code | Answer **one batched round** of questions, if any |
| 2 Plan | Briefs the planner and validates the plan | Answer the plan's open questions, if they're product calls |
| 3 Implement | Briefs `data-architect`, then `developer` | Nothing (runs in the background; ask "is it running?" any time) |
| 4 Verify | Re-runs lint, tests, build and invariant checks itself | Nothing |
| 5 Review | Runs `code-reviewer`, then its own review; up to 3 fix rounds | Nothing, unless a limit is hit or an agent reports a permission denial |
| 6 Ship | Commits, pushes `feature/<slug>`, opens a PR (never merges) | Review and merge the PR |
| 7 Wrap up | Checks status hygiene and writes the friction summary | Run any **(owner)** checks the plan lists |

Artifacts: plans in your plans folder; briefs in `.work/<slug>/`; every run in `.work/runs/<RUN_ID>/`
(`output.log`, `exit`, `proxy.log`, git snapshots); process notes in `.work/friction.md`.

### 7.2 Mode A commands (Claude Code subagents)

| Command | Does |
|---|---|
| `/plan <request>` | Planner writes the plan file; one batched question round; no code |
| `/implement [plan] [phase]` | Runs the next phase with `data-architect` or `developer` |
| `/review [plan]` | `code-reviewer` verifies and **stops** (human checkpoint) |
| `/resume [plan]` | Re-establishes actual state (runs tests) and routes to the next step |
| `/run-pipeline <request>` | Plan → data → build → review, then one bounded mechanical-fix pass, then stops |
| `/retro [since]` | Turns `.work/friction.md` into proposed pipeline changes; applies only what you approve |

### 7.3 Watching runs yourself

`<runner> list` (every run), `<runner> status <RUN_ID>` (summary and HEALTH, returns at once),
`<runner> stop <RUN_ID>` (stops the run and its process tree); the live output is in
`.work/runs/<RUN_ID>/output.log`.

HEALTH reports log and diff idle time, diff size, the most repeated tool call, permission denials,
the most repeated line of prose, the most re-read file, how long an implementer has gone without
writing, model request and error counts (with the proxy), Copilot's token
totals when a run ends, hung child processes, and a saturated machine. The runner stops a run by
itself on `MAX_RUN_MINUTES` (`max_runtime`), on `REPEAT_STOP` repeats of one tool call (`loop`) or
`REPEAT_STOP` denials (`denied`), on one line of prose repeated `max(200, 5 × REPEAT_STOP)` times
(`filler`), when an implementer has changed no file after `NO_WRITE_STOP` minutes (`no_write`), or
when the log and the diff are both idle for `STALL_MINUTES` (`stalled`). `STOP_REASON`
says which.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No Copilot agent .github/agents/<name>.agent.md` | Wrong name, the other planner is installed, or the Copilot part is missing (`--only github`) |
| `No permission profile …` / `Refusing to run: … grants everything` | Working as intended: write or fix the agent's `.flags` file (no allow-all, no interpreter rules) |
| The agent reports "Permission denied" | Policy, not a bug. If the work really needs it, add a gateway check or widen that agent's `.flags`, deliberately |
| Copilot: agent not found | The folder isn't trusted: run `copilot` once interactively in the repo root and trust it |
| Copilot log: `custom agent markdown frontmatter is malformed` | A non-agent `.md` (e.g. a README) is in `.claude/agents/` or `.github/agents/` |
| `gateway: refused: …` | An argument pointed outside the repo, or a formatter was called without paths |
| `gateway: TIMEOUT` / exit 124 | Diagnose the check; raise its timeout in `gateway.conf` only if it is legitimately slow |
| `OpenCode proxy failed to start` | Node isn't on `PATH` for the governor's shell |
| 401 / 403 in `proxy.log` or the log tail | The key is missing or wrong; restart Claude Code after changing the environment |
| Windows: `… cannot be loaded because running scripts is disabled` | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| Claude Code keeps asking permission for runner calls | `.claude/settings.json` wasn't merged; re-run the installer |
| `install: unresolved placeholders remain` | A placeholder has no config key: add the key (even empty) to your config |
| `STOP_REASON: denied` | The agent kept trying commands its profile denies: re-brief with what it was after, or add a gateway check if the need is real |
| `STOP_REASON: filler` | The model degenerated into repeated text: re-run with a shorter, ordered brief (a smaller step) |
| `STOP_REASON: no_write` | The implementer only read: re-brief with code pointers (file + symbol per item), or set `NO_WRITE_STOP=0` for a deliberately read-only run |
| `gateway: REVERTED: … deleted tracked files` | An agent deleted files through a test or build; the gateway restored them. Make the deletions the plan needs yourself (governor) |

---

## 9. Security notes

- Copilot agents never get all tools: see §4. The weakest point is the gateway's check list, so
  keep its commands to build/test/lint tools whose arguments can't execute arbitrary code.
- Keys stay in your keychain or secret store and are stripped from the agents' shell environment.
  Config, `pipeline.env`, `settings.json` and the `.flags` files hold no secrets.
- `.work/` (briefs, logs, proxy logs) is gitignored; logs can quote code and command output.
- The OpenCode proxy listens on `127.0.0.1` only, on a random port, for the duration of one run.
