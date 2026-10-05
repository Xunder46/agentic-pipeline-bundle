---
description: Run the full build pipeline ({{PLANNER_AGENT}} → data-architect → developer → code-reviewer). Mechanical fixes are applied in one bounded pass; anything needing a decision stops for you.
argument-hint: <what you want built or fixed>
---

You are orchestrating the `{{PROJECT_NAME}}` development pipeline for this
request:

$ARGUMENTS

The shared plan file at `{{PLANS_ROOT}}/<feature>-plan/<feature>-plan.md` is the single source
of truth. Every agent reads it and writes back to it. **Track the actual path
the planner establishes** and make sure each later agent is given that same
path — agents that invent their own plan path silently fork the pipeline.

Run these subagents in strict sequence, by name. Do not skip a step, do not
reorder, do not run them in parallel.

## 1. Plan — `{{PLANNER_AGENT}}` subagent

- It asks **ONE** batched round of questions, each carrying a recommended
  default, so the user can answer "all defaults except Q3". Surface that round
  and **WAIT** for answers. This is a designed checkpoint, not a stall.
- Do not expect a second question round, and do not ask the user to approve the
  plan — the planner presents it and names the next handoff itself.
- Before continuing, confirm the plan carries per-phase **Done Criteria**,
  **Predicted Files**, and fixture-enumerated **Scenarios**. A plan missing
  these cannot be verified mechanically downstream. Send it back **once** with
  that reason rather than proceeding on an unverifiable plan.
- Run the `pr-scope-guard` skill on the plan. Over budget → stop and report the
  proposed split instead of building an oversized plan.

## 2. Data layer — `data-architect` subagent

- Skip this step entirely if the plan has no data-layer phase. Say that you
  skipped it and why.
- Before continuing, confirm it updated `## Progress` in the plan file.

## 3. Logic and UI — `developer` subagent

- The developer works from the planner's scenario register. **It does not run
  its own Q&A with the user.** If it reports the register is incomplete, that is
  a Blocked phase — go to failure handling, do not answer on the user's behalf.
- Before continuing, confirm it updated `## Progress` and that its handoff
  summary contains **actual pasted test pass/fail counts**, not a claim of
  success. A summary claiming green with no counts has not been verified; send
  it back once for the real run.

## 4. Review — `code-reviewer` subagent

Let it complete its full verification and produce its verdict.

Run the `pr-scope-guard` skill after each implementation agent and after the
review as well. If it calls for a split: stop where every item is done or not
started and the suites are green, plan the moved scope with the planner, and
report instead of continuing.

## Bounded auto-fix — exactly one pass

After the review, sort the findings into **mechanical** and **decision**.

- A finding is **mechanical** only if its correct form is fully derivable from
  something that already exists: the plan pins an exact value, or the fix is a
  test assertion with one obvious target (tightening a loose or absent
  assertion, asserting a value the plan already pins).
- **Test-only fixes are mechanical by default** — a wrong guess fails loudly in
  CI instead of shipping.
- A finding becomes a **decision** the moment the fix requires *choosing a
  user-visible value the plan did not pin* — a size, a threshold, a percentage,
  a label, an ordering. "e.g." and "tuned later" in a plan mean the value is
  **not** pinned. Never invent one.

Invoke `developer` (or `data-architect`, per the finding's layer) **once** to
apply only the mechanical fixes, then re-run `{{TEST_CMD}}` and `{{LINT_CMD}}`
and report the real counts. Do not re-invoke the reviewer. Do not start a second
pass — one pass, then stop regardless of outcome.

If a mechanical fix turns out to depend on an unresolved decision finding, leave
it alone and say so. Do not partially apply it.

## Hard stop — the single human gate

After the bounded auto-fix pass, **STOP**. Present:

1. The reviewer's full verdict
2. Which findings were auto-fixed, and what the test run reported afterward
3. Which findings are left for the user, and **why each one needs a decision**

Do **not** start a fix→review→fix loop. Any further cycle is started manually by
the user in a separate run.

## Failure handling

- If any agent marks a phase **Blocked** or writes a `## Feedback` note saying it
  could not complete the work, **STOP immediately** and surface it verbatim.
- Never retry a failed agent or operation blindly. If the same operation fails
  twice, treat it as stuck: stop and report what happened.
- If the auto-fix pass leaves the suite red, **STOP** and report it. Do not
  attempt a follow-up fix.
- A hang, a timeout, or a run you killed is a **failure**, not an inconclusive
  result. Report it as such.
