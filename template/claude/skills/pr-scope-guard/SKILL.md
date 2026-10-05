---
name: pr-scope-guard
description: Check a PR against the scope budget in `.github/copilot/pr-scope-budget.md`, and split oversized work instead of growing the plan. Use at every PR checkpoint - when a plan is written or handed off, after each implementation phase, and after a code review. Also use whenever a plan passes about 500 lines, a phase uncovers substantial unplanned work, or a review returns more than a handful of findings. When over budget, it brings the current PR to a stopping point and has the planner plan the remainder as separate PRs.
---

# PR scope guard

The budget, the rules on what belongs in a plan, and the split procedure are in
`.github/copilot/pr-scope-budget.md`. Read it first; this skill is how to apply it from Claude Code.

## 1. Measure (read-only and cheap)

- **The plan:** line count (`wc -l <plan>`); phases (`grep -c '^### Phase' <plan>`); ledger decisions
  and distinct scenario ids; which tracks it touches.
- **Growth since handoff:** the plan's line count at the commit that handed it off against now.
- **The diff:** production code against tests, fixtures and docs, with
  `git diff --shortstat <base> -- <paths>`. Compare it with the plan's Predicted Files.
- **The review:** findings by severity, and by kind (mechanical, design or decision).

You measure; planners never do. A planner asked to keep a plan's line count once looped 74 minutes
re-counting.

## 2. Decide

- **Within budget:** say so in one line and continue.
- **Over budget, or unsure:** split. Small PRs are cheap; an oversized one is not.

## 3. Split (budget file §3)

1. **Stopping point.** Every item is either done or not started; roll back half-done work. The suites
   are green. The work is committed (or left for the owner) as the cycle's rules say.
2. **Record it in the current plan, in 10 lines or fewer:** what is done, what moved, and the new plan's
   path.
3. **Plan the remainder.** Inside `/feature`, brief the Copilot planner (`{{PLANNER_AGENT}}`) through
   the runner; otherwise use the planner subagent. Create the new plan folder first (the Copilot
   create tool cannot make directories). The brief gives:
   - the current plan's path and the exact sections to read (the moved items, the relevant decision
     IDs, the findings), not the whole plan;
   - the moved scope, as a list;
   - "stay within `.github/copilot/pr-scope-budget.md`; if still over, write an index plan plus the
     first PR's plan";
   - whether the owner is available. If not: resolve questions with defaults marked "owner to confirm".
4. **Order.** Don't start building the new plan until the current PR has landed or is explicitly
   paused, unless the new PR has to go first.
5. **Report to the owner:**

   ```
   Scope check: <plan> — <N> lines, <P> phases, tracks <…>, <F> findings. Over: <triggers>.
   Stopping point: <done / rolled back>; <committed | left for the owner>.
   Split: <new plan path(s)> — <one line each>. Order: <new first | current first>.
   Needs you: <only if the split drops something user-visible from the current PR>.
   ```

## 4. Keep plans lean while briefing agents

- Implementers write evidence to `<plan>.evidence.md`, reviewers write findings to `<plan>.review.md`,
  both in the plan's folder. The plan keeps one-line checkboxes.
- Point each agent at the sections it needs (its phase, the ledger, the relevant scenarios and
  findings), never "read the whole plan".
