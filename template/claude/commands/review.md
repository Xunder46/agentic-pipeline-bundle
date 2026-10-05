---
description: Review completed work against the plan, the conventions, and the architecture. Assesses and plans fixes; does not apply them.
argument-hint: [plan file path or feature name]
---

Invoke the `code-reviewer` subagent to verify the completed work:

$ARGUMENTS

If an argument is given, point the reviewer at that plan file or feature. If not,
find the in-progress plan under `{{PLANS_ROOT}}` whose phase is most recently
marked Complete. If that is ambiguous, list the candidates and ask.

## This run does not fix anything

The reviewer assesses and plans fixes. **No source code is edited in this run** —
not by the subagent, not by you. If the user wants the findings applied, that is
a separate, explicit instruction.

## Do not let the review shortcut its own checks

Before accepting the verdict, confirm the reviewer actually ran the checks that
are most often skipped:

- [ ] **It ran the test suite itself** and reported real counts — it did not take
      the implementer's word for it
- [ ] **Documentation falsification ran**, even though the change may have
      touched no documentation at all. A code-only change is the normal way
      documentation becomes false. A review that skipped this step because there
      was no doc diff has reproduced the exact bug the step exists to catch.
- [ ] **Scenario tests were checked for fixture conformance**, not just for
      existence. A test running on a trivial fixture does not cover a scenario
      whose fixture specifies near-duplicates or legacy rows.
- [ ] **The diff was compared against Predicted Files** in both directions —
      out-of-bounds files and untouched predicted files are both findings

If any of these was skipped, say so plainly in your report rather than passing a
verdict that rests on unrun checks.

## Terminal checkpoint

The reviewer is the end of the pipeline. When it finishes:

- Present its full findings
- **STOP.** Do not invoke another agent to fix anything.
- Wait for the user's explicit instruction

The user decides: approve, send findings back to an implementer, or re-plan.
