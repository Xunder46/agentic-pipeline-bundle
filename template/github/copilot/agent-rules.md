<!--
Standing rules for every Copilot agent run. The runner appends the sections that apply to the agent
to its prompt, so briefs never repeat them and a stale copy cannot spread from brief to brief.
A section applies when its heading is "## Every agent" or lists the agent's name in parentheses.
Change a rule here (through /retro), never in a brief. Lines inside these comment markers are not sent.
-->

## Every agent

Shell: your only shell command is the gateway, `{{GATEWAY}}`, spelled exactly like that and never
piped, chained or prefixed with `cd` (`{{GATEWAY}} list` shows the checks; each runs with its own
timeout). Everything else is denied by policy: read and search with your file tools. A denied command
is never retried, in any spelling, and never worked around: record what you needed under Open
questions. Exit 124 means a check timed out: diagnose it, never re-run it unchanged. If a fix fails
twice, stop and report; never run the same failing check a third time. Long output is saved under
.work/gateway/ and summarised: read that log by line range only when the summary is not enough.

Never use a test, a build or any other check to create, move or delete files or directories, or to do
anything else your tools deny. If the work needs a deletion, a new directory or another denied action,
list it under "Governor actions" in your final report and continue with the rest; the governor does it.
(A check that deletes tracked files is reverted by the gateway.)

Reading: every turn calls a tool; never write filler text. Read each file you need once, in large
ranges, and keep what you learned: do not re-read a section you already have unless you changed it.
Start where the brief's pointers say. Read in `.work/` only your brief and the gateway logs it names.

Git and pipeline: do not commit, push, reset or switch branches; do not touch .claude/, .github/,
AGENTS.md or CLAUDE.md.

## Implementers (developer, data-architect)

Work: write early. Make your first edit within the first few minutes, from the brief's pointers; read
further only to finish the item in hand. If a pointer is wrong, say so in your report and continue.
Do only the items your brief names. If the work turns out to need another phase, or a large file the
brief did not foresee, stop at a finished item and report what remains: long runs cost the most.

Files: create no scratch or probe files; remove one you made with `{{GATEWAY}} delete-scratch`. Run
formatters only on files you created, by explicit path. Edit existing files with minimal edits, then
check them with `{{GATEWAY}} git-diff --stat`: a diff bigger than your edit means undo and report.

Tests: no real-clock thresholds (bracket between timestamps, or poll to a deadline). Prove every new or
changed guard with the gateway, not by your own account: `{{GATEWAY}} prove-red HEAD test <test files>`
(or the base commit your brief names) runs your tests on the code without your change. It must say RED
AT, with an assertion failing for the reason the test guards; GREEN AT means the test proves nothing,
so strengthen it before you finish. Where the test cannot even compile without the change (new code),
use a mutation: record the original line, change it, see the test fail, restore the EXACT original,
re-run green; never end a step with a mutation applied. Paste the prove-red verdict lines in the
evidence file.
While working, run only the test files you touched (by path, or a filter); run the full suite once when
you believe you are done, and again only after a fix. Run another suite (a native or package suite)
only if this run changed its sources.
If a change turns an EXISTING test red that the plan did not predict, stop and report; do not edit that
test. If a step's text contradicts the plan's decisions, follow the decisions and log it in the Assumption Log.

Plan: update the plan's Progress table (one line per item) and Assumption Log as phases complete; put
baselines, suite outputs and red/green tables in the plan's .evidence.md, never in the plan.

Before finishing: `{{GATEWAY}} lint` clean, full `{{GATEWAY}} test` green (paste the real counts), the
project invariant checks clean ({{INVARIANT_CHECKS}}), and the plan's own residue sweeps.

## Reviewer (code-reviewer)

Create the plan's .review.md first, then append each finding as you find it. Spot-check the guards the
change adds with `{{GATEWAY}} prove-red <base commit> test <test files>`: a guard that is GREEN AT the
base proves nothing and is a critical finding. Run the full
`{{GATEWAY}} test` once and paste the counts; read the diff with `{{GATEWAY}} git-diff`, one file at a
time, once each.

## Planners (conductor, conductor-v2)

A seeded plan (the brief says so) already holds the governor's Decision Ledger, core scenarios and phase
outline: keep every seeded entry exactly as written, append new D/S entries after them, and expand the
phases. If a seeded entry looks wrong, keep it and raise it under Open questions with file:line evidence.
Write only at the paths your brief gives. Every phase item names its file and the symbol (function,
class or test) it changes, so implementers can start editing without research. No phase has more than
8 items: split a bigger one into part A and part B (each is one agent run). Do not measure or
maintain line counts.
