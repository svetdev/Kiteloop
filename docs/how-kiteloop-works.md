# How Kiteloop works

The operating model in one read: what the pieces are, what each one may do,
and where its controls live. This is the mental-model document — the how-tos
([`autopilot-runbook.md`](autopilot-runbook.md)), the API reference
([`control-api.md`](control-api.md)) and the execution model
([`how-work-flows.md`](how-work-flows.md)) sit under it. The picture version
is [`architecture-controls.drawio`](architecture-controls.drawio).

## Three kinds of things

Everything in Kiteloop is one of three kinds, and knowing which you are
looking at tells you how to deal with it:

- **Loops you configure.** The Planner's grooming loop and the fleet's run
  scheduler. They have switches, budgets and gates. You never talk to a
  loop; you arm it, bound it, or turn it off. (The
  [clean-code loop](clean-code-loop.md) is not one of these: it is a workflow
  an agent starts from a chat at your ask, and it ends at a human gate.)
- **Instruments you read.** The fleet board, the autonomy ladder, the
  Planner's report and pass history, an item's page, the suite record.
  Instruments are derivations of live state — reading one can never start
  anything, and every instrument reads the same derivation the API serves,
  so the app and a script can't disagree.
- **Agents you talk to.** Each project's worker and reviewer, and whatever
  agents you keep beside them. Conversation lives here and only here. An
  agent granted **Operator tools** can also read the instruments and work
  the controls on your ask — everything except resolving the human gate.

The app used to blur these (a "Coordinator" that seemed to be an agent, a
chat bolted to a loop, an advisory inbox doing a gate's job). The blur is
gone; if a surface seems to be two of these at once, that's a bug.

## The Planner fills the plan

The backlog is the plan. The Planner keeps it real and tells you what
happened — it coordinates nothing and runs nothing.

**Which projects it grooms** is arithmetic: open, not paused, worker and
reviewer assigned, and **opted into autonomous work** — then only projects
whose `ready` count is below the threshold, served emptiest queue first, then
longest idle. One pass serves at most three projects, tops each up to three
ready items, three drafts at most per project.

**What the drafts say** comes from two inputs you own, cheapest first: the
project's **goal** (one sentence, on the start screen's project card) and its
accumulated **`.kiteloop/coordinator-knowledge.md`** — lessons distilled from every
finished run, merged and capped, hand-editable, read back into both the
Planner's drafting and every run's worker and reviewer as background that
informs but never overrides an item's own spec.

**What guards the plan** is machinery, not a mode: every draft passes
`GroundingCheck` (its citations must resolve) and the Definition-of-Ready
(What/How/Validation, a `verify:`, a size) — what clears both files as
`ready`, the rest parks as `draft`. There is no advisory inbox; the gates
are the training wheels.

Three different things are called a gate across these docs: a **quality
gate** (`quality/`, the checks a diff must pass), a **pickup gate**
(`DefinitionOfReady` and `GroundingCheck`, which decide whether an item may
be run at all), and the **human approval gate** (`awaiting-approval` →
`done`, resolved by a person or by the `land` rung).

**When it stops**: twelve passes a day, the shared daily ceiling, and a
per-project hold after three consecutive passes that produced nothing
runnable — which lifts the moment you engage with that project.

## The fleet works the plan

