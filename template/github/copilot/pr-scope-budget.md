# PR scope budget

A PR's plan must stay small enough to plan, build, review and land in one pass. A plan that runs to
thousands of lines is several PRs in one file, or a feedback loop. This file sets the budget and says
what to do when a PR outgrows it.

It binds every role: the planner, the implementers (data-architect, developer, in Claude Code or
Copilot), the reviewer, and the governor. In Claude Code, the `pr-scope-guard` skill runs this
procedure.

Why size matters for cost as well as quality: every agent re-reads the plan, often many times in one
run (8 to 40 reads per run were measured), and every model request re-sends the agent's whole
context. Plan length multiplies the cost of every run that touches it.

The numbers below are defaults. Tune them for your project, and record why.

---

## 1. Budget

### At handoff: the plan is written, no code yet

Split if **any** hard limit is hit:

- the plan is over **800 lines**;
- more than **5 implementation phases**;
- more than about **1,500 lines of predicted production code** (tests, fixtures and docs don't count).

Split if **two or more** soft signals are present:

- the plan is over 500 lines;
- more than 3 phases;
- more than one track: separately built or deployed parts (for example an app and a server, a
  client and a shared contract). A contract change may ride with its first consumer;
- more than 20 ledger decisions, or more than 30 scenarios;
- planning found a missing prerequisite: something the feature assumes exists and doesn't.

### During implementation

Stop and split when:

- the plan has grown more than **150 lines** past its handoff size, which means evidence is leaking
  into it (see §2);
- a phase uncovers **substantial unplanned work**: a missing prerequisite, a defect that needs its own
  design, a new model, message, screen or migration the plan doesn't have, or anything that would
  need a new phase;
- the actual production diff exceeds the plan's prediction by more than half.

### At review

Split when:

- there are more than **6 substantive findings** (nits don't count);
- a design finding spans layers or needs scenarios of its own;
- a **second review round** would be needed on the same PR.

---

## 2. What the plan holds

Every plan is a folder, `{{PLANS_ROOT}}/<plan-name>/`, named after the plan file without `.md`. It
holds the plan, `<plan-name>.evidence.md` and `<plan-name>.review.md`. A series index is a single
file beside the plan folders.

- **The plan:** decisions, requirements, scenarios, and phases with Done Criteria; Open Items; a
  Progress checklist with **one line per item**, stating its result; Assumption Log entries of at
  most 3 lines each.
- **`<plan-name>.evidence.md`:** baselines, suite outputs, red→green tables, footprints, the detail
  behind Assumption Log entries. Implementers write here, not into the plan.
- **`<plan-name>.review.md`:** the reviewer's findings. The plan's `## Feedback` holds only a pointer
  to it and the fix checklist.

---

## 3. When a trigger fires

Never grow the current plan to absorb new scope or another round of feedback. Instead:

1. **Reach a stopping point.** Finish or roll back the item in progress, so every item is either done
   or not started. Get the suites green.
2. **Record it in the current plan, in 10 lines or fewer:** what is done, what moved, and where it
   went.
3. **Plan the rest separately.** Hand the planner the moved scope, the decision IDs and findings it
   depends on, and this budget. If that plan would itself be over budget, the result is an index plan
   plus the first PR's full plan (below).
4. **Order the PRs.** If the current PR can't ship without the moved work, the new PR goes first and
   the current one pauses (say so in its Progress section). Otherwise the current PR lands trimmed and
   the new one follows.
5. **Tell the owner:** the signals measured, the split, and the new plan paths. Ask first only if the
   split removes something user-visible from the current PR.

### Over budget at planning time

Write a **PR series**: a short index plan of at most 100 lines (for each PR: order, a one-line scope,
dependencies, and the decisions the PRs share), plus a full plan for the **first PR only**. Plan each
later PR when its turn comes, against the code as it is by then.

### Over budget at review time

In this PR, fix only the critical findings and the cheap mechanical ones, in one round. Everything
else becomes a follow-up PR plan. No review → fix → review loops.
