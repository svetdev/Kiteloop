# ADR-0001: Autonomous runs use the sandbox → PR → human-gate model

- **Status:** Accepted (2026-08-01)
- **Since (2026-10-01):** worktree isolation is no longer a setting. A
  project whose root is a git repository always runs its items in a worktree;
  a plain directory, which has no worktrees to run in, runs in the live tree
  and the run log says why. The `useWorktree` toggle is gone, and a config file
  or `PUT` that still names it is ignored.
- **Since (2026-09-20):** the auto-merge opt-in is the
  autonomy dial's `land` rung (`autonomy: off | propose | land`, off by
  default); `autoMergeOnApproval` still sets it, deprecated for one release.
  The gate the merge runs behind is unchanged.
- **Deciders:** the maintainer

## Context

Kiteloop's goal is unattended, continuous backlog execution. Today the autopilot
worker edits the **live project tree** directly, with a human approval gate on the
backlog item. That is unsafe to run unattended: a run can make broad, unreviewed
changes to `main`, and there is no isolation, no per-item boundary, and no revert
seam.

The autonomous-coding-agent industry has already converged on one operating model:
an agent works in an **isolated environment**, produces a **pull request**, and
**automated checks + human review gate the merge** — with no direct push to `main`.
This is the shape used by Devin, Factory, GitHub's Copilot coding agent, OpenHands,
and Cursor background agents. It is also just **branch protection + required status
checks + CODEOWNERS review** (standard CI/CD) applied to an AI author.

## Decision

Every autonomous item run executes under this model:

1. **Isolation** — the run happens in a dedicated git **worktree** on a branch
   `kiteloop/<item-id>`, branched from fresh `origin/<default>`. The worker never
   edits `main` directly.
2. **Output is a PR** — the run's deliverable is the branch, surfaced as a pull
   request (v1 may open the PR; auto-merge is out of scope).
3. **Three gates to `done`**, in order:
   - the item's **`verify:`** check (required status check),
   - the **reviewer agent** against the Definition-of-Done rubric (`CLAUDE.md`),
   - **human approval** (`awaiting-approval` → `done`, drivable via the control API).
4. **No auto-merge in v1.** Merge is a human/CI action; a conflicting or failed run
   flips the item to `blocked` with the branch left intact for inspection.

## Implementation status

Isolation shipped: `WorktreeManager` is wired into the autopilot through
`WorktreeSession`, for every project whose root is a git repository — not
behind a toggle (see *Since (2026-10-01)* above). Full model:
[`worktree-isolation.md`](../worktree-isolation.md). Two deliberate departures
from the decision above:

- The worktree branches from the **project root's `HEAD`**, not from a freshly
  fetched `origin/<default>` — Kiteloop does not touch the network on a run.
- Auto-merge exists as an **opt-in** (`autoMergeOnApproval`, off by default),
  gated on a clean `--no-ff` merge plus a green verify on the merged tree, with a
  rollback on failure. The default path is still the human gate this ADR chose;
  the flag is for deliberately unattended queues.

The run's deliverable is still the branch — no PR is opened.

## Consequences

**Positive**
- Safe to run **unattended** (the #1 endurance SLO) — a bad run is contained to its
  branch, never reaching `main`.
- One branch/PR per item gives a clean **audit trail** and trivial **revert**.
- Directly implements guardrail gates 2 (isolation) and 5 (human approval).

**Costs / follow-ups**
- Requires wiring `WorktreeManager` into the autopilot dispatch, a merge-back/PR
  service, and base-branch handling (see the Autonomy Guardrails epic:
  `branch-per-item`).
- Parallel branches can conflict pairwise → PR-per-item defers integration to a
  human/CI, which is acceptable for v1.

## Alternatives rejected

- **Edit the live tree** (today's behaviour): unsafe unattended; fails #1.
- **Auto-merge on green**: removes the human gate; fails the quality SLO (#3) and the
  "human leads" model (#2).

---

*Addendum 2026-08-17: "no PR is opened" describes v1 as decided; an
opt-in `openPullRequest` setting has since shipped and is documented in
`control-api.md`. The sandbox → review → human-gate model itself is unchanged.*