**Nothing runs unattended without three explicit acts**: a daily autonomy
budget set (arming refuses without one, naming it — the same sentence in
the app and in the API's 422), the **Run work unattended** switch armed
(the confirm shows the opted-in projects, their next items in queue order,
and the ceiling), and each project's own **Autonomous** consent, on its
Autopilot tab and the fleet board. Capability is not consent: a worker/reviewer pair makes a project
*startable*; only its opt-in makes it *autonomous*. A human pressing Run,
or `POST /v1/runs`, is never gated by any of this.

**One item runs per project at a time**, in an isolated worktree, through
worker → reviewer → the approval gate → a merge that must verify green on
the merged tree (the item's own `verify:` plus the project's command,
both). A rejection returns the item to `ready` with the reviewer's reasons
as the next run's feedback; a merge nobody approved does not exist.

**When runs fail, evidence — not latches — stops the fleet**: failed runs
accumulate into a hold scoped to the project they were about, and the hold
expires the moment that project's queue changes for any reason other than
the failures' own bookkeeping. A pickup refusal spends nothing, counts
toward nothing, and is remembered against the item *as written* — the
item is skipped, not re-asked, until its text changes. Same-cause failures
across distinct items hold the project until something outside those runs
changes. No thresholds were invented for any of this; the retry ceiling
and the budgets that already existed carry the rest.

**Stopping by hand** is Pause fleet: holds every queue *and* refuses new
starts (unlike a project's Pause), lets in-flight runs finish at their own
gates, and reports "paused — all quiet" when nothing is stranded — which
is the safe moment to quit, rebuild, or walk away.

## The money

**One number bounds the day**: the Daily autonomy budget, in the fleet
drawer. Grooming passes and unattended runs draw from the same ledger, so what an
unattended overnight session — a queue left running with nobody watching —
can cost has one answer. A project's own **Budget**
(Autopilot settings; `budgetUSD` over the API) is a slice inside that pool,
never extra allowance — one number that bounds the project's day and, as the
session's hard stop, its sitting. It replaced the per-item cap, session cap,
cost margin and daily budget that used to be four settings; the per-item
ceiling is not a setting at all any more but derived from the ledger — the
size's measured band once the project has landed enough runs, an estimate
from the item's own size before then. Budgets gate *autonomous* work only; a human start is never refused for
money. And a budget an operator typed is an instruction, not an anomaly —
nothing "corrects" it.

## Agents, and the one thing they can never do

Any agent can be granted **Operator tools**: a scoped token
(`~/.kiteloop/operator-token`) injected into its environment, authorizing
the whole control API — read every instrument, tweak configs, set
priorities, start runs, steer a run in flight — **except the three endpoints
that resolve a human gate**: the two approve endpoints and
`POST /v1/backlog/land`, which merges a done item's branch that never landed.
All three answer 403 naming the scope. An agent that starts runs
and also resolves the gate could approve its own team's work; the human
gate stays human by construction, not by policy.

## The trust ladder

Five rungs, each one or two switches, each refusing without its
prerequisites — rendered live under "Autonomy, rung by rung…" in the fleet
drawer, where the first unmet rung names the control that advances it:

1. **Use Kiteloop by hand** — always true; Run starts an item.
2. **Projects that can run** — a worker and reviewer assigned.
3. **Grooming** — the Planner files gated drafts, within the ceiling.
4. **Running work unattended** — budget, arming, and per-project consent.
5. **Shipping unattended** — a consented project also auto-approves
   review-passed runs and auto-merges behind its verify.

A fresh install stands on rung one and runs nothing.

## The principles under all of it

- **Off by default; armed deliberately, with the facts in view.**
- **A claim expires with its evidence.** Holds end when the queue they
  described changes; refusals stand until the item's text changes; a
  notification about a state should die with the state.
- **No invented constants.** Bounds come from numbers an operator set or
  ceilings that already existed; absence refuses rather than defaulting.
- **One derivation, many surfaces.** The board, the API and the panel read
  the same functions; a refusal is the same sentence everywhere.
- **Refusals name what is missing.** "Set the daily autonomy budget first"
  beats a disabled control with no caption.
- **Measurements come only from instruments.** `docs/suite-status.md` is
  written by the suite script alone; a row nobody measured is a
  fabrication, and the same discipline applies to every ledger.
- **Names say what things do.** Pause fleet, not Quiesce; the Planner,
  not a Coordinator that coordinates nothing; asks-first, not advisory.
  Machine names (`/v1/coordinator/*`, stored keys) stay stable underneath,
  documented in pairs.

## Where everything is

| Question | Surface |
|---|---|
| What may run, on what budget, what has run | **Fleet drawer** (footer → Pause fleet box): switch, ceiling, board, starts, pause |
| What gets groomed, what happened today | **Planner panel** (start screen, or the Planner box): switch, report, passes |
| One project's story | Its **Autopilot tab** (agents, consent, its budget, Advanced) and its **card** (paused, goal) |
| One item's whole story | Its **page** — reachable from anywhere its name appears |
| Where do I stand | **The ladder**, in the fleet drawer |
| Headless, all of it | [`control-api.md`](control-api.md) — same state, same words |
