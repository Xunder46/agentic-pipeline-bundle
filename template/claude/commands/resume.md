---
description: Pick up a paused, blocked, or partially complete plan in a fresh session.
argument-hint: [plan file path or feature name]
---

Resume work on an existing plan:

$ARGUMENTS

Agents in this pipeline stop cleanly at phase boundaries when they approach a
context limit, and stop hard when blocked. This command picks that work back up
without re-planning it.

## 1. Locate and read the plan

Find the plan under `{{PLANS_ROOT}}`. If the argument does not resolve to
exactly one file, list the candidates and ask. Read it in full — decisions,
invariants, scenarios, progress, assumption log, feedback.

## 2. Establish actual state, not claimed state

The plan records what agents *said* they did. Verify before building on it:

- [ ] Run `{{TEST_CMD}}` and record the real pass/fail counts. A plan claiming a
      phase is Complete while the suite is red is wrong about that phase.
- [ ] Run `{{LINT_CMD}}`.
- [ ] Check whether the files a "Complete" phase predicted actually changed.

Report any disagreement between the plan and reality **before** continuing. That
gap is the most valuable thing this command finds, and building on top of it
silently is how a blocked pipeline produces confident wrong work.

## 3. Route on status

| Plan state | Action |
|---|---|
| `## Feedback` non-empty | **Stop.** Feedback is the planner's input. Report it and recommend `/plan` to fold it into a new iteration. |
| A phase marked **Blocked** | **Stop.** Surface the blocker verbatim. It was blocked for a reason; do not work around it. |
| Phase complete, not reviewed | Recommend `/review`. |
| Phase incomplete, no blocker | Continue with `/implement` for the next phase. |
| All phases complete and reviewed | Report the plan is closed. |

## 4. Never silently re-plan

If the work no longer matches the plan — scope drifted, decisions were
superseded in chat, the codebase moved underneath it — say so and recommend
re-planning. Do not quietly rewrite the plan to match what the code now does;
that destroys the record of what was decided and why.
