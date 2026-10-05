---
description: Implement the next phase of an existing plan (data-architect and/or developer). Does not plan and does not review.
argument-hint: [plan file path or feature name] [phase]
---

Implement work from an existing plan:

$ARGUMENTS

## Locate the plan

If the argument names a plan file, use it. If it names a feature, look under
`{{PLANS_ROOT}}`. If neither resolves to exactly one file, list the candidates
and ask which — do not guess, and do not create a new plan file.

**If no plan exists**, stop and say so. Offer `/plan` instead. Implementing
without a plan means implementing without a scenario register, which the
developer agent will refuse anyway.

## Route by phase

Read the plan's `## Progress` and `> Next handoff` to find the next incomplete
phase, then invoke the subagent that phase names:

| Phase touches | Subagent |
|---|---|
| Models, persistence interface, storage implementations, migrations, seed data | `data-architect` |
| State, business logic, screens, components, navigation | `developer` |

If the argument names a specific phase, run that one instead. If a phase spans
both, run `data-architect` first, then `developer` — never in parallel, and
never merged into one agent.

## Before reporting back

- [ ] The plan's `## Progress` is updated and the phase is marked **Complete** or
      **Blocked**
- [ ] The handoff summary contains **actual pasted test pass/fail counts**, not a
      claim of success. "All green" with no counts has not been verified — send
      it back once for the real run.
- [ ] For a bug fix: the new test was shown to **fail without the fix**. A test
      that passes both ways proves nothing.
- [ ] Anything touched outside the phase's **Predicted Files** is called out with
      a reason

## Stop conditions

If the agent marks the phase **Blocked** or writes a `## Feedback` note, stop
immediately and surface it verbatim. Do not retry blindly, do not work around
the blocker, and do not answer a product question on the user's behalf.

This command does not review. Run `/review` when the phase is complete.
