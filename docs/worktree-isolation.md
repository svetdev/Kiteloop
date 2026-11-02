# Worktree Isolation

How an autopilot item runs in its own git worktree instead of your working tree —
what gets created, what the agents see, and what survives the run. (Diátaxis: this
is *explanation*. For the operating steps see
[`autopilot-runbook.md`](autopilot-runbook.md); for the config fields see
[`control-api.md`](control-api.md); for the decision behind it see
[ADR-0001](adr/0001-autonomous-run-model.md).)

Implementation: `Kiteloop/Services/WorktreeSession.swift` (the per-item lifecycle),
`Kiteloop/Services/WorktreeManager.swift` (the git plumbing),
`Kiteloop/Services/BacklogAutopilot.swift` (where they hang off the run).

## Why

Off, the worker edits the **live project tree**. That is fine while you are
watching, and unsafe when you are not: an unattended run mutates the same files
you have open, a half-finished item leaves debris in your checkout, and a bad run
has no revert seam other than `git checkout .`.

On, each item gets a dedicated worktree on a branch `kiteloop/<item-id>`. The
worker and reviewer are moved into it for the duration, and your checkout is not
touched. What the run produces is a branch — a thing you can diff, check out, keep
or delete.

Isolation is a *containment* boundary, not a security sandbox. An agent's `Bash`
can still reach outside the worktree, and an unattended run bypasses the
permission prompt layer on purpose — nobody is watching it, and a prompt that
times out is a denial, not a boundary. What bounds a run is named in
[autonomy.md](autonomy.md#boundaries): this worktree, the stray-work refusal,
the verify gate, review, the human gate, and a short deny list of command
shapes.

## When it applies

Always, for a project whose root is a git repository — it is not a setting.
A plain directory has no worktrees to run in, so its items run in the live
tree and the run log says why (*"Worktree isolation skipped — not a git
repository"*). The `useWorktree` key that used to switch it is ignored,
whether it is sent in a `PUT /v1/autopilot` or still sits in
`.kiteloop/autopilot-config.json`.

## Anatomy

| | |
|---|---|
| Worktree path | `<project>/.kiteloop/worktrees/<item-id>` |
| Branch | `kiteloop/<item-id>` (`WorktreeSession.branchName(for:)` — the one place this is spelled) |
| Base | the project's `baseBranch` (`refs/heads/<name>`), or the project root's current `HEAD` when unset |
| Created by | `git worktree add -b kiteloop/<item-id> <path> <base>` |
| Ignored by git | `.kiteloop/worktrees/` is appended to the project `.gitignore` when the project is opened (`KiteloopProject.requiredGitignoreEntries`) |

The base is the project root's `HEAD` as it stands when the item starts — Kiteloop
does not fetch or branch from `origin/<default>`. Two items run back to back
therefore branch from the same commit unless something advanced `HEAD` in between
(an auto-merge, or you).

### Which branch is the work

A project may name the branch its runs are about — the **Base branch** field
on Project Settings → Autopilot, `baseBranch` on [`PUT /v1/autopilot`](control-api.md#put-v1autopilot).
Unset means the checkout's `HEAD`, exactly as above. With a name, three things
change and nothing else does:

- **Fork.** The worktree is created from the local `refs/heads/<name>` — no
  fetch, no remote-tracking guess. A name no local branch has refuses the run at
  start, the way any other failed isolation does: the item is blocked with
  *"worktree isolation could not be established (base branch `<name>` does not
  exist in this repository)"* (`WorktreeSession.begin`).
- **Diff.** The run's diff — what the reviewer and the quality judge
  read — starts at the merge base with that ref, not with
  `HEAD` (`BacklogAutopilot.runDiffBase`).
- **Landing.** `WorktreeManager.mergeAndVerify` takes the base and lands the
  verified merge in one of three ways, decided before the scratch worktree is
  made:
  1. the checkout is on the base — merge at its tip, verify, fast-forward the
     checkout, as always;
  2. the base is checked out in some *other* worktree of the repository — a
     review checkout, a stale scratch — the merge is **refused**, naming that
     worktree's path: *"base branch `<name>` is checked out at `<path>`; merge
     there or remove that worktree"*. `git update-ref` would not have refused;
     it would have moved the ref under a live index and `HEAD`, which is what
     was found on 2026-09-03 when "run on `quality/rebased`" meant registering
     the checkout a second time and the base turned up checked out in a stale
     scratch worktree;
  3. otherwise — merge at the base's tip, verify, then move `refs/heads/<name>`
     to the merge commit with a compare-and-swap (`git update-ref <ref> <merge>
     <tip-read-at-start>`) and leave the checkout alone. A tip that advanced
     while the verify ran refuses the update, naming the branch. The app never
     switches a checkout.

A pull request (`openPullRequest`) opens against the base too, so the PR and the
merge cannot name different targets, and the approval gate's own merge —
`BacklogViewModel.resolveGate`, the path the panel, the item's page and
`POST /v1/backlog/approve` all take — lands on the same base, as does the
gate's freshness check.

## Lifecycle of one item

`WorktreeSession` owns the whole arc, so setup and teardown cannot drift apart on
the branch name or on which agents were moved. A session exists **only** for an
isolated run — `begin` returns `nil` for a live-tree run, so `session?.` in
`BacklogAutopilot` reads exactly as "if we isolated".

### 1. `begin` — decide, create, move the agents in

First the fallback rules (`WorktreeSession.decide`, pure and tested without a repo):

| Condition | Result |
|---|---|
| Isolation off | live tree, silently |
| No project root | live tree, logs *"Worktree isolation skipped — no project root"* |
| Project root is not a git repository | live tree, logs *"Worktree isolation skipped — not a git repository"* |
| Otherwise | isolate |

Then:

1. Any agent still **pinned to another item's worktree** fails setup outright: a
   live run's worker is not this item's to take, and restarting it would put two
   items' edits in one tree.
2. Any leftover worktree **and branch** for this item id is removed, so
   `git worktree add -b` cannot fail on a branch a previous run left behind.
3. The worktree is created and the run logs *"Isolated run in worktree
   kiteloop/&lt;item-id&gt;"*.
4. The worker and the reviewer are **stopped and restarted with `cwd` set to the
   worktree**, then **pinned** to it (`Orchestrator.pinWorkingDirectory`). A Claude
   Code process has its working directory fixed at spawn, so a fresh session per
   item is the only way the agents end up editing the worktree rather than your
   checkout — and the pin is what keeps them there (see below).

If any of that throws, setup rolls itself back — the worktree is dropped and every
agent is unpinned and restarted on the project root — and **the item is blocked**,
with *"worktree isolation could not be established (…)"* in the log and in its
Notes. It does **not** fall back to the live tree: a git project always
isolates, so its checkout is not where work may land, and a run that cannot honour it has nothing to offer
but writing into the checkout you asked to be left alone.

### The pin: why restarting an agent is not enough

Restarting the agents into the worktree holds only until something else restarts
them — and a dozen paths do, every one of them passing the **project root**:
`/model`, `/compact` and the other slash commands, the team-config watcher
re-adding an agent, the no-work restart after an empty run. Any of them silently
re-roots a worker mid-item, and from then on its edits land in your checkout while
its worktree and branch stay empty.

So the directory is decided in one place rather than at each call site.
`Orchestrator.startAgent` resolves the caller's `cwd` through the agent's pin: a
pinned agent starts in its pin whoever asked and whatever they passed. `end`
releases the pin before restoring the agents to the project root. A pin whose
directory is no longer on disk — a run that crashed between creating a worktree
and tearing it down — is dropped and logged rather than honoured, so a crash
cannot strand an agent pointing at a path that isn't there.

Two items were built straight into the main checkout this way on 2026-08-11,
uncommitted and interleaved with each other, while the branches they were supposed
to be on stayed empty. Both reached the approval gate reading as ordinary finished
work.

`WorktreeManager.create` refuses a project that is not a git repository up front
(`WorktreeError.notAGitRepository`), so the fallback holds even for a caller that
skipped `decide` — the error carries the path and the run log says *"… is not a
git repository"* rather than a generic failure.

### 2. During the run

The worktree is just a checkout, so everything downstream that needs a directory
uses it: the **salvage verify** — the re-check that rescues a run cut short by the
session cost cap, a stall or the retry ceiling — runs the item's `verify:`
commands inside the worktree (`WorktreeManager.runVerify`), not in your tree.

The project's own checkout is snapshotted (`git status --porcelain`) as the item
starts, and read again when it ends. Anything that became dirty in between is the
run writing outside its worktree, and the item is **blocked** naming the paths —
*"run wrote outside its worktree — 2 paths changed in the project's checkout
instead of the branch: …"*. This is the case the branch signals cannot see: a run
that built into the main checkout leaves an empty worktree and an empty branch,
which reads as a run that produced nothing and is sent round again on top of the
last attempt's uncommitted work.

Dirt that was already there before the item started is a human's own edits and is
never counted, and neither is the run's own bookkeeping — the backlog file whose
statuses it moves, the detail file it appends Notes to, `.kiteloop/`. A snapshot
that could not be taken reports nothing: this signal blocks an item, so an
unreadable repository fails towards letting the run through.

### Shared build output

A fresh worktree is a cold build for any tool that keys its output on the
directory it runs in. On 2026-09-03 a Rust project's items each paid a full
`cargo build` — 18 to 27 minute runs, most of it compilation the previous item
had already done — and a verify that needed an artifact under `target/` could
never pass in the merge scratch worktree, whose `target/` did not exist. So
every verify shell and agent spawn on a project's behalf, in an item worktree
or the merge scratch worktree, gets the project's **build exports**
(`BuildEnvironment`, `RunEnvironment`) beside its composed `PATH`:

- **Derived**, each only when its marker file exists at the project root:
  `Cargo.toml` → `CARGO_TARGET_DIR=<root>/.kiteloop/build/cargo`;
  `package.json` → `npm_config_cache=<root>/.kiteloop/build/npm`. Cargo
  serialises concurrent users of one target directory with its own lock, so
  parallel item runs wait on each other rather than corrupt anything.
- **Explicit**, from `buildEnvironment` in `.kiteloop/config.json` — a map of
  variable to value that wins over the derived entries. A value may carry `~`
  and `$PROJECT_ROOT`. `PATH` cannot be set here; it is `extraExecutablePaths`'s,
  and such an entry is dropped with a log line.

```json
{ "buildEnvironment": { "CARGO_TARGET_DIR": "$PROJECT_ROOT/../shared-target",
                        "SCCACHE_DIR": "~/.cache/sccache" } }
```

Xcode is the exception, on purpose: `xcodebuild` in a worktree builds into the
worktree's own `.kiteloop/DerivedData` (`WorktreeBuildOutput`), because a
shared DerivedData registered every worktree's `.app` under the real bundle id
and `open -a Kiteloop` resolved to a stale binary — measured on 2026-08-06,
and unchanged by this.

The shared directory lives under the project's `.kiteloop/build/`, which is
gitignored and outlives every worktree. Nothing prunes it: it is the
operator's, like any build cache. What a project exports is visible per
project as `exports` in `GET /health` and under the tools in the
Diagnostics window's Health tab.

### 3. `end` — what the outcome does to the worktree

`WorktreeSession.teardownAction(for:)` maps the item's outcome onto one of three
fates:

| Outcome | Action | On disk afterwards |
|---|---|---|
| `done`, `awaiting-approval` | commit everything as `autopilot: <item-id>`, remove the worktree | branch kept — **or** dropped too, when there was nothing to commit |
| `blocked` | leave it | worktree **and** branch, for you to look at |
| `cancelled` | discard | nothing |

Then both agents are restarted back on the project root, whatever happened.

`end` returns the branch that survived, and that is what the run result reports —
so a run with an empty commit or a cancelled run reports **no** branch rather than
naming a ref you cannot check out.

A teardown that had to commit is itself a finding. The commit it writes
carries the app's subject, `autopilot: <item-id>`, which two readers match to
find stranded work — so a run whose commits read that way is a run whose
worker never committed. The teardown reports how many files it committed, and
the autopilot writes that to the item's Notes as an advisory finding; the
worker prompt's closing line says to commit before handing off, with the
repository's own subject convention.

### Running an item again

The next run of an item starts by dropping whatever the last one left —
the checkout directory and the `kiteloop/<item-id>` branch — and creating
both afresh from the base. Two leftovers used to stop that. A checkout
directory git had already pruned the registration for (a crashed run) made
`worktree add` refuse with "already exists"; `create` now removes a directory
at its path that carries a `.git` file and that `git worktree list` no longer
names, and nothing else. And a branch a person has checked out elsewhere to
review it cannot be deleted; git says so, and the run is refused with that
reason, which names the checkout holding the branch. The item is blocked with
it, so the fix is one `git worktree remove` away rather than a hunt.

### 4. Optional auto-merge

The autonomy dial's `land` rung (off by default — the dial starts at `off`;
`autoMergeOnApproval` still sets it, deprecated for one release). On `land`, an item that reached
`awaiting-approval` with a surviving branch is merged **after** teardown — the
worktree is gone by then and the merge happens in the live project root
(`WorktreeManager.mergeAndVerify`):

1. Refuse if the project root's tree is dirty *in a way that matters*. Two kinds,
   and the reason says which (naming the offending paths, capped so a very dirty
   repo can't produce an unreadable log line):
   - **Tracked modifications** — *"working tree not clean (modified):
     CHANGELOG.md, Kiteloop/… (+3 more)"*. Always refuse: the rollback below is a
     `reset --hard`, which would take those unrelated edits with it.
   - **Untracked paths that collide with the incoming diff** — *"working tree not
     clean (untracked, colliding): docs/new-page.md"*. `reset --hard` never
     deletes untracked files, so the rollback rationale doesn't reach them; but
     `git merge` refuses to overwrite an untracked file it has to write, so a
     collision is a real refusal. A wholly-untracked directory (`docs/`) collides
     with anything the merge lands inside it.

   Untracked files the merge doesn't touch — a `.claude/settings.local.json`,
   build droppings — do **not** block. They used to, which meant one stray
   settings file could refuse every approval in a project.
2. `git merge --no-ff` the branch into a scratch worktree at the base's tip — the
   project's `baseBranch`, or whatever the project root has checked out (see
   [Which branch is the work](#which-branch-is-the-work)). A conflict aborts the
   merge and reports *"merge conflict"*.
3. Run the merge-verify commands **on the merged tree** — the item's own
   `verify:` first, then the project's `autoMergeVerifyCommand`. Both, when both
   exist: a project-level command is an *addition* to the item's verify, never a
   substitute, so the last gate before `main` is never weaker than the one the
   work was built against. The first failure resets the root back to the
   pre-merge SHA and reports *"verify failed on merged tree (`<command>`)"*,
   naming which one refused. Each runs under its own timeout — the project's
   `autoMergeVerifyTimeoutMinutes`, derived from its own verify phases and 30
   minutes until there are enough of them, so `<n>` below is that deadline in
   seconds — and an overrun still fails closed rather than skipping what
   follows it, reporting *"verify timed out after `<n>`s on merged tree
   (`<command>`)"*, since a command that never finished judged nothing about
   the tree and a killed one that printed nothing leaves no output to say so.

   A project that never set `autoMergeVerifyCommand` still has a merge-verify:
   the verify map's widest rule — the rule in the root's `kiteloop-verify.json`
   whose glob matches the most of the tree, ties to the longest command — is
   read as the project's own idea of "green" (`RepoConventions`). Likewise a
   project that never set `worktreeSetupCommand` gets the setup its tree
   implies: an install beside each lockfile, a generate beside a `project.yml`
   whose `.xcodeproj` is absent or gitignored, each step in its own directory.
   `GET /v1/autopilot` reports both effective commands beside the settings, with
   a source saying `configured` or which file or rule they came from. A value a
   person set always wins.

   That ordering is not cosmetic. `autoMergeVerifyCommand` used to *replace* the
   item's verify, and on 2026-08-10 one project merged a Rust-only diff
   whose gate was a web-only `npm test`: it passed, having compiled none of what
   changed. The item's own full-CI verify never ran.

   The run log and the run's metric record name what gated each merge
   (`verify=item verify: … + merge-verify: …`), so a merge validated by a suite
   unrelated to the diff is visible afterwards instead of having to be
   reconstructed from the diff and the project config.

Green on all three: the merge stays, the item goes to `done`, and the branch is
removed (`WorktreeManager.removeMergedBranch`) — every commit on it is in the
base and the ref was all that was left of the run; the log names the branch
either way, and a branch git will not delete is kept with git's reason. Any
failure leaves the item at Awaiting Approval for a human — main is never
advanced by work that does not build.

Note the gate is objective throughout: the reviewer's pass is what got the item to
`awaiting-approval`, and the merge itself is gated on a command, never on the
quality judge's opinion (which is advisory).

## Hygiene: what happens to worktrees nobody ended

`end` is the only thing that removes a worktree during a run, and it only runs if
the run reaches its own ending. A crash, a force quit, or the app being displaced
mid-item leaves the checkout — and its registration in `.git` — behind for good.
Nothing used to clean those up: measured in this repo on 2026-08-08, 30 registered
worktrees and 28 directories, each a full checkout of the project.

So **opening a project sweeps its worktrees directory**
(`ProjectSession.bootstrap` → `WorktreeManager.sweep`, in the background):

1. **`git worktree prune`** — drops registrations whose directory is gone. Safe by
   construction: prune only touches entries git can no longer find on disk. It
   never deletes a branch.
2. **Reap orphans** — a directory under `.kiteloop/worktrees/` with no live run
   behind it, but only when there is provably nothing to lose. The checkout goes;
   **an unmerged branch is kept** — it is the run's output.
3. **Remove landed branches** — every `kiteloop/*` branch the base already
   holds, reported as `landedBranchesRemoved`: the landings from before a
   landed merge removed its own branch, and any merged by hand since. A branch
   a live run holds, or one with a commit the base cannot reach, is never
   deleted.

Open is the seam, not quit, for the same reason `AppDelegate` reaps session FIFOs
at launch: `applicationWillTerminate` covers an orderly quit and nothing else,
while the crash and force-quit cases that actually strand a worktree skip it.

### What is never reaped

`WorktreeManager.orphanVerdict` is the rule, and it is pure so it can be read
without a repo in front of you. Two things veto a reap outright:

| Condition | Verdict | Why |
|---|---|---|
| A run in flight declares the item id active | left alone | it is not an orphan |
| The branch holds commits the project root's `HEAD` can't reach | kept, logged *"branch has unmerged commits"* | that is the run's output |
| The worktree has uncommitted changes (modified **or** untracked) | kept, logged *"uncommitted changes"* | that is exactly what a `blocked` item's worktree holds, kept on purpose above — and any crashed run's work-in-progress |
| Neither | reaped; the branch goes with the landed-branch pass above when the base holds all of it | every byte is already reachable from `HEAD` |

Every uncertain read of git resolves to *keep*: a branch that can't be counted, a
worktree whose status can't be read, and a project that isn't a git repository at
all all leave the directory where it is. Nothing is deleted on a guess, and a kept
orphan is named in the log — being told it is there is the point of leaving it.

## Finding the work afterwards

- **In the app** — a finished isolated item shows a branch chip in the run history
  (`kiteloop/` prefix stripped). Its menu offers *Copy Branch Name*, *Copy Checkout
  Command*, and *Reveal Worktree in Finder* when the worktree is still on disk.
  Deliberately read-only: nothing in it checks a branch out, because moving your
  `HEAD` under a running autopilot is not worth a shortcut.
- **Headless** — `GET /v1/runs/<id>/result` carries `branch` when the run created
  one, and the SSE log stream carries the *"Isolated run in worktree …"* line.
- **On disk** — `git worktree list` and `git branch --list 'kiteloop/*'`.

## Gotchas

- **Re-running an item destroys its previous branch.** `begin` clears
  `kiteloop/<item-id>` before creating the new worktree. If a blocked item left work
  you care about, rename or merge that branch before you re-run it.
- **Auto-merge needs isolation on.** Without a branch there is nothing to merge, so
  `autoMergeOnApproval` is a no-op for a project that is not a git repository.
- **A non-git project runs in the live tree.** The fallback is per-run, and
  logged.
- **Approving an item does not commit anything.** With isolation on, the commit
  already happened on the branch at teardown; approval moves the item's status, not
  your files.
- **Approval is refused when the work is not on a branch.** With isolation on, an
  item at the gate whose branch does not exist *and* whose project checkout has
  tracked modifications is not approved: *"the work is not where it should be —
  this item has no branch, and the project's checkout has uncommitted changes
  (modified): …"*. "Nothing to merge" covers two opposite states — a branch that
  was merged, and work that never reached a branch at all — and only the first is
  done. Commit or stash the checkout and approve again, or reject the item.
- **One item at a time per project**, so worktrees do not accumulate — but a
  blocked item's worktree stays under `.kiteloop/worktrees/` until you remove it
  (`git worktree remove --force`) or re-run the item. The open-time sweep will not
  take it either: it holds uncommitted work, which is the whole point of keeping it.

## Tests

| Behaviour | Test |
|---|---|
| Create / commit / remove / git-repo detection | `KiteloopTests/Services/Autopilot/WorktreeManagerTests.swift` |
| Prune, orphan reaping, and the guards that veto it | `KiteloopTests/Services/Autopilot/WorktreeManagerTests.swift` |
| Fallback rules and teardown mapping | `KiteloopTests/Services/Autopilot/WorktreeSessionTests.swift` |
| Setup that cannot isolate fails the item, and the agent pin | `KiteloopTests/Services/Autopilot/WorktreeSessionTests.swift` |
| Work that landed in the project checkout instead of the branch | `KiteloopTests/Services/Autopilot/RunWorkEvidenceTests.swift` |
| Approval refused over an empty branch and a dirty checkout | `KiteloopTests/Services/Autopilot/WorktreeManagerTests.swift`, `KiteloopTests/ViewModels/BacklogViewModelStatusTests.swift` |
| Isolation read off the checkout, not a stored setting | `KiteloopTests/Services/Autopilot/BacklogAutopilotWorktreeIsolationTests.swift` |
| The branch/worktree link the history shows | `KiteloopTests/Services/Autopilot/BacklogAutopilotBranchLinkTests.swift` |
| Salvage verify against a worktree | `KiteloopTests/Services/Autopilot/AutopilotSalvageTests.swift` |
| `.kiteloop/worktrees/` stays ignored | `KiteloopCore/Tests/KiteloopCoreTests/Models/KiteloopProjectGitignoreTests.swift` |
