# Kiteloop Success Metrics

Kiteloop's north-star capability is **autonomous backlog execution with quality
control** — a human *leads* a team of agents that work a backlog continuously and
safely. Progress is measured with four **SLIs**, each carrying an **SLO** target
and an **error budget** that governs how far we let autonomy expand.

This borrows the Google SRE discipline (SLI → SLO → error budget) rather than
inventing bespoke metrics.

## Framing: autonomy within an ODD

From self-driving (SAE J3016 autonomy levels + **Operational Design Domain**):
Kiteloop targets **L4 autonomy within a bounded ODD**. The agent runs *unattended*
only inside a defined domain — groomed items, size ≤ M, isolated branch, a
`verify:` check present. We **expand the ODD as the metrics prove out**; we never
claim autonomy outside it.

- ODD definition (Definition-of-Ready): [`CLAUDE.md`](../CLAUDE.md) → *Autonomy* section
- Execution model: [`docs/adr/0001-autonomous-run-model.md`](adr/0001-autonomous-run-model.md)
- How to run/operate: [`docs/autopilot-runbook.md`](autopilot-runbook.md)

## The scorecard

| # | Metric (what it proves) | SLI — how it's measured | SLO (initial — calibrate) | Source |
|---|---|---|---|---|
| 1 | **Unattended autonomy run** (endurance) | Longest continuous autopilot session that keeps advancing the queue with **0 human rescues** | **≥ 8h**, ≥ 6 items reach `awaiting-approval`/`done`, **0 rescues**, no node stalled > 20 min | control-API run log + `events.jsonl` |
| 2 | **Human-touch per item** (leverage) | (approvals + rejects + rescues) ÷ completed item | **≤ 1.0 approval** and **0 rescues** per item | `events.jsonl` + run log |
| 3 | **Quality** (control works) | (a) first-pass rate: % passing reviewer + `verify:` on the first worker attempt; (b) escaped-defect rate: % of *approved* items reopened within 7 days | first-pass **≥ 70%**, escaped **< 10%** | reject→rerun counts; `task-approvals.jsonl` (see below) |
| 4 | **Estimation accuracy** (predictability) | \|predicted − actual\| for duration and cost | within **±40%** for size ≤ M | `task-metrics.jsonl` / `task-estimates.jsonl` |

Definitions:
- **Rescue** = any human action other than an approve/reject decision: a restart,
  killing a stuck agent, re-configuring, or re-prompting. Rescues are the enemy of #1.
- **Completed item** = reached `awaiting-approval` or `done` via the worker→reviewer loop.

**How far back the sources reach.** `.kiteloop/events.jsonl` keeps **30 days**
(`EventBus.retentionAge`), the same window as the control-API run log
(`RunRecordStore.retentionAge`) that #1 and #2 read alongside it — so the two
always cover the same period. The window is applied when a project opens: events
older than it are dropped from the file then, and a measurement that needs to
reach further back has to be taken from a copy made before that. Transcripts are
shorter-lived still (seven days, `RunTranscriptStore.Limits.retention`).

### How #3b (escaped-defect rate) is measured

The two halves of #3 pull in opposite directions on purpose. Approving everything
on the first attempt scores a perfect (a) — (b) is what catches it. So (b) is
measured from what review *accepted*, not from what it looked at.

`EscapedDefectTracker` watches each open project's backlog for two **transitions**
and appends them to `~/.kiteloop/task-approvals.jsonl`:

- **approved** — the item reached `done`. That is the accepted state in both
  flows: a human clearing the approval gate, or the reviewer passing it when the
  project has the gate off.
- **reopened** — an item that had been observed reaching `done` came back to
  `ready`, `blocked`, `active`, or `in-review` (`EscapedDefectTracker.reopenStatuses`).
  Two neighboring statuses don't count: a return to `draft` un-files the item
  rather than reporting a defect against shipped work, and a return to
  `awaiting-approval` may be an auto-merge refusal bouncing it back rather than
  a defect that escaped review.

Transitions, not statuses: an item read as `ready` at one moment cannot tell you
whether it was ever approved, so the first look at a backlog only records the
baseline. Changes made outside the app count too — a hand edit to `BACKLOG.md`
that unchecks a done item is read on the next file-watcher reload.

**rate = reopens within the window ÷ approvals.** What each side does *not*
include is the point:

