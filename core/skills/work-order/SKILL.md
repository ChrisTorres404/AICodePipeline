---
name: work-order
description: Create, advance, or close a work order. Use when the user asks to start a feature, spec something out, plan a change, open a WO, or close one out — and before writing implementation code for anything non-trivial.
---

# Work Orders

A work order is a folder, never a loose file. It carries the specification, the
task breakdown, the checklist, the implementation prompt, and — at the end —
evidence that the work was verified.

## Before creating one: search the playbooks

```bash
{{PIPELINE_ROOT}}/bin/playbook search "<the problem>"
```

If a work order already covers this, read it first. Most of the hard thinking
may already be recorded, including the mistakes. Starting from precedent is not
cheating; it is the reason the playbooks exist.

## Create

```bash
{{PIPELINE_ROOT}}/bin/wo new "<title>" [--size trivial|small|standard|large] [--series N] [--priority P0|P1|P2|P3]
```

Choose the size honestly and say which you chose. `trivial` is a one-document
change such as a typo or a config flip. `small` is one file, one function, a
SPEC is enough. `standard` is the full set. `large` adds SDK and UI documents.
Every size needs VERIFICATION to close; that never relaxes.

This creates the folder and the documents the size requires. Do not create them by
hand — the driver enforces naming and numbering that `bin/playbook` and the index
depend on.

Then fill in the SPEC **before writing code**. A spec that is written after the
implementation is a description, not a specification, and it will not catch the
design problem you are about to ship.

## Required documents

| Document | Holds |
|---|---|
| `SPEC` | Problem, current state, solution, file-by-file changes, acceptance criteria |
| `CHECKLIST` | Phased implementation steps, tickable |
| `TASK-BREAKDOWN` | Tasks with estimates and dependencies |
| `Prompt` | The implementation prompt for an AI session |
| `VERIFICATION` | Executed-test evidence — required before closeout |
| `CLOSEOUT` | What shipped, what changed, what remains |

Add `sdk-implementation` and `ui-implementation` when the work touches those.

## While working

```bash
{{PIPELINE_ROOT}}/bin/wo start <n>              # in progress
{{PIPELINE_ROOT}}/bin/wo block <n> "<reason>"   # blocked, with the reason recorded
{{PIPELINE_ROOT}}/bin/wo note <n> "<text>"      # dated session note in the spec
```

In git, commit the order's documents before `wo start`: it makes the order's branch and a worktree from
HEAD, and refuses while they are uncommitted. Work in the worktree it prints; run every `wo` command from
the main checkout. Merge the branch, then `wo verify` and `wo close` (verify tests the main checkout; close
refuses while the branch is unmerged).

## Verify

```bash
{{PIPELINE_ROOT}}/bin/wo verify <n> --run <suite.sh>
```

This is the **only** way a VERIFICATION document should come into being. With
`--run` the suite executes and the status is written from its exit code:
`EXECUTED — PASS` or `EXECUTED — FAIL`, with the log kept beside it. Without
`--run` the document says `NOT EXECUTED — PLAN ONLY`, and the Stop hook will
say so too. You do not type a status; the run does.

## Working with others

```bash
{{PIPELINE_ROOT}}/bin/wo publish <n>    # GitHub issue carrying the work order
{{PIPELINE_ROOT}}/bin/wo sync <n>       # push spec and status to the issue
{{PIPELINE_ROOT}}/bin/wo import <issue> # work order from an existing issue
```

The folder is the record; the issue is what teammates see. Verification runs
post their result there; close closes it.

## Close

```bash
{{PIPELINE_ROOT}}/bin/wo close <number>
```

This **refuses to run without a VERIFICATION document**. That is deliberate.
A closeout without executed-test evidence is a claim, not a record. If you are
tempted to work around the guard, the correct move is to run the tests.

## Promote

```bash
{{PIPELINE_ROOT}}/bin/wo promote <number>
```

When a closed work order is worth carrying to the next project, promote it.
It is copied into your project's playbooks with a catalog entry extracted from the
SPEC and CLOSEOUT. Then edit the **Pitfalls** lines. That is the part that
saves someone a week. Promotion refuses unverified work and work that fails
`bin/sanitize`.

## Status

```bash
{{PIPELINE_ROOT}}/bin/wo list            # SCTPVC completeness map per work order
{{PIPELINE_ROOT}}/bin/wo status <number> # which documents exist, which are missing
```

## Non-negotiables

- No placeholder implementations, no `TODO: later`, no `throw new Error('Not implemented')`.
- No code referencing files, tables, or columns you have not verified exist.
- Never report a test as passing without having run it and seen the output.
  `NOT EXECUTED — PLAN ONLY` is a valid and honest status. A false `PASS` is not.
