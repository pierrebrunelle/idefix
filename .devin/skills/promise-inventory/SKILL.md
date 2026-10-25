---
name: promise-inventory
description: Audit a system by extracting every promise it makes (to users, models, callers, operators) and grading each TESTED, CLAIMED, or UNENFORCED. The inventory is the deliverable, not a formal model. Use for architecture audits, "what does this actually guarantee" reviews, or before trusting a green suite.
---

# Promise inventory

A green suite measures the imagination of whoever wrote the checks. The
ground truth is the list of promises the system makes — in docs, help
text, wire formats, journal schemas, error paths — graded by what
actually enforces each.

## Method

1. **Extract.** Read docs and help text for user-facing promises; read
   code for internal invariants (bounds, cleanup, ownership, wire
   shape). One read-only pass per subsystem beats one deep read of the
   whole tree.
2. **Grade each promise:**
   - `TESTED` — a check fails when the promise is broken, demonstrated
     (or provable by construction).
   - `CLAIMED` — enforced in code but nothing demonstrates the
     enforcement can fire.
   - `UNENFORCED` — documented or implied, nothing enforces it.
3. **Demonstrate breaks** for anything graded TESTED that looks
   vacuous: a check that cannot fail proves nothing. Mutate the code
   under test, watch it go red, revert.
4. **Report** the table: promise, grade, evidence (file:line), the
   smallest check that would upgrade the grade.

## What this found here (first run)

- `pgrep -f "exec sleep 30"` orphan check: vacuous for months —
  post-`exec` cmdline is `sleep 30`.
- `--max-seconds` was soft (checked only at loop top, not during
  commands).
- Journal prefix invariant was CLAIMED not TESTED.
- Stub could not emit the failures that actually lost runs (false
  finish, unclosed `<tool_call>`): the suite passed while those failure
  modes stayed unreproduced.

## Rules

- The matrix is the deliverable. A formal spec (TLA+) is optional and
  usually worse than the inventory for a sequential loop.
- CLAIMED items are where the next bug lives; grade before trusting.
- Re-run the inventory after the architecture changes, not on a
  schedule.
