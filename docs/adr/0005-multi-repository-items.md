# ADR-0005: Multi-repository items — one item, matching branches in several repositories, one gate

- **Status:** Proposed — decision only, no code shipped
- **Deciders:** the maintainer
- **Related:** [ADR-0001](0001-autonomous-run-model.md) (the sandbox → review →
  human-gate model this stays inside), [ADR-0004](0004-parallel-disjoint-runs.md)
  (one run at a time per project, which this keeps),
  [`worktree-isolation.md`](../worktree-isolation.md),
  [`backlog-format.md`](../backlog-format.md)

## Context

A project is one git repository. An item's run gets one worktree on one branch,
`kiteloop/<item-id>`, forked from the project's base; its diff, its verify and
its merge are all read from that one repository, and anything the worker
changes outside it is refused as stray work (`RunWorkEvidence.strayWork`).

Some features do not fit in one repository: a library change that needs its
reference app changed with it, a client and the server it calls. Today such a
feature is two items in two projects. Each is verified against the other
repository as it happened to stand, each reaches its own gate, and nothing
says the two belong together — one can land while the other is rejected.

What a person wants is one item: the branches made together, verified
together, and approved or rejected together.

## Decision

**Companion repositories, named by the project and opted into by the item.**

1. **The project names its companions.** `.kiteloop/config.json` gains
   `companions`: a list of `{ "name", "path", "baseBranch"? }`, each a git
   repository on this Mac. A companion is not a project of its own for the
   run's purposes: it has no backlog, no autopilot and no gate here.
2. **An item says which it touches.** A `repos:` list in the item's detail
   frontmatter, naming companions. An item without it is today's item,
   unchanged. Naming a companion the project does not have is refused at
   pickup with the name, as any other Definition-of-Ready clause is.
3. **One branch name, one worktree per repository.** The run creates
   `kiteloop/<item-id>` in the project and in each named companion, each
   forked from that repository's base. The companions' worktrees are made
   under the project's own worktree, at `.kiteloop/repos/<name>`, so the
   worker and the reviewer see one tree and a path names its repository.
4. **One verify, in the project's worktree.** The item's `verify:` runs once,
   from the project's worktree, with the companions at their relative paths.
   There is no per-companion verify: what proves the feature is the one
   command that exercises all of it.
5. **One diff, one gate.** The run's diff is each repository's diff against
   its own merge base, under a heading naming the repository. The reviewer
   reads all of it; the human gate shows all of it; approve and reject apply
   to all of it.
6. **Landing is all or nothing.** The merge gate prepares and verifies a merge
   commit in every repository before moving any ref. Refs then move by
   compare-and-swap, the project last. If one refuses — its base advanced, its
   base is checked out elsewhere — every ref already moved is put back by the
   same compare-and-swap, and the item returns to the gate with the refusing
   repository named.
7. **Stray work keeps meaning what it means.** A change in a companion the
   item named is the item's work. A change in one it did not name, or anywhere
   else, is still stray.

## What this deliberately leaves out

- **Remotes.** As with a single repository, nothing fetches or pushes;
  pull-request publishing for companions is a later decision.
- **Running two items at once.** A companion in use by a run is in use; the
  rule stays one run at a time per project, and two projects sharing a
  companion are held apart by the branch already existing.
- **Companions as projects.** The same repository may also be open as its own
  project with its own backlog. Its checkout is never switched; only its refs
  move, as a base branch not checked out moves today.

## Consequences

- The worktree lifecycle, the diff base, the work evidence, the merge gate and
  the sweeps that clean up after a run each learn that a run may span several
  repositories. That is most of what makes a run safe, so this is built behind
  the item's opt-in and leaves a single-repository run on the code it runs
  today.
- A verify that needs a companion's build products needs them built in the
  companion's worktree; the cold-worktree problem a single repository has is
  multiplied by the number of companions.
- Rollback by compare-and-swap covers refs. It does not cover a checkout that
  a person fast-forwarded by hand between the two moves; that window is
  refused, not repaired.

## Alternatives considered

- **Git submodules or a superproject.** One repository again, so nothing in
  the run changes — but it changes how every contributor works with the
  repositories, to serve a tool.
- **Linked items** (`needs:` across projects, each with its own gate). Already
  expressible within one project; across projects it orders the work without
  verifying it together, which is the thing asked for.
- **One worktree per repository, side by side.** Simpler to create, but the
  worker's paths and the item's `verify:` would then depend on where Kiteloop
  chose to put each one.

## Order of work

1. Config and Definition-of-Ready: `companions`, `repos:`, the refusals.
2. Worktrees and the combined diff, with landing refused for a multi-repository
   item — it stops at the gate and is merged by hand. Useful on its own.
3. The all-or-nothing landing.
4. The phone's gate review, one section per repository.
