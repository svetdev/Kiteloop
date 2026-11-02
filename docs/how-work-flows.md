# How Work Flows

Who decides what gets built, who builds it, and who lets it into `main`.

Two corrections to the obvious mental model are worth stating up front, because
both are load-bearing:

- **The Planner does not start runs.** It fills the queue. A person (or the
  control API) starts a run by hand; under the autonomy dial's `propose` or
  `land` rung the fleet's run scheduler starts runs unattended. There is no
  path from the Planner to `BacklogAutopilot.start`.
- **The autopilot does not approve its own work into `main`.** The reviewer's
  pass moves an item to `awaiting-approval`. Merging is a separate, optional step
  gated on a clean merge *and* a green verify of the merged tree — never on the
  reviewer's opinion.

```
   DECIDE                    WORK ITEMS                     EXECUTE
   ──────                    ──────────                     ───────

┌──────────────┐      ┌────────────────────────┐
│    Human     │      │  Project A             │
│              │      │   Epic ── item ── item │
│ • observe    │      ├────────────────────────┤
│ • prioritise │      │  Project B             │
│ • approve    │─────▶│   Epic ── item ── item │
│ • set budget │ groom├────────────────────────┤
└──────┬───────┘      │  Project C  (paused)   │
       │              │   Epic ── item ── item │
       │ configures   └───────────┬────────────┘
       ▼                          │
┌──────────────┐                  │  items reach `ready`
│   Planner    │─────────────────▶│
│  (portfolio) │   drafts + files │
│              │                  ▼
│ • sees every │        ┌──────────────────────┐
│   project    │        │  Pickup gate         │
│ • longest    │        │  • Definition-of-    │
│   idle first │        │    Ready             │
│ • paused =   │        │  • Grounding check   │
│   never      │        └──────────┬───────────┘
│ • daily      │                   │ runnable
│   budget     │                   ▼
└──────────────┘        ┌──────────────────────┐
       ▲                │  Run: a person, the  │  ← the Planner
       │                │  control API, or the │     cannot do this
       │                │  fleet scheduler     │
       │                │  (propose / land)    │
       │                └──────────┬───────────┘
       │                           ▼
       │                ┌──────────────────────┐
       │                │  Autopilot           │
       │                │  one item at a time, │
       │                │  per project         │
       │                │                      │
       │                │   worker ──▶ reviewer│
       │                │      ▲          │    │
       │                │      └──reject──┘    │
       │                └──────────┬───────────┘
       │                           │ reviewer passes
       │                           ▼
       │                ┌──────────────────────┐
       │                │  awaiting-approval   │
       │                └──────────┬───────────┘
       │                           │
       │           ┌───────────────┴───────────────┐
       │           │                               │
       │   autonomy: land                  off / propose (default)
       │           │                               │
       │           ▼                               ▼
       │  ┌──────────────────┐            ┌──────────────────┐
       │  │ clean merge AND  │            │ human approves   │
       │  │ green verify of  │            │ and merges       │
       │  │ the merged tree  │            └────────┬─────────┘
       │  └────────┬─────────┘                     │
       │           │ fails → left for a human      │
       │           ▼                               ▼
       │                        ┌──────────┐
       └────────────────────────│   done   │
          outcomes, cost,       └──────────┘
          merge rate feed back
```

## The four roles

The full operating model — what each piece may do and where its controls
live — is [how-kiteloop-works.md](how-kiteloop-works.md); this is the short
form.

**Human** — decides what matters: parks or unparks each project and sets its
goal, sets the budgets, approves work, and can always start a run by hand.
Paused is a hard stop nothing overrides. How far a project goes without them is
its **autonomy** dial — `off` is never picked up unattended, `propose` lets the
fleet start runs unattended and parks every review-passed run at the human
gate, `land` approves and merges them. The gate stays human by construction:
the two approve endpoints and `POST /v1/backlog/land` answer 403 to the
operator token.

**Planner** — portfolio-level, one per app (machine name `coordinator`, kept in
the `/v1/coordinator/*` paths and the stored keys). It watches every open
project, drafts items for whichever most deserves them, puts each draft through
the same two pickup gates a human-groomed item faces, and files what survives.
It never starts a run and never merges.

**Fleet** — the run scheduler (`Services/CoordinatorRunScheduler.swift`,
`Services/RunScheduling.swift`). Under `propose` or `land` it starts the next
`ready` item of an opted-in project unattended — inside the daily autonomy
budget, one run per project at a time, never a paused project — through the
same `BacklogAutopilot.start` a person's Run reaches. It chooses what to start,
and nothing else.

**Autopilot** — project-level, one item at a time. A worker implements, a
reviewer judges against the item and the rubric. Rejection returns the item with
feedback; a pass hands it to the approval step.

## The gates, in order

Six checks stand between a `ready` item and `main`: **Definition-of-Ready**
and the **grounding check** at pickup (`DefinitionOfReady`, `GroundingCheck` —
is the item shaped right, and does it cite things that exist); **did the
worker change anything**, asked as it hands off (`EmptyDiffHandoff`); the
**reviewer rubric**, whose findings are `blocking` or `advisory`
(`ReviewFindings`); **did the run produce anything**, before the approval
step (`RunWorkEvidence` — no branch or an empty diff is `blocked`, not
rejected, and leaves that stage only through groom); and, at the `land` rung
only, the **merge** — a clean merge *and* a green verify of the merged tree,
never the reviewer's opinion. What each one asserts, and the runs that made it
necessary, is [autonomy.md](autonomy.md); how the code does it is
[architecture.md](architecture.md#the-autopilot-run).

## Where the money is bounded

| Ceiling | Scope | On breach |
|---|---|---|
| Project budget (`budgetUSD`, the one number a person sets per project) | the project's day — and, as the session's hard stop, the sitting | hard stop: no next item starts |
| Per-item ceiling (derived from the ledger, not a setting) | one autopilot item | **advisory** — records the overrun, run continues |
| Daily autonomy budget (portfolio-wide) | every autonomous start and grooming pass | refuses to start, with the reason |

The per-item ceiling is advisory on purpose: killing an item mid-review destroys
work that has already been paid for. The project's budget is the one that
actually bounds an unattended overnight session — a queue left running with
nobody watching — inside the portfolio's. The budgets in full:
[how-kiteloop-works.md](how-kiteloop-works.md#the-money).

## What feeds back

Every finished item records its outcome, duration, cost and quality score. Those
records are what the portfolio report turns into the number that matters —
**merged ÷ filed** — which is the honest read on whether grooming is producing
value or motion.
