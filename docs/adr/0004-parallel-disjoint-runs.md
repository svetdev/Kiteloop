# ADR-0004: Parallel disjoint runs — should two runs on non-overlapping file scopes proceed concurrently

- **Status:** Proposed — decision only, no enforcement code shipped
- **Deciders:** the maintainer
- **Related:** [ADR-0001](0001-autonomous-run-model.md) (sandbox → PR → human-gate
  model this ADR stays inside), [ADR-0003](0003-run-sandboxing.md) (surveyed what
  isolates a run's *execution*; this ADR is about what isolates two runs from
  *each other*), [`worktree-isolation.md`](../worktree-isolation.md),
  [`backlog-branch.md`](../backlog-branch.md), [`control-api.md`](../control-api.md)
  (states "one run at a time per project" as a v1 limit)

## Context

Today's rule, stated in two places: `worktree-isolation.md` — *"One item at a
time per project, so worktrees do not accumulate"* — and `control-api.md` —
*"One run at a time per project. A second `POST /v1/runs` waits out the
previous run's tail, then 409s naming the run it is waiting for."* One
`BacklogAutopilot` instance is cached per project (`MainWindow.swift:1763`,
`autopilotCache.instances`) and drains its `runQueue` (declared at
`BacklogAutopilot.swift:784`) strictly one item at a `currentIndex` at a time
(`currentIndex = index` in the queue loop, `BacklogAutopilot.swift:3013`);
nothing in the app today starts a second
worker/reviewer pair before the first's item has left the queue.

Item runtimes are real time on the table: this project's own measured
distribution is 3–18 min per item, median 6 (accumulated project knowledge),
corroborated by two runs recorded in this session's own
`~/.kiteloop/task-metrics.jsonl` — `run-sandboxing-decision` at 440s (~7.3
min) and `stale-item-sweep` at 1212s (~20 min, the item that got rejected for
coverage gaps below). A queue of a dozen ready items at a 6-minute median is
over an hour of wall clock with nothing else happening concurrently.

`VerifyCoverage` (`KiteloopCore/Sources/KiteloopCore/Services/VerifyCoverage.swift`)
already has the one piece of machinery this question needs: a deterministic,
tested glob matcher (`matches(glob:path:)`) that decides whether a changed
path falls under a rule. It is proposed here as the arbiter of "disjoint"
because it is the only glob engine in the codebase that already treats this
comparison as a gate rather than a heuristic — no model, no score, a path
either matches a glob or it doesn't. It is not, today, wired to run *before*
a run starts: `VerifyCoverage.evaluate` reads `changedFiles` from a
**produced diff**, after the worker has already run. Using it to gate
*dispatch* — "may item B start now, next to item A" — needs items to declare
a scope *before* either has a diff, which nothing in `DefinitionOfReady` or
`docs/backlog-format.md` requires today. `Out of Scope` on an item is prose
bullets, not machine-checkable globs (`backlog-format.md:351`). That gap
is itself part of what this ADR has to weigh, not just the glob engine's
capability.

The question: if two items' declared scopes don't overlap by that same
glob logic, may their runs proceed concurrently? The one-run rule is a real
integrity property, not just a queue-depth limit — so each resource it
protects has to be named and checked against "protected by disjoint file
scope," "protected by ordering the merges," or "not protected by either."

## Shared resources surveyed

### 1. The project-root git checkout (`WorktreeManager.mergeAndVerify`)

