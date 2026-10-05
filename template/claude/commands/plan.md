---
description: Plan a feature or fix without implementing it. Produces the shared plan file and names the next handoff.
argument-hint: <what you want built or fixed>
---

Invoke the `conductor` or `conductor-v2` as necessary subagent to plan this request:

$ARGUMENTS

Planning only. **No source code is written in this run**, by the subagent or by
you — if the planner starts implementing, stop it.

What to expect, and what to check before reporting back:

- The planner classifies the request first. If it calls the request **TRIVIAL**,
  it will say so and recommend skipping straight to `/implement`. Relay that
  recommendation rather than pushing a full plan the user does not need.
- It asks **ONE** batched round of questions, each with a recommended default so
  the user can answer "all defaults except Q3". Surface that round and **WAIT**.
  Do not answer on the user's behalf, and do not pre-empt the questions by
  guessing from the codebase — the planner has already excluded anything it
  could resolve itself.
- It presents the plan and names the next handoff. **Do not ask the user to
  approve the plan.** That gate is deliberately absent.

Before reporting back, confirm the plan file at `{{PLANS_ROOT}}/<feature>-plan/<feature>-plan.md`
exists and each phase carries:

- [ ] **Done Criteria** — runnable commands, not prose
- [ ] **Predicted Files** — the diff target for review
- [ ] **Scenarios** with enumerated **fixtures**, including the adversarial data
      (duplicates, near-twins, legacy rows, empty sets)

A phase missing any of these cannot be verified mechanically downstream. Send it
back **once** with that specific reason rather than accepting it.

Then run the `pr-scope-guard` skill. An over-budget plan becomes an index plan plus
the first PR's plan before anything is built.

Report: the plan file path, the phase list with its owning agent, and the named
next handoff.
