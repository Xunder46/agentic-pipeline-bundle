---
description: Turn the friction log into proposed pipeline changes (agents, commands, scripts, briefs). Proposes; applies only what the user approves.
argument-hint: [since YYYY-MM-DD, or a slug]
---

# Role

You run the pipeline retrospective. `/feature` records friction but is forbidden from changing the
pipeline; this command is the one place where the log becomes changes to `.claude/`, `AGENTS.md` or
`{{CONVENTIONS_DOC}}`.

Scope: $ARGUMENTS (empty = every entry since the last `### … · RETRO` marker in `.work/friction.md`)

## 1. Read, do not re-litigate
- Read `.work/friction.md` for the scope. Read the run logs it cites only by searching them for the
  quoted excerpt; never open a whole log.
- Group entries by **cause**, not by agent: runaway commands, loops, briefs that prescribed a wrong
  mechanism, review misses, green-but-wrong, scope/format collateral, status drift, owner-check backlog,
  provider/runner failures.
- For each group: count, total cost (minutes, fix rounds), and the entries' evidence IDs.
- **Economics first.** Run `{{STATS}} --since "<period start>"` and put its output at the top of the
  retro: tokens per changed line, where the tokens went (build / fix / plan / review), time to first
  edit, re-reads, long runs, automatic stops. Compare it with the previous retro's numbers before
  proposing anything; a change that does not move a number is not worth making. Then rank the period's
  runs by model requests and name the top five with their causes: cost tracks the number of requests
  (each re-sends the whole context), so loops, re-reads, long runs and open-ended briefs show up first.

## 2. Propose — one change per cause, smallest that would have prevented it
For each group, name the single file and the single change that would have stopped the most cost:
- a runner knob or check (`.claude/pipeline.env`, `.claude/scripts/run-agent.sh`)
- a standing agent rule (`.github/copilot/agent-rules.md`) or a review-focus line (`.claude/commands/feature.md`)
- an agent instruction (`.claude/agents/<name>.md`)
- a standing convention or invariant check (`{{CONVENTIONS_DOC}}`, `AGENTS.md`)
- a permanent guard in the repo (a test, a lint rule, a CI job) — preferred over any instruction,
  because instructions decay and guards do not

Prefer deleting or tightening an instruction over adding one. Reject any proposal that only restates a
rule an agent already broke; say what would make breaking it impossible or visible instead.

Present a numbered table: cause · entries · cost · proposed change · file · why it would have worked.
**Stop and wait** for the user to pick which to apply.

## 3. Apply only what was approved
- Edit exactly the approved files. Show `git diff --stat` afterwards.
- If `run-agent.sh` changed: `bash -n .claude/scripts/run-agent.sh` must pass.
- Append `### <YYYY-MM-DD> · RETRO` to `.work/friction.md` listing what was applied, so the next retro
  starts after it.
- Do not commit unless the user asks.