`mergeAndVerify` (`WorktreeManager.swift:1211`) runs `git status
--porcelain` for a dirty-tree refusal, `git merge --no-ff` against
`projectRoot`'s **single checked-out branch**, and on a verify failure `git
reset --hard` back to the pre-merge SHA. All three read and write the same
`.git/HEAD`, `.git/index`, and working tree — not per-file state, per-repo
state. Git itself serializes concurrent mutators of one working tree via
`.git/index.lock`; a second `git merge` invoked while the first is mid-merge
does not race cleanly, it fails to take the lock or (worse, if the lock is
briefly free between the first merge's internal git calls) reads a
half-updated index. This has nothing to do with which files either merge
touches.

**Verdict: not protected by disjoint scope at all.** Two items whose diffs
share not one path still cannot merge at the same instant into the same
checkout — the contention is mechanical (one `HEAD`, one index, one working
tree), not semantic (whose lines conflict). This resource needs **ordering**,
full stop; disjointness is irrelevant to it.

### 2. The backlog branch (`docs/backlog-branch.md`, `.kiteloop/backlog-tree/`)

Every backlog write — a status flip, a note, a reviewer's advisory findings —
is its own commit against **one private checkout** at
`.kiteloop/backlog-tree/`, with pushes rate-limited to one per minute
(`backlog-branch.md:57-59`). This fires on *every* item's status transitions
regardless of what code that item touches: a UI-only item and a
`KiteloopCore`-only item both commit to the same `BACKLOG.md` on the same
branch. The doc's own stated limit is blunt about what protects this today:
*"the one-run-per-project guard lives inside a single app instance"*
(`backlog-branch.md:73-77`) — i.e., the *only* thing serializing these
commits is that nothing else is running. Two lanes inside that same instance
remove that guard unless something replaces it.

**Verdict: not protected by disjoint scope at all**, for the same reason as
resource 1 but sharper — this isn't even the *item's own* files, it's a
project-wide log every run writes into no matter its scope. Needs its own
serialization (or an actor-isolated queue) independent of what the two items'
globs say.

### 3. Complexity and CRAP baselines (`.swiftlint-baseline.json`, `.crap-baseline.json`)

Traced the actual write path rather than assuming one exists: `check-crap.py`
and `check-complexity.py` (`check-complexity.sh` is a 15-line shim over it)
both run **read-only** (`--quiet`) as pre/postflight
of `scripts/run-unit-suite.sh`, and independently as part of an item's own
`verify:` when `VerifyCoverage`'s map requires them for a Swift-touching diff
— this session's own metrics ledger shows exactly that gap on
`stale-item-sweep`: *"diff touches `**/*.swift` … but verify never runs
`./quality/bin/check-complexity.sh`"*. In both call sites the check reads the
existing baseline and compares; only `--write-baseline`, a **manual, human-run**
flag (`check-crap.py:314`, `check-complexity.py:135`), ever writes the
file. Nothing in the autopilot's per-item verify or the merge-verify path
(`xcodebuild … build-for-testing`) invokes it.

**Verdict: not contended by concurrent lanes, because neither lane writes
it.** This looked like the item most likely to need scope-based protection —
"two runs racing to update the same ratchet" — and turns out not to be a
live concern once the write path is traced; both lanes only ever *read* the
same baseline file, which is safe unboundedly, disjoint or not.

### 4. `docs/suite-status.md`

Appended only by `scripts/run-unit-suite.sh` — a script the project's own
convention restricts to a human running it by hand, and which separately
refuses to start while Kiteloop itself is running (an unrelated guard against
a second app instance). The merge gate every item's run actually exercises is
`xcodebuild … build-for-testing`, which "compiles the test bundles and
launches no host… the harness runs the item's `verify:` for you"
(`docs/testing.md:1015-1017`) — it does not run the suite itself. No autopilot
code path — worker, reviewer, or merge — invokes `run-unit-suite.sh`.

**Verdict: not contended at all**, same shape as resource 3: two lanes cannot
race on a file neither of them writes. Named here because the item's context
calls it out explicitly, but tracing the write path clears it, same as the
baselines.

### 5. The per-project budget (`budgetUSD`)

One budget pool, tracked by the one cached-per-project `BacklogAutopilot`
instance (its `costGovernor`, `BacklogAutopilot.swift:1058`, sampled at
`BacklogAutopilot.swift:6252`). This is not a git
or filesystem resource — it's in-process state a run's watchdog samples and
compares against a ceiling. Disjoint file scope has zero bearing on it: two
lanes' worker sessions could touch entirely disjoint files and still jointly
overspend a shared cap if each watchdog checks "am I under the cap" and both
answer yes moments apart, before either's spend is visible to the other — a
classic check-then-act race on a shared counter.

**Verdict: not protected by disjoint scope; protected by keeping the
accounting inside the one actor-isolated instance**, same as today, just now
serving two watchdogs instead of one rather than each lane keeping (and
under-counting against) its own view of the pool.

### 6. Per-item work evidence (`RunWorkEvidence`, stray-work / empty-diff detection)

This is the one resource that already assumes exactly what this ADR is
asking about. `RunWorkEvidence`'s stray-work and empty-diff checks read the
diff off **that item's own worktree/branch** — each item already gets an
isolated `git diff`, so two lanes each produce a correct, independent answer
with no change to this mechanism at all.

**Verdict: fully protected by the existing worktree-per-item model already**
— the one resource on this list that disjoint scope (or rather, per-item
isolation, which is a stronger property than mere disjointness) already
covers for free.

### 7. Files nearly every item touches in practice

`VerifyCoverage`'s glob match is exact — it doesn't know two paths are
"basically disjoint," only whether they match a literal glob. Two files
almost every non-trivial item touches regardless of its stated domain work
against that: **`CHANGELOG.md`**, which every behaviour change gets a line
in under the current `## <version> — unreleased` heading (`CLAUDE.md`'s own
Definition-of-Done), already named in accumulated project knowledge as *"the
merge-conflict hotspot… several items landing in one `— unreleased` section
all edit the same lines"* — additive, and resolvable serially, but that's
exactly the ordering resource 1 already requires, now with real conflict
markers instead of a clean fast-forward; and **`Kiteloop.xcodeproj/project.pbxproj`**,
touched whenever a run registers a new file to a target, called out in the
same knowledge file as showing up modified after runs that add anything.

If a pairing candidate's declared scope includes either file — which most
will, the moment either item adds a new source file or changes behaviour —
`VerifyCoverage.matches` correctly reports them as **not disjoint**, and the
pairing is refused. That is the right, conservative outcome given what the
glob matcher can express (path equality, not "these are both append-only and
git can trivially auto-merge them"). It does mean the pool of item pairs
that pass a literal-glob disjointness check is narrower in practice than
"picked from two different epics" — expect most eligible pairs to be
single-file, tightly scoped items that don't cross either shared file.

## Throughput estimate

The bulk of an item's wall time is the worker/reviewer conversation
(resource 6, already isolated per item); the merge step — `git merge` plus
`xcodebuild … build-for-testing` — is the tail, and it's the one part that
must serialize regardless (resource 1). Against the measured 3–18 min range
(median 6), if merge-verify accounts for roughly 1–3 of those minutes, two
genuinely disjoint items running their agent phases concurrently and merging
back-to-back could compress a 12-minute sequential pair to something in the
7–9 minute range — call it a 30–40% queue-throughput gain **on the pairs
that qualify**, not the 2x a naive reading of "two lanes" would suggest,
because (a) merges never parallelize and (b) resource 7 narrows how often a
real pair is disjoint by the literal-glob standard this mechanism can check.

## Decision

**Go, narrowly:** two lanes, not N — the resources above (particularly 1, 2,
and 5) each need to move from "protected by being the only run" to
"protected by an explicit serializer," and that migration should be proven
at the smallest scale before it's generalized.

The smallest safe shape:

1. **Eligibility is computed before dispatch, not after.** This needs a new,
   machine-checkable declared scope on an item — `VerifyCoverage.matches`
   reused as the comparison, but fed from something new (a `paths:` glob
   list groomed onto the item, analogous to `verify:` — not `touches:`, which
   has since shipped with a different meaning: the protected paths an item is
   excused to change, `backlog-format.md` § Protected paths), since today's
   `Out of Scope` is prose and `VerifyCoverage.evaluate` only ever judges an
   already-produced diff. No declared scope on either item, or any overlap
   including `CHANGELOG.md`/`project.pbxproj` per resource 7, refuses the
   pairing — deny by default, the same posture `VerifyCoverage`'s own doc
   comment already takes ("a gap fails the run rather than quietly running
   the missing command").
2. **Worker + reviewer phases run concurrently, in separate worktrees.**
   No change to `WorktreeManager`'s per-item isolation (resource 6) — this
   already supports N simultaneous worktrees; what's new is dispatching two
   items' agent sessions at once instead of one at a time.
3. **Merges are strictly serialized**, through the existing single
   `WorktreeManager`/`BacklogAutopilot` instance — a queue or lock around
   `mergeAndVerify`, first-ready-first-merged, not a race. This is resource 1's
   requirement and does not depend on the pairing being disjoint at all;
   it would be required even for two unrelated single-file items.
4. **Backlog-branch writes stay behind the same single serializer** (resource
   2) regardless of which lane produced them — status flips from lane A and
   lane B interleave through one committer, not two independent ones racing
   `.kiteloop/backlog-tree/`.
5. **Cost-cap bookkeeping stays inside the one actor-isolated instance**
   (resource 5), sampled by both watchdogs against the same counter, not
   duplicated per lane.

## Consequences

**Positive**
- Throughput gain on the queue's genuinely-disjoint tail, without touching
  the sandbox → merge → human-gate model ADR-0001 already decided — the
  isolation and gates are unchanged, only how many item's worker phases run
  at once.
- Reuses `VerifyCoverage`'s existing, tested glob engine as the disjointness
  arbiter rather than inventing a second one.
- Resources 3, 4, and 6 need **no new protection** — tracing their actual
  write/read paths cleared them; the increment is smaller than "parallelize
  everything the one-run rule touches" would suggest.

**Costs / follow-ups**
- A declared-scope concept has to be added to the groomed item shape
  (`touches:`, or similar) — `DefinitionOfReady` doesn't require one today,
  and without it there is nothing to compare before a diff exists.
- Two watchdogs sampling one cost-cap counter, and two lanes' merges queued
  through one lock, are new concurrency surfaces inside `BacklogAutopilot`
  that need their own tests (a TOCTOU on the cap, a merge-queue starvation
  case) — this ADR does not design that locking, only names where it's
  required.
- Resource 7's carve-outs (`CHANGELOG.md`, `project.pbxproj`) are a
  maintenance burden that grows if the set of "everyone touches this" files
  grows; a literal glob matcher has no way to express "these two changes to
  the same file are safely additive," so every such file has to be either
  named explicitly or accepted as a standing disqualifier for pairing.
- Both lanes' `budgetUSD` draws from a project that is already
  running roughly 2x the agent spend per unit wall-clock time when two
  lanes are active — worth surfacing in `/v1/metrics`/`autopilot` status so
  an operator watching spend isn't surprised by the rate change.

## Alternatives rejected

- **Fully parallel N lanes.** The throughput ceiling is the serialized merge
  step (resource 1), which N lanes hit identically to two — more lanes only
  buys more agent-phase overlap, at the cost of more surface for the
  backlog-branch and cost-cap races (resources 2, 5) to actually manifest,
  for a gain that doesn't scale past what merge-serialization already caps.
  Two is the smallest number that proves the serializer works before
  widening it.
- **Disjoint scope alone, no merge ordering.** Rejected outright — resource 1
  shows this doesn't protect the one thing that actually needs protecting;
  a pairing being disjoint says nothing about whether two `git merge`
  invocations can run at the same instant against the same checkout.
- **Do nothing (keep one-run-at-a-time).** Still defensible on cost/complexity
  grounds — the throughput gain (30–40% on a narrow pool of qualifying pairs)
  is real but not dramatic, and resources 2 and 5 need genuine new
  concurrency-safe code, not configuration. Rejected here because the
  isolation machinery (worktrees, `VerifyCoverage`, `RunWorkEvidence`) that
  the two-lane shape leans on already exists and is already tested per item
  — the increment is adding a serializer around three specific resources,
  not building parallelism from scratch.
