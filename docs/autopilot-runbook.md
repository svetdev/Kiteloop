# Autopilot Runbook

How to run and operate Kiteloop's autopilot, including headless control via the
local API. (Diátaxis: this is a *how-to*. For targets see
[`success-metrics.md`](success-metrics.md); for the execution model see
[ADR-0001](adr/0001-autonomous-run-model.md).)

Several rules below carry a date. Each is a run that went wrong in exactly that
way, and the dates are kept on purpose: a rule you can trace to its incident is
one you can judge, and one you can decide you don't need.

## Prerequisites

A fresh install runs nothing: grooming and unattended running are off until a
human arms them, arming refuses without a daily budget to spend against, and
each project joins autonomous work only by its own opt-in (the **Autonomy**
dial on Project Settings → Autopilot, or `autonomy` over the API —
`autonomousWorkEnabled` still answers there, deprecated for one release).

- The app is running.
- The target project is open, with a **worker** and **reviewer** agent that have
  live sessions.
- The item you want to run is `ready` and inside the **ODD / Definition-of-Ready**
  (see `CLAUDE.md`): has What/How/Validation, a `verify:` command, size ≤ M.
- For an *unattended* queue, macOS privacy prompts are cleared one time up front —
  otherwise the first read of a project in `~/Documents`, `~/Desktop` or
  `~/Downloads` stalls the item behind a modal dialog:
  [`unattended-permissions.md`](unattended-permissions.md).

## A. In the app

Three surfaces, one question each — the map is also in
[`architecture-controls.drawio`](architecture-controls.drawio), and the
**autonomy ladder** ("Autonomy, rung by rung…" in the fleet drawer) shows live
which rung you are on and names the control that advances you.

**A project's Autopilot tab — this project's story.**

1. Open the project → **Autopilot** sidebar tab.
2. Pick **Worker** and **Reviewer** in the two pickers — the project is now
   *startable* by hand.
3. Optional: the **Autonomy** dial on **Project Settings → Autopilot**, which
   the gear on the tab opens — `Off` / `Propose` / `Land`, off by default; a
   human ▶ Run never asks. *Propose* lets the fleet pick the project up
   unattended and parks a review-passed run at the approval gate for you;
   *Land* approves it without asking and merges. The row under the tab's
   title keeps one switch for it, **Autonomous**, for the person watching the
   fleet — it is the dial's first rung, not a separate setting — beside
   **Paused**, the fleet board's switch that parks the project.
