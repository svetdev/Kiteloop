# Autonomy: What Makes a Run Trustworthy

Kiteloop's goal is unattended backlog execution *with quality control*. The
interesting question is not whether an agent can write code — it is what stops a
bad run from reaching `main`, and what stops a run from reporting success it did
not earn.

`CLAUDE.md` is the operative copy the worker and reviewer read; this page
explains it. Bringing Kiteloop to your own repository? Start with
[Adopting this in your own project](#adopting-this-in-your-own-project).

This is the answer, in four parts:

- [The run model](#the-run-model) — where the work happens and what gates it.
- [The ODD](#the-odd-autonomy-inside-a-boundary) — the boundary autonomy is
  scoped to.
- [Definition-of-Ready](#definition-of-ready) — what an item must carry before a
  run may be spent on it, and which clauses a machine checks.
- [Definition-of-Done](#definition-of-done) and the
  [reviewer rubric](#the-reviewer-rubric) — what the worker must satisfy, and
  what the reviewer blocks on.

Most of the specific rules below exist because a run went wrong in exactly that
way. Those stories are kept: a rule with a date attached is one you can judge,
and one you can decide you don't need.

## The run model

Decided in [ADR-0001](adr/0001-autonomous-run-model.md): **isolation → branch →
human gate**. It is branch protection, required status checks and review — the
ordinary CI/CD shape — applied to an AI author.

1. **Isolation.** The run happens in a dedicated git worktree on a branch
   `kiteloop/<item-id>`. The worker never edits the project tree directly. This
   is not a setting: it holds **whenever the project root is a git
   repository** — a plain directory has no worktrees to run in, so there the
   run uses the live tree and says why. Full
   model: [worktree-isolation.md](worktree-isolation.md).
2. **The deliverable is a branch.** Opening a pull request from it is an opt-in
   (`openPullRequest`, off by default).
3. **Three gates to `done`**, in order: the item's **`verify:`** command, the
   **reviewer agent** against the rubric below, and **human approval**
   (`awaiting-approval` → `done`).
4. **No auto-merge by default.** The autonomy dial's `land` rung exists for
   deliberately unattended queues; the dial starts at `off`, and on `land` the
   merge is gated on a clean
   `--no-ff` merge *plus* a green verify of the merged tree, with a rollback on
   failure — never on the reviewer's opinion alone.

Who is allowed to move an item between statuses, and who is not, is
[how-work-flows.md](how-work-flows.md). Two rules from there are load-bearing
here: the Planner fills the queue but cannot start runs, and no agent moves an
item into `done` or `draft` on its own — `done` is reached by a person's
approval or by the `land` rung approving a review-passed run, and `draft` is
where a pickup gate sends an ungroomed item back.

## The ODD: autonomy inside a boundary

Borrowed from self-driving (SAE J3016's **Operational Design Domain**): Kiteloop
targets high autonomy *inside a bounded domain* rather than general autonomy. An
agent runs unattended only on items that qualify — groomed, sized ≤ M, carrying a
`verify:` check. Outside that domain there is no claim.

### Boundaries

What bounds an unattended run, in one place. Not a permission prompt: a run's
worker and reviewer are spawned in Claude Code's auto mode with prompts off,
because a prompt nobody is watching protects nothing. The boundaries that hold:

- **The worktree.** Every run builds in its own checkout under
  `.kiteloop/worktrees/<item-id>`, pinned as the agents' working directory
  ([worktree-isolation.md](worktree-isolation.md)).
- **Stray work is refused.** A diff that reaches outside the item is refused at
  the gate (`RunWorkEvidence`), whatever wrote it.
- **The verify gate**, then **review** against the rubric below, then **a
  person** at the approval gate.
- **Claude Code's auto-mode classifier**, which decides each tool call; with
  `--permission-prompts none`, anything it would have asked about is refused.
  Kiteloop keeps no deny list of its own — only an agent's own `denied` tools
  are added, and the classifier is not infallible (see
  [DECISIONS.md](../DECISIONS.md)).
- **Next:** a sandbox-exec profile around the spawned process, the kernel
  boundary [ADR-0003](adr/0003-run-sandboxing.md) queued.

The autonomy ladder states this on the rung that starts unattended runs, and
`GET /v1/projects` reports it per project as `unattendedPermissions`.

The boundary moves on evidence. [success-metrics.md](success-metrics.md) defines
four SLIs with SLOs and an error budget: inside budget, the ODD widens (bigger
items, more parallelism, longer unattended windows); budget burned, expansion
freezes until the failure mode is fixed. The rescue budget for a promotion is
zero — an eight-hour run that needed unsticking does not pass, it names the next
reliability bug.

## Definition-of-Ready

An item is autopilot-runnable only if all of these hold:

- A groomed detail file with **What / How / Validation** (`backlog/<id>.md`).
- A **`verify:`** command — the objective check the work has to pass.
- **Size ≤ M.** L and XL must be broken down; unsized counts as unready.
- An explicit **out-of-scope** list.
- Every item it must **wait for is `done`**, written as `needs:<id>` on the
  backlog line.

**Most of this is enforced at pickup**, not trusted. `DefinitionOfReady.evaluate`
(`Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/DefinitionOfReady.swift`) is a pure function of the
item, its detail file and the backlog around it, so the queue filter, the panel
and the control API all reach the same verdict. An item that fails is **skipped
with the failing clause named**, rather than spending a full worker/reviewer
cycle discovering it had nothing to build against — which is what used to happen.

| Clause | Unmet when |
|---|---|
| `detail` / `what` / `how` / `validation` | No groomed detail file, or it is missing a required section |
| `verify` | Neither the detail file nor the line declares a command |
| `verifySeparator` / `titleSeparator` | The `verify:` or the title contains the line's field separator `" \| "` |
| `size` / `sizeTooLarge` | No size set, or sized L/XL |
| `dependency` | A `needs:` id is not `done` — including one naming nothing, and a cycle |

Three things about that gate are easy to get wrong, and each is a deliberate
decision rather than an omission:

- **Out-of-scope is not machine-checked.** An empty out-of-scope list is a
  legitimate statement — "nothing is off limits" — and reads identically to an
  unwritten one, so blocking on it would refuse items that are genuinely ready.
  It stays a grooming rule. A missing What, `verify:` or size cannot be read that
  way: each is unambiguously ungroomed.
- **Inline grooming counts.** A line whose title carries `WHAT: … HOW: …
  VALIDATE: …` is groomed, with no detail file. Some projects work that way, and
  the gate must not refuse them for putting the same content in a different
  place.
- **The gate withholds; it never reorders.** An item whose turn has not come is
  skipped with the dependency named, and the queue moves on.

### Writing a `verify:`

Two rules, both of which have cost real runs. The mechanics live in
[backlog-format.md](backlog-format.md#writing-a-verify); the reason they are here
is that both are trust properties, not formatting preferences.

- **It runs from the project root.** For this repository the Xcode project is at
  `Kiteloop/Kiteloop.xcodeproj`, so a command naming `Kiteloop.xcodeproj` at top
  level is wrong however plausible it reads. Twelve open items got this wrong on
  2026-08-10, and each was destined to be built against for a whole run and then
  fail its own merge gate in front of a person.
- **A shell pipe must be written unspaced** — `a --json|python3 -c '…'`. A spaced
  pipe *is* the backlog line's field separator, so the command is truncated
  there with no error and no warning, and the item runs something shorter than
  what was written — while the shortened half still passes and the merge gate
  still opens.

### The second gate: grounding

`DefinitionOfReady` checks that an item is *shaped* right. `GroundingCheck` asks
whether it is **true** about the repository it will be built in: it pulls the
concrete claims a draft makes — backticked paths and symbols, plus the `verify:`
command's executable and the paths handed to it — and asks the filesystem whether
each one exists.

This is a smoke test against invention, not a compiler. A detail file here once
told a worker to copy a symbol that is in no file in this repo, and the run was
spent hunting for something that was never there. It is conservative in both
directions on purpose: only backticked, code-shaped tokens count as claims, and a
reference the draft proposes to *create* is exempt. A missed invention costs one
run; a wrongly refused item strands real work and nobody finds out why.

## Definition-of-Done

What the worker must satisfy before handing off:

- **The `verify:` command passes.**
- **Only files the item implies are changed** — no unrelated edits, no scope
  creep.
- **Tests added or updated for any change in behaviour.** A change that alters no
  behaviour — documentation, comments, an ADR — has nothing to assert and must
  not invent a test to satisfy this line.
- **For a documentation item:** accurate against the code as it exists today,
  covering what the item asked for, with every command and path it cites real.
- **Nothing left half-done** — no TODOs standing in for acceptance criteria.
- **A change in behaviour is described in `CHANGELOG.md`**, as one line under the
  current unreleased heading, saying what changed *for someone using the app* —
  not the item id, not the files touched. A reader scanning a release wants a
  list, and 58 entries of a paragraph each is not a list.

Two of these carry war stories, and both describe the same failure: **reporting
work that did not happen.**

### A passing `verify:` on an unchanged tree is not done

The `verify:` command passes on a clean checkout — that is what it does. So a
green run proves nothing about whether the item was built.

On 2026-08-09 a run ended `produced no work — no branch` with the closing message
*"Done. ./scripts/ci-local.sh is green"*. The worker had run the item's verify
against an unchanged tree, watched it pass, and reported success. There was no
branch, no diff, and nothing delivered. `settings-checked-queries` was run that
way **five times**; `small-routes`, four.

Three things now stand between that and a green-looking queue:

1. **The worker is told, while it can still act.** Git is asked one turn before
   the hand-off to the reviewer, and a clean worktree with no commit is said out
   loud to the worker (`EmptyDiffHandoff`). It then either makes the change, or
   states that it believes the item is already implemented — which is the outcome
   nobody could see before, and which rides out of the run as its closing
   message. Told **once**, not in a loop: a worker that has answered has
   answered.
2. **The reviewer is instructed to fail an empty diff outright.** In the shipped
   reviewer prompt: *an empty diff is not evidence for any of the criteria, so
   "passed" is the one verdict it can never earn, however green the verify
   commands are on an unchanged tree.*
3. **A circuit breaker.** A streak of items producing no work pauses the run and
   says why, rather than chewing through the backlog restarting agents.

Only "the worktree is clean and the branch carries no commit" triggers any of
this. *Nobody could tell* is a different fact from *there is nothing there* —
telling a worker it changed nothing on the strength of an unreadable git is how a
run that did real work gets an accusing turn it has to argue with.

### Never write the suite record by hand

`docs/suite-status.md` holds one row per unit-suite run. A row is a
**measurement**, so writing one by hand is fabricating one. That happened on
2026-08-11: rows were typed into the file from an unrelated item, and the tooling
duly reported 3,077 passing tests that nobody had run.

Only `scripts/run-unit-suite.sh` may append a row. Each row now names the
`.xcresult` bundle xcodebuild opened — timestamped by xcodebuild and present on
disk only because a build ran — so a typed row names a bundle that
`find ~/Library/Developer/Xcode/DerivedData -name '<the cell>'` cannot find. A
row is checkable rather than trusted.

The generalisation is the rule worth carrying: **reporting a measurement you did
not take is the same failure as reporting success over an empty diff.**

## The reviewer rubric

The reviewer judges the diff, clause by clause, and blocks on any that is unmet:

1. **`verify:` passes.**
2. **Scope respected** — the diff matches the item's What/How. Three failures
   here are blocking rather than advisory, and all three have shipped past a
   reviewer at least once:
   - the item **explicitly said not to** do something and the diff does it
     anyway. An item's prohibitions are binding, and "it's a small improvement"
     does not override them;
   - the diff **widens a default** the item did not ask to widen — granting a
     capability to shared templates, presets or default lists;
   - the diff **touches the suite record** while the item is not about that
     recording mechanism.
3. **Every acceptance criterion in the item's Validation is actually met by the
   diff.** An unimplemented criterion is a rejection even when everything present
   is well built — checked off one by one against the code, not against the run's
   summary of itself.
4. **Tests present and meaningful, for a change in behaviour.** Judge the diff
   you were given, not the diff you expected: if it changes no behaviour, this
   criterion does not apply, and a test invented to satisfy a checklist is itself
   a defect.
5. **For a documentation-only diff**, clause 5 replaces clause 4: is it accurate
   against the current code, does it cover what the item asked for, and is every
   command, path and symbol it cites real? Verified by checking the code, not by
   reasoning about what the docs ought to say.
6. **Matches surrounding conventions** — code or prose.
7. **If unmet → reject with a specific reason.** The item returns to `ready` with
   that feedback attached to the next run. Marginal work is not approved. "No
   tests" is only a specific reason when behaviour changed.

### How a verdict is written

The reviewer answers with a JSON object — a verdict, a reason, and optionally a
list of findings, each carrying a severity:

```json
{"passed": false, "reason": "AC 3 is unimplemented",
 "findings": [{"severity": "blocking", "text": "AC 3 is unimplemented", "file": "Services/Foo.swift"},
              {"severity": "advisory", "text": "`n` reads oddly next to the names around it"}]}
```

**Why severities exist.** `passed` alone makes every observation blocking by
construction: a reviewer that notices a misnamed variable while approving good
work can either reject the whole run over it or say nothing, and it says nothing.
Either way the observation dies with the run — rejection feedback is the only
channel a review has, and an approval has no channel at all.

- **`blocking`** — any of 1–6 is unmet. One blocking finding rejects the run, and
  the findings become the next worker pass's feedback.
- **`advisory`** — worth saying, not worth rejecting for. These are written to the
  item's `## Notes` when the review passes, so raising one no longer costs a run.

This changes what a reviewer can *say*, not what blocks. A blocking finding is
not softened to advisory to let work through, and a nit is not raised to blocking
to make a point.

The parsing (`ReviewFindings`) is deliberately lenient in one direction only,
because a verdict that cannot be read costs a whole run:

- Findings are optional; a bare `{"passed": true}` routes exactly as it always
  did.
- A findings list that is not readable is treated as absent — malformed structure
  never invents a verdict.
- **A severity nobody recognises reads as `advisory`, never `blocking`.** Guessing
  "blocking" from an unknown word would reject work over a typo.
- Findings can only ever **downgrade** an approval that contradicts itself into
  the rejection its own findings describe. Nothing here turns a rejection into an
  approval.
- A verdict written only as prose still cannot be acted on, whichever way it
  decided. A run whose reviewer answered without a machine-readable verdict is
  asked once for the same decision in a routable form — deliberately symmetric,
  so it never makes "approved" the easier answer.

### The quality judge is a signal, not a gate

`RunQualityJudge` scores a finished run against this rubric as an independent
one-shot call — not the reviewer agent, to avoid self-preference bias. The score
is advisory: it feeds metric #3 and the error budget, and **never changes item
state**. A run with no score and a run scored zero are different facts, and are
reported as different facts.

## Scope discipline

Touch only what the item requires. Broad, opportunistic refactors are out of
scope for an autonomous run — they are proposed as new backlog items instead.
This applies to every agent, and it is the rule the three blocking scope failures
above are all instances of.

## What an unattended agent is allowed to remember

**An autopilot agent keeps no memory of its own.** Claude Code's auto-memory is
on by default and keys its directory to the **git repo root**, so a worker and
the reviewer of its work — the same repo, by construction — would share one
self-maintained memory under `~/.claude` that Kiteloop never displays, never
curates and never gates. Cross-role contamination is the concrete hazard: a
worker's half-verified belief written there becomes the reviewer's prior on the
next run, and the reviewer's independence is what this whole model rests on.

So Kiteloop spawns unattended sessions with `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`
(`ClaudeCodeCLIRuntime.sessionEnvironment`). Unattended means a run has taken the
agent over — the worker and the reviewer of an item in flight — or the session is
a one-shot headless call (`HeadlessAgentRunner`: the quality judge, the
coordinator's advisors, backlog AI edits). A run replaces a role's session first
if it was started for a chat, because a process's environment is fixed when it
spawns.

What compounds instead is audited: run outcomes distilled into the project's
capped coordinator knowledge, which both agents are handed at the start of every
item, and `propose_memory`, which a human answers. Both are things you can read.

**Chatting with an agent is unchanged.** No session is spawned unattended
because of a role — only because a run has taken that agent over — so the worker
and the reviewer are ordinary chat agents between runs, memory and all. (A
session a run leaves behind keeps the terms it was spawned with until something
restarts it; the environment of a live process cannot be changed, only
replaced.) Whether an interactive session *should* keep a self-maintained memory
is an open question, and not something this rule decides.

## Adopting this in your own project

**The operative copy of these rules lives in the project's `CLAUDE.md`.** That is
not incidental: Kiteloop loads the `CLAUDE.md` chain into every agent's context
(`MemoryManager.loadClaudeMDChain` — `~/.claude/CLAUDE.md`, then the project
root's, then `.claude/CLAUDE.md`), so the worker and reviewer read these rules on
every run. They are live guardrails, not documentation about guardrails.

A project adopting Kiteloop should carry its own version of the Definition-of-
Ready, Definition-of-Done and reviewer rubric in its `CLAUDE.md`. Some of what is
described here holds regardless — `DefinitionOfReady` and `GroundingCheck` are
app code and gate every project's queue. The rest is only true of a project that
tells its agents so.

Two pieces of advice from having done it here:

- **Write the war stories in.** "Never report success over an empty diff" is a
  rule an agent can rationalise around. "One item was run five times that way,
  each run ending *Done, CI is green*, with nothing delivered" is one it cannot.
- **Prefer rules a machine can check.** Every clause above that moved from prose
  into `DefinitionOfReady` stopped costing runs the day it moved. The clauses
  still written as prose — out-of-scope, the changelog rule, scope discipline —
  are the ones that still get missed.

## See also

- [adr/0001-autonomous-run-model.md](adr/0001-autonomous-run-model.md) — the
  sandbox → PR → human-gate decision, its alternatives and its costs.
- [success-metrics.md](success-metrics.md) — the SLIs, SLOs and error budget that
  govern how far the ODD expands.
- [backlog-format.md](backlog-format.md) — the item format, and the
  Definition-of-Ready as the parser and gate implement it.
- [how-work-flows.md](how-work-flows.md) — who moves an item between statuses,
  and who is allowed to.
- [worktree-isolation.md](worktree-isolation.md) — how a run is contained.
- [autopilot-runbook.md](autopilot-runbook.md) — running a groomed backlog
  unattended.
- `CLAUDE.md` → *Autonomy* — the operative copy the agents are given.
