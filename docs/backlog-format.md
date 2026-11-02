# The Backlog Format

`BACKLOG.md` is the file a human grooms, the Planner writes, an agent is sent
to build from, and the app rewrites on every status change. It is a plain
Markdown file that stays readable in an editor and diffs in git — there is no
database behind it, and nothing else is authoritative.

This is the description of that format. It is written against the code that
reads and writes it — `BacklogParser`, `BacklogSerializer`, `DefinitionOfReady`
(`Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/`) — rather than against intent, so where the two
could differ, what is written here is what the parser does.

- [Where the file lives](#where-the-file-lives)
- [The shape of the file](#the-shape-of-the-file)
- [The item line](#the-item-line)
- [Statuses](#statuses)
- [Writing a `verify:`](#writing-a-verify)
- [Lines the parser cannot read](#lines-the-parser-cannot-read)
- [Detail files](#detail-files)
- [Definition-of-Ready](#definition-of-ready)
- [The round-trip guarantee](#the-round-trip-guarantee)

## Where the file lives

Three locations, checked in this order (`BacklogViewModel.loadForProject`):

1. **`BACKLOG.md` in the project root.** This wins whenever it exists. It is
   self-contained, travels with the repo, and needs no configuration.
2. **The shared backlog branch** — a `BACKLOG.md` on an orphan
   `kiteloop/backlog` branch of the project's own repo, kept in a private
   checkout under `.kiteloop/backlog-tree/` (`BacklogBranch`). The team layer:
   shared through the remote, survives every clone, never dirties the working
   tree. Full design, sync semantics and limitations:
   [backlog-branch.md](backlog-branch.md).
3. **A vault-hosted `Projects/<name>/Backlog.md`**, when a vault is configured
   (Settings → General). `BacklogParser.findBacklogPath` resolves the repo to a
   project folder by, in order: a `Logs/registry.yaml` entry whose `repo:` or
   `aliases:` match, a `Backlog.md` whose own `repo:` frontmatter matches, and
   finally a fuzzy match of folder name against the repo's directory name.

Everything relative — most importantly `backlog/<id>.md` — resolves **against
the directory the backlog file is in**, not against the project root
(`BacklogViewModel.detailURL`). A vault-hosted backlog keeps its detail files in
the vault beside it.

The file is watched while a project is open (`BacklogFileWatcher`), so edits made
outside Kiteloop — by hand, by a script, by an agent with a text editor — are
picked up without a restart. The watcher survives the write-to-temp-and-rename
that most editors and every atomic write perform.

## The shape of the file

```markdown
---
project: kiteloop
repo: /Users/me/code/kiteloop
verify_default: swift build
---

# Kiteloop Backlog

## Epic: Portfolio & Backlog

Cross-project portfolio: browse every project and plan its backlog by epic.

- [x] portfolio-home | Portfolio landing screen | verify: swift build | size:M | 2026-08-04
- [ ] portfolio-view | Cross-project item list (read-only v0) | verify: swift build | size:M | draft → [detail](backlog/portfolio-view.md)
- [ ] portfolio-filters | Filter the list by status | verify: swift build | size:S | needs:portfolio-view | from:portfolio-view | ready → [detail](backlog/portfolio-filters.md)

## Bugs

- [ ] crash-on-empty-project | Crash opening a project with no files | verify: swift test | size:XS | blocked:cannot reproduce
```

Four kinds of line carry meaning. Everything else is ignored on read, and is not
written back.

### Frontmatter

An optional YAML-ish block between two `---` lines at the top. Three keys are
read; any other key is parsed and discarded.

| Key | Meaning |
|---|---|
| `project` | The project's name. Also the source of the regenerated `# <Project> Backlog` heading, title-cased |
| `repo` | Absolute path to the repository. Only used to resolve a vault-hosted backlog back to its repo; a project-local `BACKLOG.md` does not need it |
| `verify_default` | Read and written back as it is, but inherited by no item — see [`verify_default`](#verify_default) |

> **Caution.** The *first* `---` line in the file opens frontmatter, wherever it
> sits, and the next one closes it. A pair of `---` horizontal rules partway down
> the file therefore encloses a region the parser reads as key/value pairs and
> discards — item lines between them vanish, with no issue reported. Separate
> sections with a heading, not a rule.

### Epic sections

A `## ` heading opens an epic; every item line below it belongs to that epic
until the next heading. `## Epic: Portfolio` and `## Portfolio` both name the
epic `Portfolio` — the `Epic: ` prefix is stripped on read and added back on
write, so a heading written either way settles on `## Epic: Portfolio` after the
first write-back. One heading is exempt: a section named `Bugs` is written back
as `## Bugs`.

The `# ` H1 is ignored on read and regenerated on write from `project`.

Prose under a heading, **before the epic's first item line**, is the epic's
description: it is kept and written back above the items. Prose that sits *after*
the first item is not kept, and disappears on the next write-back — put epic-level
notes directly under the heading.

An item line above the first `## ` heading belongs to no epic. It parses, but it
is not kept, and the parser reports it as an issue naming the id that will be
lost.

## The item line

```
- [ ] <id> | <title> | <field> | <field> … → [detail](<path>)
```

The line is read in three steps (`BacklogParser.parseItemLineWithUnrecognisedFields`):

1. The whole line must match `- [ ] ` or `- [x] ` followed by at least one
   character. `[X]`, `[~]` and `- [x ]` are not item lines at all.
2. A trailing `→ [detail](path)` link, if present, is taken off the end.
3. What is left is split on the literal **`" | "`** — space, pipe, space. The
   first field is the **id**, the second is the **title**, and every remaining
   field is recognised by its own shape, in any order.

Only the id is mandatory: `- [ ] some-id` parses, with an empty title.

### The fields a line can carry

| Written | Meaning |
|---|---|
| `verify: <cmd>` | The command that decides whether the work is done. The space after the colon is optional |
| `size:M` | One of `XS`, `S`, `M`, `L`, `XL`; read case-insensitively |
| `lane:now` | **Read**: the item runs ahead of everything not marked — see [Lanes](#lanes). `now` is the only lane written (case-insensitively); `later` is the default and is left off |
| `flow:qa` | **Read**: the item runs through the QA flow — a specifier first, the project's clean and harden commands after the worker, and a QA agent that drives the app and judges its screenshots at the end; see [`qa-flow.md`](qa-flow.md). `qa` is the only flow written; the standard run is the default and is left off |
| `needs:a` / `needs:a,b` | The items this one must wait for. **Read**: an item whose prerequisite is not `done` is not ready |
| `from:<id>` | The item this one was discovered from — a parent it was split out of, a failed item a regroom turned into new work. Purely descriptive; never affects readiness, and may name an id that has since been archived |
| `touches:<path>` / `touches:a,b` | The protected paths this item may change. Kept on the line, but no run is gated on it any more — see [Protected paths](#protected-paths) |
| `draft` `ready` `active` `in-review` `awaiting-approval` | The item's stage |
| `blocked` / `blocked:<reason>` | Blocked, optionally with the reason |
| `18q` | Queries spent, on a done item |
| `$2.50` | Cost, on a done item. Digits and a dot — no thousands separator |
| `2026-08-04` | Completion date, on a done item |
| `team` | Jira items only: marks the item as team-owned |
| `→ [detail](backlog/<id>.md)` | Link to the groomed detail file. Always last on the line |

Fields are matched in the order above, first match wins, and the last rule is the
loose one: **any leftover field containing a `-` and no longer than 10
characters is read as a completion date.** Two consequences worth knowing —
a field that matched nothing else is dropped and reported rather than guessed at
(see [Lines the parser cannot read](#lines-the-parser-cannot-read)), and a short
hyphenated word written as a bare field is read as the completion date with no
issue raised — on an unfinished item the next write-back then drops it, since
only a done item carries one.

The serializer writes the fields it kept in a fixed order — id, title, `verify:`,
`size:`, `lane:`, `needs:`, `from:`, `touches:`, then the stage tokens — so a
hand-written line in a different order is reordered on the first write-back.
Nothing is lost by that.

### Ids

Ids are the key every lookup, run record, agent hand-off and `needs:` edge uses,
so they must be unique within the file. A repeat is reported as an issue naming
the line the id first appeared on; the first line wins everywhere the ambiguity
matters.

An id is treated as a **Jira** key when it is written `JIRA:ABC-123`, or when it
matches the canonical key shape `^[A-Z][A-Z0-9]+-\d+$` on its own. Everything
else — including a shouty local id like `backlog-refactor-2` — stays a local
item.

## Lanes

An item's **lane** says *when* it runs; its epic says *where* it belongs. They
are separate axes, and the run order reads them in that order:

1. **Lane** — every `now` item, across every epic, before any `later` one.
2. **Document order** — within a lane, epics top to bottom and items within them,
   exactly as the file is written.

`later` is the default, so a backlog nobody has promoted anything in runs in
document order, as it always did. An item **never leaves its epic to change
lane**: promoting it is a word on its own line, and the epic goes on recording
which area the work is about.

The lane changes the order and nothing else. Readiness, `needs:`, the retry
ceiling and every other pickup gate judge an item exactly as they did — a `now`
item that isn't ready is skipped first rather than run first. It is not a
dependency either: to make one item wait for another, write `needs:`.

`BacklogAutopilot` builds its run queue in this order before the pickup gates
run, so what the gates log and refuse is in the order the run will walk, and the
"next items" the coordinator and the phone read are sampled in the same order.

**Migrating off a `Now` epic.** Before lanes, the way to say "run this next" was
an epic called `Now`. On load, every item under an epic of that name is marked
`lane:now` once and the marks are written back to the file; the second load finds
them already marked and writes nothing. The items are **not** moved: nothing in
the file says which area they belong to, so filing them under their real epics is
a person's edit, made whenever they get to it. Until then the lane carries the
ordering the epic used to.

## Statuses

```
draft → ready → active → in-review → awaiting-approval → done
```

| Token | Meaning |
|---|---|
| `draft` | Filed, not yet groomed. Never picked up |
| `ready` | Groomed and queueable. The only stage autopilot pulls from by default |
| `active` | A run is building it |
| `in-review` | The worker handed off; the reviewer is judging it |
| `awaiting-approval` | The review passed; a human has to accept it |
| `blocked` | Orthogonal to the rest — an item can land here from any stage |
| `done` | Accepted |

Two rules the file itself expresses:

- **The checkbox carries `done`.** `- [x]` is done whatever else the line says,
  and a done item is written with no status word — its `18q`, `$2.50` and
  completion date take that slot instead. (One exception in the reading: a
  `blocked` field is honoured even on an `[x]` line, and the next write-back then
  files the item as `- [ ] … | blocked`.)
- **A `[ ]` line with no status field is `ready`.** If you want an ungroomed item
  to sit out of the queue, write `draft` on it. New items created in the app
  start at the project's configured new-item stage, `draft` by default
  (`.kiteloop/backlog-workflow.json`).

`done` and `draft` are human-only stages — an agent may not move an item into
either (`BacklogItemStatus.isHumanOnly`). Which stages autopilot pulls from is
per-project configuration (`autopilotPickupStages`, default `[ready]`); see
[docs/how-work-flows.md](how-work-flows.md) for who moves an item where.

## Writing a `verify:`

The `verify:` command is what makes an item objectively finishable: it is run
against the work, and a merge gate opens on it. Two rules, both of which have
cost real runs:

**It runs from the project root.** A path in it resolves from there. For this
repository the Xcode project is at `Kiteloop/Kiteloop.xcodeproj`, so a command
naming `Kiteloop.xcodeproj` at top level is wrong however plausible it reads.
Write `cd Kiteloop && …`, or the sturdier form that works from a worktree too:

```
verify: cd "$(git rev-parse --show-toplevel)/Kiteloop" && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build-for-testing
```

`GroundingCheck` refuses a command whose paths do not resolve at grooming time,
and names the directory the command runs in. It judges only whether the paths
exist — whether a command can *pass* is not decidable from its text and is not
attempted.

**A shell pipe must be written without spaces around it** — `a --json|python3 -c
'…'`, never `a --json | python3 -c '…'`. A spaced pipe *is* the line's field
separator: the command is truncated there, the tail is dropped as an unrecognised
field, and the item runs something shorter than what was written — with no error
unless something reports it. Two things now do: the parser raises an issue naming
the fix, and `DefinitionOfReady` refuses the item at grooming
(`Requirement.verifySeparator`). The separator is not changing; every backlog in
every project uses it.

The same applies to the **title**, one field to the left: a title containing
`" | "` is filed shorter than the one that was groomed, so the gate refuses that
too (`Requirement.titleSeparator`).

### `verify_default`

`verify_default` in the frontmatter is no longer a fallback: an item line that
carries no `verify:` field has no command, whatever the frontmatter says, and the
write-back puts nothing on its line. The key is still read into the file
(`BacklogFile.verifyDefault`) and written back as it was, so an older backlog
that declares one round-trips unchanged.

An item with no command is held by the Definition-of-Ready unless the project's
verify map has a rule matching every path — see below.

### Which command actually runs

When the item has a groomed detail file whose frontmatter declares `verify:`
commands, **those win** — all of them must pass. The line's own `verify:` is the
fallback (`BacklogAutopilot.declaredVerifyCommands`). Detail-file commands are
read from YAML rather than from a split line, so a spaced pipe there is fine and
runs exactly as written.

## Lines the parser cannot read

Nothing is silently dropped, and nothing is silently repaired.

- **A malformed item line** — a typo'd checkbox, an empty item — yields no item.
  It is reported as an issue saying what to type instead, *and* carried through
  the next write-back verbatim so the work it describes is not deleted from the
  file. It comes back under its own epic, after that epic's items rather than in
  its original position.
- **An unrecognised field** on a line that otherwise parsed is dropped from the
  item and reported. When the line also carries a `verify:`, the report names the
  spaced-pipe cause directly, because that is almost always what happened.
- **An unreadable value** in a field that *was* recognised — `size:Small`,
  `$1,20`, `abcq` — leaves that field unset and reports what a readable value
  looks like. It is never mapped onto the nearest thing it resembles: `size:Small`
  becomes no size at all, and the item is then skipped at pickup for having none.

The panel banners these; `GET /v1/backlog` returns them as `issues`, always
present so an empty array means a clean file — see
[docs/control-api.md](control-api.md#get-v1backlog).

## Detail files

An item's groomed body lives in its own file, linked from the line:

```
- [ ] portfolio-filters | Filter the list by status | verify: swift build | size:S | ready → [detail](backlog/portfolio-filters.md)
```

By convention that is `backlog/<id>.md` beside the backlog file — that is what
the app creates and links. The link is what the app follows; the file also
identifies itself by its own name, so a file whose frontmatter omits `id:` is
still read as belonging to `<id>`.

```markdown
---
id: portfolio-filters
title: Filter the list by status
size: S
verify:
  - name: build
    cmd: "cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination \"platform=macOS\" build-for-testing"
---

## What

Describe the outcome: what exists, or behaves differently, when this is done.

## How

Suggested approach — files to touch, patterns to follow, pitfalls to avoid.
Agents treat this as guidance, not a mandate.

## Validation

- [ ] First observable behaviour that proves it works
- [ ] Second criterion; each becomes a checklist item for the worker and reviewer

## Out of Scope

- Things a well-meaning agent might do but shouldn't
```

**Frontmatter is optional.** A file that is just `## What` / `## How` /
`## Validation` is a groomed item. Where it is present, these keys are read:
`id`, `title`, `status`, `epic`, `priority`, `size`, `owner`, `jira`, `repo`, and
a `verify:` block of `- name:` / `cmd:` / `expect:` entries. A `cmd:` written as
a double-quoted scalar has its escapes resolved (`\"`, `\\`, `\n`, `\t`); one
written unquoted is taken as-is.

The body sections the parser reads:

| Heading | Read as |
|---|---|
| `## What` | The outcome. Required by the Definition-of-Ready |
| `## How` or `## Approach` | Suggested approach. Required |
| `## Validation` or `## Acceptance Criteria` | The criteria list. Required |
| `## Out of Scope` | Bullets naming what not to do |
| `## Premise` | Bullets naming the measurable claims the item rests on; the worker checks each before it builds, and one it refutes with a measurement ends the run as an investigation |
| `## Why`, `## Context` | Free prose, carried for whoever reads the item |
| `## Notes` | Appended to by the app — see below |

Criteria and out-of-scope entries are read from **any `- ` bullet**, checkbox or
not: `- [ ] criterion`, `- [x] criterion` and `- criterion` all count. Headings
the table does not name are ignored, and a detail file is never rewritten
wholesale, so extra sections stay where you put them.

**`## Premise`** states the measurable claims the item rests on — what it
takes as given, one claim per `- ` bullet, written after `## What` and before
`## How` (a bare `- ` reads as no claim). The worker verifies each claim against the tree before changing
anything and reports each at the top of its handoff as `held`, `refuted:
<measurement>` or `unverifiable: <why>` (`PremiseReport` reads those lines
back). A refuted premise is a legitimate end to the run: the worker stops, states the measurement and what, if anything,
still qualifies, and the run ends as an **investigation** — the item goes to
the approval gate with the report in its Notes, the reviewer reads the report
beside the diff, and the quality judge scores the measurement rather than the
absent diff. It exists because an item once asserted four functions qualified
for a change when one did, and the run that measured first and refused the
other three was scored as a diff that added no tests. The three grooming
skeletons carry an optional `premise` variable for it.

`## Notes` is the one section the machinery writes. A note is appended as a dated
bullet — `- 2026-08-11 — …`, multi-line notes indented to stay inside the bullet
— inserted directly under the heading, so the newest note is first. The section
is created if the file has none. Advisory review findings, gate refusals and
status reconciliations all land here, which makes it the running history of what
happened to the item.

Two fields answer in two places, and the precedence differs:

- **`size`** — the backlog line wins; the detail's frontmatter `size:` is the
  fallback (`DefinitionOfReady.effectiveSize`).
- **`verify`** — the detail's frontmatter wins; the line's `verify:` is the
  fallback.

### Citing what exists, and what the item creates

A backticked path or symbol in a detail file is read as a claim that the repo
has it, and `GroundingCheck` refuses the item when nothing in the repo does.
The exception is a reference the item itself *creates* (or reports as *gone*):
say so with a creation cue — `add`, `create`, `write`, `new`, … — or an
absence cue — `missing`, `gone`, `removed`, … — in the same sentence, before or
after the backticked name. The binding rule for a cue after the name: it
belongs to the *next* backticked span in the sentence when there is one, and to
the name before it only when there is none; between two spans, the cue nearest
the second is that span's and any earlier cue stays with the first. So "the
policy file `quality.json`, which X creates" excuses `quality.json`; in
"`foo.json` is gone, so create `bar.json`", "create" introduces `bar.json` and
"gone" is left to `foo.json`, so both are excused; and in "`foo.json`, so
create `bar.json`" nothing excuses `foo.json`. A sentence ends at the first
`.`, `?` or `!` outside a backticked span, so a cue two sentences on excuses
nothing. A refusal names the reference, how it was read (a path or a symbol)
and the cue that would have excused it.

## Definition-of-Ready

The gate an item passes before autopilot will run it unattended
(`DefinitionOfReady.evaluate`). It is a pure function of the item, its detail
file, and the backlog it sits in, so the queue filter, the panel and the control
API all reach the same verdict.

An item needs no `verify:` of its own when the project's verify map
(`kiteloop-verify.json`) has a rule matching every path (`"glob": "**"`): the
merge gate runs that rule on every diff, so the item's `verify:` holds only the
checks particular to it. The autopilot's pickup is told whether the map has such
a rule; without one, an item with no command is refused as before.

| Clause | Unmet when | Reported as |
|---|---|---|
| `detail` | No detail file, and the line is not groomed inline | `no groomed detail file — write backlog/<id>.md with What/How/Validation` |
| `what` | The detail file has no `## What` | `detail file has no What section` |
| `how` | No `## How` (or `## Approach`) | `detail file has no How section` |
| `validation` | No `## Validation` criteria | `detail file has no Validation criteria` |
| `verify` | Neither the detail nor the line declares a command, and the project's verify map has no rule matching every path | `no verify: command — nothing objective for the run to pass` |
| `verifySeparator` | The line's `verify:` contains the field separator `" \| "` | names the unspaced-pipe fix |
| `titleSeparator` | The title contains the field separator `" \| "` | names the fix |
| `size` | No size on the line or in the detail frontmatter | `no size set — autopilot runs XS/S/M` |
| `sizeTooLarge` | Sized `L` or `XL` | `size L is too large for autopilot — break it down first` |
| `qaProfile` | Marked `flow:qa` in a project with no usable `kiteloop-qa.json` at its root | `flow:qa needs the project onboarded for QA — add kiteloop-qa.json at the root`, or why the file cannot be used |
| `dependency` | A `needs:` id is not `done`. One phrase per unmet id | `needs <id> — not done (<status>)`, `needs <id> — no such item`, or `needs <id> — dependency cycle: a → b → a` |

Three things about that list are easy to get wrong:

- **The explicit out-of-scope list is a grooming rule, not an enforced clause.**
  An empty out-of-scope is a legitimate statement ("nothing is off limits") and
  reads identically to an unwritten one, so blocking on it would refuse items
  that are genuinely ready.
- **Inline grooming is accepted.** A line whose *title* carries `WHAT: … HOW: …
  VALIDATE: …` counts as groomed with no detail file. Some projects work that
  way and the gate must not refuse them for putting the same content in the line.
- **`needs:` is only judged when there is a backlog to resolve it against.**
  Somewhere with no file to check — grading a proposed draft before it is filed —
  the clause is silent rather than failed. `done` is the only status that
  satisfies a dependency; an id naming nothing, and a cycle, both count as unmet
  and say which.

The gate withholds; it never reorders. An item whose turn has not come is skipped
with the dependency named, and the queue moves on.

`GET /v1/backlog` reports this per item as `ready` plus a `notReady` list of the
gate's own phrases — for `ready` items only, since pickup readiness means nothing
for a `done`, `blocked` or `draft` one. See
[docs/control-api.md](control-api.md#get-v1backlog).

## Protected paths

Retired. A project could once hold a list of repo-relative paths —
`protectedPaths` in `.kiteloop/autopilot-config.json` — that a run's diff was
stopped for changing unless its item named them with `touches:`. The list was
empty in every project and never refused a run, so it is no longer a setting:
a config file or a [`PUT /v1/autopilot`](control-api.md#put-v1autopilot) that
still names it is accepted and the key ignored. The repository's own guards —
the verify map, the diff rules, stray-work detection — are where path rules
live now.

`touches:` is still read and written on the backlog line, and the Planner still
may not file a draft carrying one `ready`: it lands as `draft` with the claim in
its Notes and the refusal recorded as `protected-path-claim`.

**The same gate runs the item's own `verify:`.** The app runs it in the tree the
run's work is sitting in, and a non-zero status — or a deadline reached before
the command answered — stops the run **before the reviewer sees it**, with
`cause=verify-failed` in the log. The verdict is kept: the command as it was
run, the directory, the exit status and the tail of the output go to the item's
Notes. It runs under the same deadline as the merge gate's own verify —
`autoMergeVerifyTimeoutMinutes`, this project's derived gate deadline, reported
by [`GET /v1/autopilot`](control-api.md#get-v1autopilot) — so one command is
never judged by two clocks. An item declaring no `verify:` has nothing to
measure and reaches the reviewer as it always did.

## The round-trip guarantee

Every in-app change — a status flip, an approval, a filed item — rewrites the
**whole file** through `BacklogSerializer`. What that guarantees, and what it does
not, is asserted in `Kiteloop/KiteloopCore/Tests/KiteloopCoreTests/Services/BacklogRoundTripTests.swift`.

**Guaranteed.** Everything the parser understood comes back: every status, size,
lane, `verify:` (flags, quotes and all), `needs:`, `from:`, blocked reason, done
metrics, Jira key, detail link, epic name and epic description. `serialize ∘
parse` is idempotent — the second write of an unchanged file is byte-identical to
the first, so a backlog rewritten on every status change does not churn in git.
Lines the parser refused come back too, unrepaired. So do frontmatter keys other
than `project`, `repo` and `verify_default` — kept as written, after the three
known keys, in the order they were read, and not reported as a parse issue.
Prose under an epic heading that sits after the epic's first item is kept too,
re-emitted after that epic's items rather than where it was written.

**Normalized on the first write-back.** These are not losses, but the file will
not come back looking exactly as you typed it:

- `## Now` becomes `## Epic: Now` (except `## Bugs`).
- Every item under an epic named `Now` gains `lane:now`, once — see
  [Lanes](#lanes). The items stay in that epic.
- The H1 is regenerated as `# <Project> Backlog` from `project` — but only when
  the file has no preamble to take one from. A preamble is written back as it
  came in, own H1 included.
- Fields are reordered into the serializer's fixed order.
- A bare Jira key is written back with its prefix: `PROJ-77` becomes
  `JIRA:PROJ-77`.
- A refused line is re-emitted after its epic's items rather than where it was.

**Not preserved.** Write these somewhere else:

- Item lines above the first `## ` heading — they belong to no epic, and are
  reported as a parse issue rather than kept. Everything else above the first
  heading is the preamble, and that *is* preserved — see above.
- Comments, blank-line placement, and any other structure between items.

External edits are picked up rather than overwritten: the watcher re-reads the
file when it changes on disk, so hand-edits, a script's append and an agent's
edit all reach the app and survive the next serialization. There is no locking —
the app writes the file it last read, so an edit made in an editor *during* an
in-app write can still be lost. In practice, edit the file or drive the app, not
both in the same second.

## See also

- [docs/control-api.md](control-api.md#get-v1backlog) — the same data over HTTP:
  items, readiness verdicts, parse issues.
- [docs/how-work-flows.md](how-work-flows.md) — who moves an item between
  statuses, and who is allowed to.
- [docs/autopilot-runbook.md](autopilot-runbook.md) — running a groomed backlog
  unattended.
- [CLAUDE.md](../CLAUDE.md) — the Definition-of-Ready and reviewer rubric as the
  agents are given them.
- `templates/release.md` — a backlog template: the same item-line grammar and
  detail-file layout with `{{variable}}` placeholders, read by the very same
  parsers (`BacklogTemplate`).