- **A reviewer rejection is not a reopen.** It goes `active`/`in-review` → `ready`
  without ever reaching `done`, so no approval precedes it. That is a first-pass
  failure, already counted by (a); counting it again here would charge one event
  to both halves and inflate the number the SLO is read from.
- **The window is 7×24h from the approval, inclusive.** A reopen exactly 7 days
  after counts; one second later does not. Late reopens are still recorded and
  reported as `lateReopened`, so a rate of 0% can be told apart from "everything
  came back, just on day 30".
- **An item never approved contributes nothing** — to neither side of the ratio.
- **A reopen the gate-retry loop re-approves within its own window is not
  counted either.** `MergeRetryChurn.genuine` runs over the recorded events
  before the rate is computed, and a reopen immediately followed by an approval
  within `MergeRetryChurn.window` (30 minutes) is dropped along with that
  approval: the approval standing before the bounce is the one still in force,
  so neither the reopen nor the approval that closed it is a new fact.
- **Re-approved work counts again — when the second pass is genuine.** Approve
  → reopen → approve → reopen is 2 approvals and 2 reopens as long as each
  reopen sits outside `MergeRetryChurn.window` of the approval before it: that
  second pass through review was its own chance for a defect to escape. A
  reopen the loop re-approves inside that window is the churn above, not a
  second pass, and counts as neither an approval nor a reopen.

Read it from `GET /v1/metrics` → `escapedDefects` (see
[control-api.md](control-api.md#get-v1metrics)). `rate` is `null` until something
has been approved — 0/0 is *not measured yet*, not 0%.

Two limits worth knowing before quoting the number. Every approval is in the
denominator, including ones made in the last seven days that have not had their
full window to come back yet, so the rate reads slightly low right after a burst
of approvals and settles as the window passes. And history recorded before this
existed is not backfilled: a reopen whose approval was never observed is skipped
rather than counted against a guessed date.

## Error-budget policy (the SRE loop)

The gap between SLI and SLO is the **error budget**. It governs autonomy expansion:

- **Inside budget** → widen the ODD (bigger items, more parallelism, longer unattended windows).
- **Budget burned** (e.g. a marathon — a long unattended run, eight hours or more, that
  `scripts/kiteloop-verify.py --marathon` drives — needed a rescue, or escaped-defect rate exceeded the SLO)
  → **freeze ODD expansion** and fix the failure mode before adding autonomy.

Rescue budget for an ODD promotion is **0**: an 8h run that needed unsticking does
not pass — whatever had to be unstuck is the next reliability bug to fix.

## Current baseline

| Metric | Baseline | Notes |
|---|---|---|
| 1 Unattended run | _unmeasured_ | No 8h run has been driven — the endurance number can only come from one. A hung node no longer blocks it: `BacklogAutopilot` ends a run with no progress for `stallTimeoutMinutes` (per-project, derived from its own worker phases and 20 until there are enough of them). |
| 2 Human-touch | _unmeasured_ | Approval gate exists; rescue tracking not yet instrumented. |
| 3 Quality | _unmeasured_ | Both halves instrumented — `GET /v1/metrics` → `firstPassRate` (a) and `escapedDefects` (b); no history yet. |
| 4 Estimation | partial | Learning engine records duration/cost; accuracy not yet reported. |

Fill these in by driving a marathon with `scripts/kiteloop-verify.py` against the
control API and reading `events.jsonl` + `task-metrics.jsonl`. With the app
running, the control API on and the project open:

```bash
scripts/kiteloop-verify.py --marathon kiteloop --hours 8 --auto-approve \
  --timeout-min 30
```

Its `marathon()` works the `ready` queue for `--hours` and prints the metric-#1
scorecard when the run ends — wall clock, items run, completed, blocked
(stalled), rescues, avg quality — and checks the zero-rescues SLO as
`marathon: zero rescues (SLO #1)`. `--auto-approve` is what keeps an unattended
run moving: without it — and with the project's autonomy dial at `propose`
rather than `land` — a reviewer-passed item parks at `awaiting-approval`
waiting for someone who is asleep. `--timeout-min` bounds the
wait on any one item (default 20). The spend circuit breaker is the project's
one budget, `budgetUSD`, set with `PUT /v1/autopilot` before the run. Add
`--worktree` (or `--auto-merge`, which implies it) to isolate each item on its
own branch, and `--json` to get the report as one JSON document on stdout with
the narration on stderr.