4. **This project's budget**, on the same page, is the project's one ceiling —
   a day's spend that also bounds a sitting — shown under the portfolio
   ceiling it sits beneath; the per-item ceiling is derived from the ledger
   ([`how-work-flows.md`](how-work-flows.md#where-the-money-is-bounded)).
5. Select the `ready` item(s) in the queue → **Run** (▶); watch
   **Console → Activity** and **Traces**; on `awaiting-approval`, review the
   diff and approve/reject.

**The fleet drawer (sidebar footer → Pause fleet box) — what runs, on what
budget.** The **Run work unattended** switch (arming confirms with the
opted-in projects, their queue heads, and the ceiling), the **Daily autonomy
budget** — the one number bounding grooming and unattended running together —
the **consent roster** (every open project's opt-in, same setting as step 3),
the autonomous-starts history, and **Pause fleet / Resume**.

**The Planner panel (start screen, or the Planner box) — what gets
groomed.** **Groom the backlog** — the switch is the whole choice: on files
gated drafts within the shared ceiling, off doesn't — pass history, and the
day's report. Unattended running is deliberately *not* here: the Planner
knows and feeds; the fleet runs. (Machine name `coordinator`: the
`/v1/coordinator/*` endpoints and stored keys keep that spelling, the way
`/v1/fleet/quiesce` keeps `quiesce` for **Pause fleet**.)
To *steer* — discuss priorities, ask why nothing is moving, have the answer
applied — talk to a team agent granted **Operator Tools** (agent settings):
it reads the same fleet state through the control API, keeps its memory
between conversations, and can act on what you decide, short of resolving a
human gate.

Neither loop arms without the daily autonomy budget — the switch refuses,
naming it, with the same sentence the API returns.

## B. Headless via the control API

Enable **Settings → Local Control API** (starts a token-guarded server on
`127.0.0.1:4517`). Full endpoint reference: [`control-api.md`](control-api.md).
To run these from another machine or a phone, see [Remote access](#remote-access).
Then:

```bash
TOKEN=$(cat ~/.kiteloop/control-token); H="Authorization: Bearer $TOKEN"; B="127.0.0.1:4517/v1"

curl -s 127.0.0.1:4517/health
curl -s -H "$H" "$B/backlog?project=<name>"                 # statuses
# open a project / summon agents / wire autopilot if needed:
curl -s -H "$H" -d '{"path":"~/path/to/project"}' $B/projects/open
curl -s -H "$H" -d '{"project":"<name>","name":"Builder","model":"opus"}' $B/agents
curl -s -H "$H" -X PUT -d '{"project":"<name>","worker":"<id|name>","reviewer":"<id|name>"}' $B/autopilot

# run → monitor → result
RUN=$(curl -s -H "$H" -d '{"project":"<name>","item":"<item-id>"}' $B/runs | jq -r .runId)
curl -N -H "$H" $B/runs/$RUN/events                          # live SSE
curl -s -H "$H" $B/runs/$RUN/result
curl -s -H "$H" -d '{"approve":true}' $B/runs/$RUN/approve   # this run's gate — see below
```

**Running on a branch other than the checkout's.** Name it once, per project,
and leave the checkout alone:

```bash
curl -s -H "$H" -X PUT -d '{"project":"<name>","baseBranch":"quality/rebased"}' $B/autopilot
curl -s -H "$H" $B/projects | jq '.projects[] | {name, baseBranch}'   # what a run would use
```

Every run then forks its worktree from the local `quality/rebased`, reads its
diff against it, lands an approved merge on it — by fast-forward if the checkout
is on it, otherwise by moving the branch without touching the checkout — and
opens its pull request against it. `null` or `""` puts the project back on the
checkout's own `HEAD`, the default. Two refusals to know: a name no local branch
has blocks the next run at start, and a base checked out in another worktree
refuses the merge naming that worktree — remove it or merge there. Never switch
the checkout or register the same directory twice to get a run onto a branch;
that is what left a base checked out in a stale scratch worktree on 2026-09-03.
The model: [`worktree-isolation.md`](worktree-isolation.md#which-branch-is-the-work).

### Landing the work — the item gate

A run that ends at `awaiting-approval` has produced a branch and nothing more.
The call that merges it and marks the item `done` is the **item** gate:

```bash
curl -s -H "$H" -d '{"project":"<name>","item":"<item-id>","approve":true}' $B/backlog/approve
curl -s -H "$H" \
  -d '{"project":"<name>","item":"<item-id>","approve":false,"reason":"AC 3 unimplemented"}' \
  $B/backlog/approve
```

Two endpoints carry the word *approve* and they are not interchangeable; a
third lands what an approval left behind:

| | What it resolves | Reach for it when |
|---|---|---|
| `POST /v1/runs/{runId}/approve` | whichever gate that **live** run is holding — a mid-workflow node first, otherwise the item's | the `runId` is in hand and the app that started the run is still up |
| `POST /v1/backlog/approve` | the **item's** gate, addressed by project and id | everything else — above all a queue left at the gate by an app that has since restarted, whose old `runId`s answer 409 |
| `POST /v1/backlog/land` | the merge of a **`done`** item's branch that never landed | the item was approved without a merge — a `propose` project, or a half-set dial — and `GET /v1/backlog` names it under `strandedWork` |

The second is the one an operator ends up living in: a gate outlives the run that
opened it, and by the next morning the item id is the only handle still valid.

Approving merges the item's branch (when the project's dial is at `land` — or
`autoMergeOnApproval`, deprecated, is set) and marks it `done` only if that
merge is clean *and* the merged tree verifies green. Otherwise it is a **409**, the item stays at the gate rather than being
stamped done over work that did not land, and `reason` names the command that
refused with `verifyOutput` carrying its tail. Rejecting never merges — it
returns the item to `ready` with `reason` recorded as feedback the next run reads.

Clearing a night's output is that call over whatever is parked:

```bash
curl -s -H "$H" "$B/backlog?project=<name>" |
  jq -r '.items[] | select(.status == "awaiting-approval") | .id'   # then approve each
```

Terms, response shape and every refusal code:
[`POST /v1/backlog/approve`](control-api.md#post-v1backlogapprove).

### What every project is doing

One call answers "what is happening" for the whole app — each project's run state
and how much work it has left — instead of a `GET /v1/autopilot` plus a
`GET /v1/backlog` per project:

```bash
curl -s -H "$H" $B/projects |
  jq -r '.projects[] | "\(.name)\t\(.run.state)\t\(.run.item // "-")\trunnable \(.queue.runnable)/\(.queue.ready)\tgate \(.queue.awaitingApproval)"'
```

Read `runnable` before `ready`. `ready` counts items somebody *called* ready;
`runnable` is what the Definition-of-Ready gate (§C) would actually let autopilot
pick up. So `runnable 0/7` is a full queue nobody can run — it needs grooming,
not a start — while `runnable 0/0` is genuinely out of work and needs filing.
Nothing else tells those two apart in a single call.

Fields: [`GET /v1/projects`](control-api.md#get-v1projects).

### Keeping the queue fed

When projects sit idle with empty queues, check the refill loop before assuming a
ceiling stopped it — the throttle is often just the cadence:

```bash
curl -s -H "$H" "$B/coordinator/refill?limit=5" | jq '{enabled, checkIntervalSeconds, budget}'
curl -s -X PUT -H "$H" -d '{"checkIntervalSeconds":300}' $B/coordinator/refill  # look every 5m
curl -s -X PUT -H "$H" -d '{"enabled":true}' $B/coordinator/refill
curl -s -X PUT -H "$H" -d '{"dailyBudgetUSD":125,"maxPasses":60}' $B/coordinator/refill
```

`budget.exhausted` with `exhaustionReason` is the loop having stopped on a
ceiling you set; `enabled: false` is the shipped state and no upgrade turns it
on. An omitted field is left alone, so each line above changes only what it names.
Shortening the cadence costs model calls the loop would otherwise skip, which is
why the default stays at 900 seconds.

Fields and ranges: [`GET`](control-api.md#get-v1coordinatorrefill) ·
[`PUT /v1/coordinator/refill`](control-api.md#put-v1coordinatorrefill).

## C. Getting an item ready (Definition-of-Ready)

Autopilot checks the Definition-of-Ready at pickup and skips an item that misses
any of it, rather than spending a worker/reviewer cycle discovering there was
nothing to build against. An item is runnable when all of this holds:

| Requirement | Where it lives |
|---|---|
| Status is a pickup stage (default `ready`) | the `BACKLOG.md` item line |
| A detail file that parses | `backlog/<id>.md` |
| **What** and **How** sections | `## What` / `## How` in the detail file |
| At least one **Validation** criterion | `## Validation` (or `## Acceptance Criteria`), as `- [ ]` lines |
| A `verify:` command | the detail's `verify:` frontmatter, or the item line's `verify:` (which inherits `verify_default`) |
| A size of XS, S or M | `size:` on the item line, or the detail's frontmatter |

An unsized item is refused too: nothing says it's ≤ M. An explicit out-of-scope
list is part of the ODD but is **not** enforced — an empty one is a legitimate
statement and reads the same as an unwritten one.

### Writing the `verify:`

**It runs from the project root** (`WorktreeManager.runShell` runs it in the
worktree, or the project, root — never in a subdirectory), so every relative path
in it resolves from there. In this repo the Xcode project is
`Kiteloop/Kiteloop.xcodeproj`, so a bare `-project Kiteloop.xcodeproj` cannot
work; write `cd Kiteloop && …`, or the sturdier `cd "$(git rev-parse
--show-toplevel)/Kiteloop" && …`.

The grounding check (`Services/GroundingCheck.swift`) refuses that at pickup
rather than letting it reach a merge gate, naming the path, the directory the
command runs in, and the `cd` that fixes it:

```
Skipped: <id> — not grounded: verify command names `Kiteloop.xcodeproj`, which
does not exist from the project root — the repo has it at
`Kiteloop/Kiteloop.xcodeproj`; did you mean `cd Kiteloop && …`?
```

It only refuses a path the repo holds under a directory the command never
entered — a missing `cd`, which names its own fix. A path the repo does not have
at all is left alone: static text can't tell a file the command *writes*
(`tee results/out.json`) from one the run is about to create. Nothing here asks
whether the command can *pass* — that is not decidable from its text.

**A pipe must be written without spaces around it.** A backlog line's fields are
split on `" | "`, so a spaced pipe *is* the field separator:

| written on the item line | what the item actually runs |
|---|---|
| `verify: a --json \| python3 -c '…'` | `a --json` |
| `verify: a --json\|python3 -c '…'` | `a --json\|python3 -c '…'` |

The truncation is silent — no error, no warning. A `verify:` in the detail file's
frontmatter is a YAML value rather than a line field, so it is not affected.

### Tools the app must reach

Kiteloop is a GUI app, so it launches with a thin `PATH` — none of the login
shell's additions reach it. Every place the app asks "can this project run
tool X" — the grounding check at pickup, the verify shell at the merge gate and
the salvage re-check, the agents' own `claude` processes, the credential checks
— reads **one** search path (`Services/ExecutableSearchPath.swift`), composed
in this order and deduplicated:

1. the login shell's `PATH` — `/bin/zsh -lc 'printf %s "$PATH"'`, captured
   once per app launch with a 5 s deadline; the app's own `PATH` if the shell
   fails or hangs;
2. the fixed toolchain homes: `/opt/homebrew/bin`, `/opt/homebrew/sbin`,
   `/usr/local/bin`, `/opt/local/bin`, `~/.local/bin`, `~/.npm/bin`,
   `~/.cargo/bin`;
3. `extraExecutablePaths` in `~/.kiteloop/global-config.json` — a list of
   directories, `~` allowed, for every project;
4. `extraExecutablePaths` in the project's `.kiteloop/config.json` — the same
   shape, appended last, for this project alone.

```json
{ "extraExecutablePaths": ["~/.pyenv/shims", "/srv/tools/bin"] }
```

The verify shell is still `/bin/zsh -lc`, but its `PATH` is exported from this
list rather than left to what `~/.zprofile` happens to set — a login shell
reads `~/.zprofile` and not `~/.zshrc`, which is how a pip-installed `lizard`
was invisible at the merge verify while the same `cargo` was being refused at
grooming, both installed, on 2026-09-03.

What resolved, and what did not, is visible before a run is refused for it:
`GET /health` carries `tools` — per open project, one row per executable
the verify commands run, with the path it resolved to or `null` and the
directories searched — and the Diagnostics window's Health tab shows the same
rows. A grounding refusal for an executable names the directories it searched.

One trap: `brew install lizard` installs a compression library, not the
complexity analyser. The `lizard` a `verify:` wants is `pip install lizard`
(or `pipx install lizard`), which lands in `~/.local/bin` — on the list above.

To make an item runnable, groom it and flip its status to `ready` in the backlog
file — the app live-reloads it into the queue. A refused item logs
`Skipped: <id> — not ready: <reasons>` in the Autopilot tab's log, and a refused
`POST /v1/runs` returns 422 with the same reasons. See `CLAUDE.md` → Autonomy.

Either refusal — the grounding check above, or Definition-of-Ready for how the
item is written — also sends the item back to `draft`, with the refusal itself
written to its `## Notes` as `sent back to draft: <reasons>`. No run started,
so this costs nothing against the retry ceiling (`CLAUDE.md` → Autonomy): a
pickup refusal is a citation to fix, not an attempt that failed. An item held
back solely by an unmet `needs:` is left alone in `ready` — it is waiting its
turn, not mis-groomed.

## D. Recovery & safety

| Situation | What to do | Notes |
|---|---|---|
| A run hangs on `node=worker` with no progress | Wait out the stall timeout, or pause/stop autopilot in the app | The watchdog ends the item (→ `blocked`) after the stall timeout — not a setting: it is derived from the project's own worker phases (p95 × 1.5, floored at 15 min, capped at 60) and stays at 20 minutes until five runs carry a worker phase. `GET /v1/autopilot` reports it as `stallTimeoutMinutes`, with `runTimeoutSource` saying whether it is measured yet. |
| Item ends `blocked` | Read the reason (status/result), fix, re-`ready` it | A run cut short (session cost cap, stall, retry ceiling) is first re-checked against the item's `verify:` — if that passes, the branch is committed and the item lands in `awaiting-approval` instead. |
| Item stuck in `awaiting-approval` | Approve/reject (app or `/approve`) | In a long unattended run, the "human touch" is clearing this queue. |
| Item ends `blocked` with "diff touches … but verify never runs …" | Widen the item's `verify:` (or fix the glob), re-`ready` it | The verify-coverage gate (§F): the run changed files the item's command doesn't exercise. The work is committed on its branch — nothing is lost. |
| `POST /v1/runs` answers 202 with `status: "starting"` and no `runId` | Read `run.runId` from `GET /v1/autopilot?project=<p>`, or post the item again | Nothing refused the run — it was accepted and is still spinning up, so **do not** drop the item. Posting it again while it is in flight answers 409 naming the run; it does not start it twice. |
| `POST /v1/runs` answers 409 "still busy" | Read the run it names: `GET /v1/runs/<id>/result` | Only a run in flight refuses another, and the refusal names it. A queue **paused** by the budget does not refuse a run — but the next run inherits the spent session and pauses again, so clear it first: `POST /v1/autopilot/resume` opens a fresh session budget and picks the held queue back up, or raise `budgetUSD` with `PUT /v1/autopilot`. |
| Cost climbing | Set the project's **budget** in Project Settings → Autopilot (or `budgetUSD` over `PUT /v1/autopilot`) | The one budget **pauses** autopilot, leaving the rest of the queue for you to resume — it is the ceiling that actually bounds the spend, and it counts every run of the sitting, not one item (resuming past it is what starts the next session). The per-item ceiling is derived from the ledger (the size band's p90, else the budget's share of the prediction) and is **advisory**: it records the overrun and the run continues, so use it to see which items outgrow their estimate. The budget is empty (uncapped) by default; a `PUT` naming the old `sessionCostCapUSD`, `perItemCostCapUSD` or `costCapMargin` is tolerated and ignored. |
| Bad changes | Review the diff before approving; changes are **not** committed by approving | In a project that is not a git repository the worker edits the live tree — review carefully. In a git repository the work always stays on `kiteloop/<item-id>` (ADR-0001). |

### Stopping the whole fleet — pause and resume

Pausing each project is not enough to stop the fleet: `POST /v1/runs` never
consults an autopilot's status and starts anyway. The fleet-wide hold — **"Pause
fleet"** in the sidebar, `POST /v1/fleet/quiesce` over the API — holds every
advancing queue **and** puts a gate in front of that start, so it is the one call
to make before quitting the app, rebooting, or walking away mid-night:

```bash
curl -s -H "$H" -d '{"waitSeconds":600}' $B/fleet/quiesce   # hold, wait up to 10m to drain
curl -s -H "$H" $B/fleet/quiesce | jq '{quiesced, drained, running}'   # read-only: where is it?
curl -s -X POST -H "$H" $B/fleet/resume
```

**Nothing is stranded exactly when `quiesced` and `drained` are both `true`.**
Runs already in flight are left to finish at their own gate rather than
interrupted, which is what makes the restart cost nothing — so a wait that runs
out is still a 200 carrying `drained: false` and a count of what is left. Wait
again, or `POST /v1/runs/{runId}/cancel` the run holding it up; never read a
timeout as drained.

The hold lives in memory. After the restart it was taken for, every autopilot
comes back idle and `resume` reports an empty `resumed` — that is the success, not
an error. It picks up exactly the queues the hold took, never one that was
already paused when it arrived.

**The endpoint keeps the `quiesce` spelling; the app says "Pause fleet".** The path,
the `quiesced`/`drained` fields and their values are what scripts read and are not
changing — only the sidebar control, its state line ("pausing — N run(s) finishing",
then "paused — all quiet") and the quit dialog were renamed. In the app the same hold
is reached from the sidebar's Pause · Fleet control, or by quitting with runs in
flight and choosing to pause first.

[`POST /v1/fleet/quiesce`](control-api.md#post-v1fleetquiesce) ·
[`GET`](control-api.md#get-v1fleetquiesce) ·
[`POST /v1/fleet/resume`](control-api.md#post-v1fleetresume).

## E. Measuring a marathon

A *marathon* is a long unattended run — eight hours or more — that
`scripts/kiteloop-verify.py --marathon` drives against the control API. Run the
harness (it drives §B in a loop as the queue drains) and read:
- `events.jsonl` — workflow transitions, durations, rescues.
- `task-metrics.jsonl` — per-item duration/cost/errors (feeds metric #4).
- control-API run log — outcomes per run.
- the unified log — one structured line per run phase, and the only record that
  survives an app restart (the in-app log keeps just the last 50 lines):

```bash
log stream --predicate 'subsystem == "ai.kasatkin.kiteloop" AND category == "backlog-autopilot"'
log show --last 6h --predicate 'category == "backlog-autopilot"' --info   # after the fact
```

Each line is `phase=<name> key=value …`: `run.start`, `item.start`,
`worker.start`/`reviewer.start` (with `attempt`), `item.abort` (the item was
ended in flight — session cost cap, stall, or nothing to review),
`item.over-budget` (the item crossed its own — advisory — cost cap and the run
carried on, so it is an overrun and not an ending), `item.end` (outcome,
duration, cost, branch, quality), `merge`, `run.pause` (with `resumeAt`),
`run.end`. Phases that ended something badly log at error level, so
`--predicate 'messageType == "Error"'` alone lists the failures.

Emit the [scorecard](success-metrics.md): duration, items done, rescues, stalls,
first-pass rate.

### The night in two calls

Those files are the raw record; two endpoints answer the questions off them
without re-deriving anything. `GET /v1/report` is what a window of unattended work
*produced* — merged ÷ filed per project, why the rejections were rejected, the
spend and the idle time. `GET /v1/metrics` is the per-run measurement underneath,
and carries the first-pass rate rolled up over the whole recorded history rather
than the page it returns:

```bash
curl -s -H "$H" "$B/report?hours=24" | jq -r '.summary, (.rows[] | .text)'
curl -s -H "$H" "$B/metrics?project=<name>&limit=5" |
  jq -r '"first-pass \(.firstPassRate.firstPass)/\(.firstPassRate.judged) = \(.firstPassRate.rate)"'
```

Read `mergeRate.basis` before believing the rate: `filed` is the headline (was
the grooming any good), and it falls back to `run` in a window where nothing was
filed rather than reporting a good night as `0/0`. A `fraction` of `null` is *not
measured*, not 0%.

A merge nobody has decided counts as **not merged** — unknown never rounds in the
flattering direction — so a rate that looks bad in the morning is often a queue
still sitting at the item gate. Check `awaitingApproval` in
[`GET /v1/projects`](#what-every-project-is-doing) before drawing a conclusion
from it.

[`GET /v1/report`](control-api.md#get-v1report) ·
[`GET /v1/metrics`](control-api.md#get-v1metrics).

## F. Verify coverage: does the `verify:` cover the diff?

An item's `verify:` is trusted to exercise whatever the run changed, and until a
map exists nothing checks that it does. A run whose diff reaches past its command
merges having verified only the half the command happens to build — a web-only
`npm test` over a diff that also carried Rust ships the backend unchecked.

Configure the check per repo in **`kiteloop-verify.json`** at the repository
root — path glob → the command that covers those files — and commit it, so a
rule is reviewed like any other file. It is repo-level on purpose: which command
covers `apps/api/**` is not the item author's call.

```json
{
  "rules": [
    { "glob": "apps/web/**", "command": "npm --prefix apps/web test" },
    { "glob": "apps/api/**", "command": "cargo check --workspace" },
    { "glob": "**/*.sql",    "command": "cargo sqlx prepare --check" }
  ]
}
```

After a run produces its diff, autopilot lists the changed files and, for each
rule whose glob any of them match, checks that the rule's command is part of what
the item declared as its `verify:`. A rule that isn't → the item is **blocked**
with the paths, the glob and the missing command named:

```
Blocked: … — diff touches apps/api/** (3 files: apps/api/src/routes/expert.rs,
apps/api/.sqlx/query-cache.json, apps/api/query-ratchet.toml) but verify never
runs `cargo check --workspace`
```

The work is committed on `kiteloop/<item-id>` and nothing is lost: widen the
item's `verify:` (or the map, if the glob is wrong) and re-`ready` it.

Blocked triage does that widening itself. A run record whose reason carries
`verify never runs` is classified `verifyUncovered` (`BlockedTriage.Failure`) —
the verify was never *asked*, which is not the verify failing — and the regroom
that sends the item back appends each missing command to the item's `verify:`
line **and** to the detail file's frontmatter `verify:` list when it has one
(the list is what a run executes; the line is read only when the list is
empty). Each command is re-rooted first — `&& cd "$(git rev-parse
--show-toplevel)" && …` — so a line that ended inside a subdirectory does not
run it from there. The item's Notes say what was added. Before this, triage
returned the item unchanged with a note, the same gate refused the same diff,
and the second identical refusal escalated it: two runs spent per item, and
twelve items went that way on 2026-08-24.

A rule may carry a `run` beside its `command`: the runnable spelling, for a
`command` that is only the prefix a match needs. `xcodebuild -project
Kiteloop.xcodeproj -scheme Kiteloop` matches every build of that scheme but
runs nothing as written; its `run` is the full `cd Kiteloop && xcodebuild …
build-for-testing`. Absent, `command` is added as written, from the root.

```json
{ "glob": "Kiteloop/Kiteloop/**/*.swift",
  "command": "xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop",
  "run": "cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination \"platform=macOS\" build-for-testing" }
```

What it deliberately does **not** do:

| | |
|---|---|
| No map configured | Nothing is checked — the default for every project, and this must stay a mechanism a repo opts into. A malformed map file is logged and treated as absent. |
| A changed file matching no glob | Not a gap. An unmapped path is an unmade statement, not a claim that nothing covers it. |
| A gap found | **Fails the run**, never runs the missing command itself. Widening what a run executes is its own surprise, and an expensive one. Blocked triage widens the item's `verify:` afterwards, so the *next* run executes it — declared on the item, not sprung on the run. |
| A live-tree run (worktree isolation off) | Not checked — there is no branch to diff. |

Glob syntax: `*` matches within one path segment, `?` one character, `**` any
number of segments (a trailing `/**` also names the directory's own files).
Patterns are repo-relative and anchored at both ends. A rule counts as run when
its command appears anywhere in a declared verify command, so `cd repo && cargo
check --workspace && npm test` satisfies a rule for `cargo check --workspace`.

Rules live in `Services/VerifyCoverage.swift`.

### Prove a map before trusting it

A map that matches nothing is indistinguishable from no map: both let every run
through, and both read as coverage afterwards. So make each rule fail on purpose
before trusting it, and check it stays quiet on the diffs that really are
covered. `scripts/verify-map-replay.sh` answers both in a second — it compiles
the shipped rules and runs them against a diff you name:

```bash
./scripts/verify-map-replay.sh ~/code/api/kiteloop-verify.json \
    @da045ae0 './scripts/ci-local.sh'          # the files that commit touched
printf 'src/lib.rs\n' | ./scripts/verify-map-replay.sh <map> - 'npm test'
```

Replaying a repo's already **merged** items is the part worth the effort: each of
those was verified to somebody's satisfaction, so a rule that blocks one is
claiming coverage the repo itself does not agree with. Both maps written on
2026-08-09 lost a rule to that replay, and each loss is a kind to expect:

* **A command that never reads the file.** `Kiteloop/project.yml` →
  `xcodebuild … build` looks obvious and is false: `xcodebuild` reads the
  `.xcodeproj`, never the XcodeGen spec it was generated from, so no build can
  fail on a drifted `project.yml`. The replay surfaced the merged item that
  fixed exactly that drift with a `grep`, and would have been blocked by a rule
  demanding a build that proved nothing.
* **A tree with no canonical command.** The repo whose escape motivated this
  gate verifies its web tree two ways — `npm --prefix apps/web test` (vitest
  alone) in twenty items, and `./scripts/ci-local.sh` (which runs that suite
  *plus* `tsc -b` and the bundle) in thirty-three. A rule naming either one
  blocks the items using the other, including three already merged and one of
  the two currently ready — runs that did more checking, not less. One command
  per glob is the mechanism's whole design, so a tree with two has no claim to
  make yet, and stays unmapped until the repo settles on one.

Both are the same mistake in the end: a glob is a claim about what exercises
what, and a claim that misfires is worse than a missing one, because after the
fact it reads as coverage.

### The maps as they stand

This repository's map is `kiteloop-verify.json` at its root, tracked like any
other file: a fresh checkout and the worktree a run executes in both carry it,
and a change to a rule goes through review. It is not reprinted here, so this
file cannot drift from it — read it there, and prove it with
`scripts/verify-map-replay.sh` as in the walkthrough above; it compiles the
shipped rules against the map you name.

## Remote access

The control server binds `127.0.0.1` and only `127.0.0.1` — the listener sets
`requiredLocalEndpoint`, so it is not reachable off-device and no setting widens
that. Driving a dedicated Mac from a laptop or a phone is still a normal thing to
want, and the answer is a **tunnel**: the server keeps its loopback posture, and
your client gets a local `127.0.0.1:4517` that comes out on the Mac. Every recipe
in §B then works verbatim, token and all.

### 1. SSH local forwarding

On the Mac, turn on **System Settings → General → Sharing → Remote Login** once.
Then, from the client:

```bash
ssh -N -L 4517:127.0.0.1:4517 <user>@<mac>
```

Write the forward target as `127.0.0.1`, not `localhost`: the listener is bound to
the IPv4 loopback address, and a `localhost` that resolves to `::1` first gets the
forward refused. Leave that command running (`-N` = no remote shell) and use a
second shell on the client:

```bash
curl -s http://127.0.0.1:4517/health      # {"status":"ok","version":…} → the tunnel is up
```

That one line is the whole verification — `/health` is the unauthenticated probe,
so it answers before you have sorted out the token.

### 2. The token

The bearer token lives on the **Mac**, at `~/.kiteloop/control-token` (mode
`0600`, minted on first use). Your client needs a copy; the tidiest way to get one
is over the same SSH connection you just proved works:

```bash
TOKEN=$(ssh <user>@<mac> cat '~/.kiteloop/control-token'); H="Authorization: Bearer $TOKEN"
B="http://127.0.0.1:4517/v1"

curl -s -H "$H" "$B/backlog?project=<name>"
```

From here §B is unchanged, including the SSE stream:

```bash
curl -N -H "$H" $B/runs/$RUN/events
```

Both the token fetch and every subsequent request ride inside the SSH connection,
so the token is encrypted in transit and never crosses your LAN in the clear. If
the tunnel drops mid-run, the run keeps going — it is driven by the app, not by
your client. Reconnect and `GET /v1/runs/<id>/result`, or re-open `/events`, which
replays this run's history before going live again.

**Settings → Local Control API → Bearer token → Regenerate…** invalidates every
copy immediately, including the one on your phone — re-fetch it after rotating.

### 3. Tailscale, to make the Mac reachable at all

SSH only helps once you can route to the Mac. Tailscale puts both devices on one
private network with no port forwarding and no public exposure:

1. Install Tailscale on the Mac and on the client, and `tailscale up` on both.
   (If `tailscale` isn't on the Mac's `PATH`, the CLI ships inside the app bundle
   at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.)
2. `tailscale status` — note the Mac's machine name or `100.x.y.z` address.
3. Run exactly the same command as above, against that name:

```bash
ssh -N -L 4517:127.0.0.1:4517 <user>@<mac-machine-name>
```

Turning on **Tailscale SSH** (`tailscale up --ssh` on the Mac, plus an ACL rule
that permits it) means that command needs no SSH keys at all — the tailnet
identity is the credential. Either way it is still an SSH tunnel, so everything in
§1 and §2 applies unchanged.

On a phone, an SSH client that supports local port forwarding (Blink, Termius,
and similar) sets up the same `4517 → 127.0.0.1:4517` forward; point curl, or any
HTTP client on the device, at `http://127.0.0.1:4517`.

### 4. The pairing forwarder: what the QR sheet actually uses

§1–§3 are a tunnel *you* set up. The app's own pairing sheet (Settings →
General → Local Control API → "Pair a phone") does something else: it shows a
QR code for `scripts/control-forwarder.py`, a small process that binds the
Mac's **tailnet address** (100.x.y.z, WireGuard-encrypted by Tailscale) and its
**LAN address** (the same Wi-Fi network, plain TCP) and forwards each
connection to the loopback-only control server. Scanning the code hands the
iOS companion a URL and a bearer token of its own in one step — each pairing
mints a token for that phone, listed under **Settings → Control API → Paired
phones**, where **Revoke** stops that phone alone — no SSH tunnel, no typed
address — as long as the forwarder is actually running on the Mac.

That is the same trade [What not to do](#what-not-to-do) below warns about for
`tailscale serve`, made deliberately and on two networks at once: anyone who
can reach either address can send it a request, and the bearer token is the
only thing that stops them — on the LAN address, unencrypted on the wire too.
Treat it the way you would treat `tailscale serve`: fine on a private tailnet
and a trusted home or office Wi-Fi, worth reconsidering on a network you do not
control.

Install it once, on the Mac:

```bash
./scripts/install-control-forwarder.sh              # copies the script to
                                                      # ~/.kiteloop/bin, writes
                                                      # and loads the LaunchAgent
./scripts/install-control-forwarder.sh --dry-run     # see the plan first, touches nothing
./scripts/install-control-forwarder.sh --uninstall   # tear it down
./scripts/install-control-forwarder.sh --tailnet-only # never the LAN address
```

On a work laptop, or any Mac on Wi-Fi you do not control, install with
`--tailnet-only`: the forwarder then binds only the tailnet address, so the
plain-TCP LAN side never exists, and a LAN lease coming or going is no reason
to rebind. Installing again without the flag goes back to both addresses.

It runs as `ai.kasatkin.kiteloop-forwarder`, kept alive by launchd
(`RunAtLoad`/`KeepAlive`) across reboots and across the DHCP lease changes that
would otherwise take the LAN address out from under it — the forwarder
re-checks its addresses every 30s and exits on purpose, either when a bound
address disappears or when one it did not bind appears (the ordinary case at
login, when Wi-Fi is up before `tailscaled` finishes), so launchd restarts it
against whatever address is current. Logs land under `~/.kiteloop/logs/`.
Reinstalling after a change to `control-forwarder.py` is the same command: it
leaves one copy and one loaded job, not a second of either.

### 5. From a phone: the sequence

§1–§3 get you a tunnel and a token. This is what to do through it — see what is
happening, then either ship the work or stop the fleet. It is one screen of
typing, and none of it needs the app in front of you.

```bash
curl -s http://127.0.0.1:4517/health                    # tunnel up? (no auth)
TOKEN=$(ssh <user>@<mac> cat '~/.kiteloop/control-token')
H="Authorization: Bearer $TOKEN"; B="http://127.0.0.1:4517/v1"

# 1. what is happening, everywhere
curl -s -H "$H" $B/projects |
  jq -r '.projects[] | "\(.name)\t\(.run.state)\trunnable \(.queue.runnable)/\(.queue.ready)\tgate \(.queue.awaitingApproval)"'

# 2. what is parked at a gate in one project
curl -s -H "$H" "$B/backlog?project=<name>" |
  jq -r '.items[] | select(.status == "awaiting-approval") | .id'

# 3a. ship it — merges the branch and marks the item done
curl -s -H "$H" -d '{"project":"<name>","item":"<item-id>","approve":true}' $B/backlog/approve

# 3b. or send it back, with the reason the next run will read
curl -s -H "$H" -d '{"project":"<name>","item":"<item-id>","approve":false,"reason":"<why>"}' $B/backlog/approve

# 3c. or stop taking new work until you are back at the machine
curl -s -H "$H" -d '{"waitSeconds":600}' $B/fleet/quiesce
```

Step 3a is the one to have muscle memory for — the item gate, not the run gate:
from a phone you have an item id, and the `runId`s of an app that restarted
overnight answer 409 ([Landing the work](#landing-the-work--the-item-gate)).

Give it time. Approving runs a real merge and a real verify on the Mac, so the
request can sit for minutes and a **409** is a failed merge or a red verify, not a
transport problem — read `reason` and `verifyOutput` in the reply rather than
retrying blind. If the tunnel drops meanwhile the work carries on regardless: it
is driven by the app, not by your client.

### What not to do

`tailscale serve --bg 4517` and `tailscale funnel` will proxy the port directly —
TLS-terminated at the Tailscale daemon, so the token is still encrypted in
transit — but they change the security model rather than tunnel around it:

| | |
|---|---|
| `tailscale serve` | Publishes the API to your **whole tailnet**, including shared-in devices. The bearer token becomes the only thing between any of them and `POST /v1/runs`. |
| `tailscale funnel` | Publishes it to the **public internet**. The control API has no rate limiting and no lockout, so a token in a plaintext file is the entire defence. |

Anything holding that token can start runs, spend money against your caps and
edit your working tree. The SSH tunnel is the better trade for the same result: it
requires an account on the Mac *in addition to* the token. If you do reach for
`serve` anyway, scope it with tailnet ACLs and rotate the token when you are done.
