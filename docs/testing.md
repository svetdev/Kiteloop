# Testing Kiteloop — what each check asserts, and why it exists

This is the long form of the *Testing* section in `CLAUDE.md`. That section holds
the rules; this file holds the history behind each one — what each preflight
check reads, the failure it was written to end, and how its own test asserts it.
`CLAUDE.md` is loaded into every agent's context and has a word ceiling
enforced by `quality/bin/check-doc-size.py`, so the narrative lives here.

Nothing here is enforced by being read: every claim below is asserted by a
script in `scripts/`, and `scripts/run-unit-suite.sh --dry-run` prints the order
they run in.

`--flakes` reads `docs/suite-status.md` in full and lists every test the record
has decided two different ways *at the same commit*, over rows the record calls
clean — red in one row, green in a later row, no code change in between to
credit. A row whose tree cell says dirty is no reading for this comparison: the
uncommitted content it measured is unknown and unrecoverable, so it is passed
over, exactly as a row stating no verdict already is. One line after the header
says how many rows were passed over and for which of the three reasons — a
dirty tree, no verdict to read, a red row naming no test — against how many
rows the record holds, so `none` cannot be read as "no test flipped" when what
happened is that no row was readable at all. It answers a
narrower question than the `earlier` and `flaky` lines `--last` prints below,
which apply the same dirty-row rule to their own comparisons: `earlier` never
counts or names a dirty row among the measurements it compares at one commit,
and `flaky` never lets a dirty row set the green reading a red row is said to
have passed since, nor the red reading a later green row is compared against.
The `flaky` line also reads only the newest twenty rows and names a test that
failed at one commit and passed at a later one, because it is answering "does
this still describe the tree?" and cannot tell a flake from a fix either way.
`--flakes` only ever claims the shape it can call a flake without guessing —
both verdicts at one clean commit — over the whole file rather than a
twenty-row window, so a test that flips once a week does not scroll out of
view before anyone reads it.

## The suite and its preflight

```bash
cd Kiteloop
# the standing check — compiles the app *and* the test bundles, runs nothing
xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build-for-testing
```

```bash
# the full unit suite — from the repo root here, but the script finds the root
# itself, so any path to it works from any directory
./scripts/run-unit-suite.sh
./scripts/run-unit-suite.sh --dry-run   # print the commands it would run, start nothing
./scripts/run-unit-suite.sh --last      # when the suite was last measured, and the drift since
./scripts/run-unit-suite.sh --flakes    # every test the whole record has decided both ways at one commit
```

A run that did not come back clean keeps its full output — not just the tally —
under `.kiteloop/suite-logs/` in the project root, the newest twenty kept; the
`--last` line above prints the `log` line naming that file for as long as it is
still there. A run ended by the idle ceiling also keeps a `sample` of every test
host, taken just before it was ended, beside that log as `<run>.samples.txt` —
the stack of the clone that stopped answering is what names a wedge.

An async test must not call `Process.waitUntilExit()` after an `await`: the body
may resume on another cooperative thread, where that call parks the thread's run
loop for a wakeup that never comes. It held a parallel clone until the idle
ceiling ended the run twice on 2026-09-22. Start and wait with no `await`
between, or poll `isRunning` with `Task.sleep`.

Use `build-for-testing`, not `build`: the shared scheme's BuildAction lists only
`Kiteloop.app`, so plain `build` never compiles `KiteloopTests` and a test file
that does not build stays invisible until someone runs the suite by hand.

Run the suite through `scripts/run-unit-suite.sh` rather than typing it: it
refuses, and starts nothing, while Kiteloop is running — the app hosts the tests,
see the rule at the end of this file — and refuses the same way when `pgrep`
could not answer at all, since an unread process list is not evidence the app is
down. Otherwise it runs its preflight in
order, which is what `--dry-run` prints:

```
scripts/test-check-target-membership.py
scripts/test-run-unit-suite.sh
scripts/test-kiteloop-verify.py
scripts/test-export-coverage-lcov.py
quality/tests/run.sh
quality/bin/gate.py --skip-missing-tools
scripts/core-package/test-core-check.py
scripts/core-package/test-core-inits.py
scripts/core-package/test-core-move.py
scripts/core-package/test-core-pick.py
scripts/core-package/test-pbx-register.py
scripts/core-package/test-test-move.py
scripts/test-run-core-tests.sh
scripts/run-core-tests.sh
scripts/test-make-release.sh
scripts/test-make-mobile-release.sh
scripts/test-verify-map-replay.sh
scripts/test-install-control-forwarder.sh
scripts/test-test-host-hook.sh
scripts/test-check-repo-map.py
scripts/test-control-forwarder.py
scripts/test-check-control-api-docs.py
scripts/test-check-companion-api-list.py
scripts/test-check-doc-links.py
xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" -only-testing:KiteloopTests -parallel-testing-enabled YES -enableCodeCoverage YES test
scripts/export-coverage-lcov.py --out .kiteloop/coverage/suite.lcov   # postflight, after a green row
quality/bin/check-crap.py --quiet   # postflight, after a green row
quality/bin/gate.py --postflight --gate changed-coverage   # postflight, after a green row
timeout: 1800s — xcodebuild is ended, and the row it would have written recorded as such, if it runs past this
idle:    600s — the same, if it prints nothing for this long: a host that has stopped mid-suite
power:   caffeinate -i -s holds an idle- and system-sleep assertion for as long as xcodebuild runs, so a Mac left alone does not sleep into that ceiling
```

The `-only-testing:KiteloopTests` above is belt-and-suspenders, not the reason
`KiteloopUITests` stays out of the run: the shared scheme's `TestAction` marks
the `KiteloopUITests` `TestableReference` `skipped = "YES"`, so a plain
`xcodebuild … test` with no `-only-testing:` flag now exercises `KiteloopTests`
alone and its exit status is that suite's verdict — `KiteloopUITests` cannot
enable automation mode headlessly and used to fail the whole run for a reason
that had nothing to do with the unit suite. The UI tests still build and are
still runnable by naming them: `xcodebuild -project Kiteloop.xcodeproj -scheme
Kiteloop -destination "platform=macOS" -only-testing:KiteloopUITests test`.

The first twenty-three are the preflight, run from the repo root before anything
is built. A failure in any of them exits with that command's own status, does not
start xcodebuild, and appends no row to `docs/suite-status.md`: nothing was
measured.

The target-membership check runs inside `quality/bin/gate.py`, as its
`target-membership` command; the first preflight entry is the script that
asserts it. `build-for-testing` cannot catch an
unregistered file: it compiles the *targets*, and a `.swift` file missing from
`project.pbxproj` is in no target, so there is nothing for the compiler to
complain about — a test file in that state does not fail, it goes silent, and the
suite stays green because it never ran. Unregistered test files have accumulated that way before.
It walks two projects, each judged against its own targets: the Kiteloop app
project's `Kiteloop/`, `KiteloopTests/` and `KiteloopUITests/` roots, and the
KiteloopMobile companion's `Sources/` and `Tests/` roots.
If the check fails it names the files. Run it on its own —
`./scripts/check-target-membership.py` — after adding a file from the command
line.

`scripts/test-check-target-membership.py` runs immediately ahead of it, for the
reason the tally reader is asserted ahead of the run that uses it. The check is
regex over `project.pbxproj` and its failure mode is silence: one pattern that
stops matching — a group block a newer Xcode lays out differently, an object id
of a length `UUID` no longer admits — and it goes on printing `OK: all N .swift
files … are compiled by their own target` while vouching for nothing, which is
the state it was written to end. So `parse` and `referenced_paths` are driven
over synthetic pbxproj text, one fixture per invariant: a file whose build file
sits in a Sources phase a `PBXNativeTarget` lists is compiled; one whose build
file appears in no phase is not; one in a Sources phase no native target lists is
not either — the orphaned-phase rule — and each target's set is kept apart from
the others', which is what the misfiled verdict is read from. Group paths compose
through nested groups while a path-less virtual group contributes no component, a
multi-segment path on the file reference resolves whole, object ids that are not
24 characters still parse, and two references naming one path count as compiled
when either of them is. Then the check itself is run end to end against
mutations of this repository's own project file, handed to it through
`--pbxproj`: a build file taken out of its Sources phase, a file reference
deleted, the app target renamed. Each is one of the three failures it exists to
name, and each case asserts it exits non-zero and names the file — a reader that
parses and a check that reports are different claims, and only the second stops a
run. It builds nothing, reads no process list and writes nothing outside a
temporary directory, so it is safe on its own or as part of the suite while
Kiteloop is running.

`scripts/test-run-unit-suite.sh` asserts the five readers inside
`run-unit-suite.sh` that turn xcodebuild's output into a suite record — the
tally, the result bundle that says the run happened, the names of the tests
that failed and of the ones that skipped, and how long the run took — along with
what `--last` prints for
the last four, and what `--flakes` prints over the whole record. Its cases run
synthetic xcodebuild logs through the production path. For the tally: both
frameworks counted rather than the last one to speak winning, an XCTest failure
behind a passing swift-testing summary reading failed, a skipped test not
counting as a failure but being named in the cell — `✔ 3058 tests passed (1
skipped) — …`, so a green row also says how much of the suite opted out, and no
parenthesis at all when nothing was skipped — skips alongside real failures
reporting only the failures,
a red cell saying how many tests failed as well as how many failures were
reported — `✘ 3056 tests, 1 failing test (2 failures) — …` for one test that
failed twice, and `2 failing tests (2 failures)` for two that failed once each —
counted off the reader that fills the names cell beside it, so the two cannot
say different things about one run, while a red run that named no test at all
keeps the bare failure count,
a failed summary naming no count still reading failed, a single framework passed
through verbatim, and no summary at all coming back empty. For the result bundle:
the session bundle a finished run opened, reduced to its last component; the
error bundle a run that died before testing started wrote instead, which is still
evidence a run happened; the later of two bundles named in one log; and no bundle
named coming back empty. For the failing names: every failure in the order the
run reported it, with XCTest's selector rewritten to the dotted spelling
`-only-testing:` takes; swift-testing's failures read too rather than only
XCTest's; swift-testing's run summary, which has the shape of a failing test, not
mistaken for one; a name XCTest repeats once per enclosing suite recorded once;
a red run that printed no per-case line at all read from xcodebuild's own
trailing `Failing tests:` block instead — a fallback and never a union, since
that block omits the `KiteloopTests.` prefix the per-case reader produces, so a
run printing both still records the per-case spelling and each name once; and a
green run recording a dash rather than an empty cell. For the skipped
names: the same reading, dedup and dotted spelling as the failing ones, a failing
test not mistaken for a skipped one, a run that skipped nothing recording a dash,
and the count in the tally agreeing with the names beside it — plus the row a
finished run writes, whose header must be the one `docs/suite-status.md` already
carries. For the duration: the seconds between two epoch stamps, a run inside one
second reading `0s` rather than an empty cell, a clock that stepped backwards
mid-run reading `0s` rather than a negative, a cell to the right of the skipped
names not being read as one of them, and — end to end, through the copy of the
script the guard cases drive — a finished run's own row carrying a whole number
of seconds, which a `duration_cell` nothing called would still have passed. The
`--last` cases
check that the bundle, failing-tests, skipped-tests and duration lines print what
the row
carries, sit in
row order with their labels aligned, and print no line at all — not a blank one,
and not the cell next door — when the cell is empty or the row predates the
column, the skipped line staying quiet for a dash as well, since a run that
skipped nothing has already said so by carrying no `(N skipped)` in its tally;
and, for the disagreement line, that a commit measured red then green
reports it and names the red row's tests, that green then red reports it too,
that a repeated name is said once, and that rows which agree, a lone row, a red
row at a *different* commit, and a row whose tally states no verdict all produce
no line; that a row whose tree cell says dirty is left out of both the count and
the names, the way `--flakes` leaves it out, that the same pair with the row
clean instead still reports and names it, and that a dirty row among several at
one commit is left out of the count as well as the names; and, for the flaky
line beside it — the one that reads across commits —
that a test red at one commit and green at the next is named where the
same-commit comparison is silent, that a test the newest row still has red is
not called green since, that a name red in several rows is said once, that a red
row one past the twenty-row window is not named while the same row inside it is,
and that a green record, a ceiling row and red rows only at the newest commit all
produce no line; that a dirty red row grants no flip, that a dirty green row
grants none either — the skip applies to the row that would set the green
reading, not only to the row naming a test — and that a dirty *newest* row does
not get to mark a test still red, so a clean row behind it still reports the
test as having passed since; and, for `--flakes` itself, that a test red then green *at the
same commit*, both rows clean, is listed with the flip counted and the commit
named, that the same red-then-green pair with either row's tree cell dirty is
not — the uncommitted content it measured is unknown and unrecoverable, so it is
no reading of that commit — that a test red at one commit and green only at a
later one — the shape `--flakes` leaves to a fix rather than calling a flake —
is not, that a test red in every row a commit was ever measured at is not
either, since there is no green row there to read it against, that a red row
naming no test contributes neither a red nor a guessed-at green reading, that a
row stating no verdict at all is passed over the same way the flaky line passes
it over, that the line above the ledger counts each of those skips under its own
reason against the whole record — a record every row of which is dirty saying it
read none of them, and still exiting 0 — that the line carries no leading space,
since two spaces would reach `FlakeLedgerReader` as a test name and four as its
flip line, and that an empty record answers cleanly instead of failing over
nothing to read; and, for the uncommitted line,
that a modified file under
`Kiteloop/` or `scripts/` is counted and an untracked one too, that the count is
files rather
than paths, that a modified `docs/suite-status.md` — the state every finished run
leaves behind — is not, and that a clean tree prints no line at all. The `tree`
cell a run records is asserted over that same scope, since it is the same
question: a modified or untracked file under either code path records `dirty`,
while an uncommitted backlog or docs edit — and the record file itself — records
`clean`, as does a clean tree. It sources
`run-unit-suite.sh`, which defines its functions and returns
when sourced, so it builds nothing, reads no process list and writes no record —
it is safe to run, on its own or as part of the suite, while Kiteloop is running.
Running it here means a broken reader stops the run before a build starts,
instead of quietly recording a wrong row for a run that did happen. It also
covers the guard itself — each of pgrep's three answers, and what a copy of the
script does with it in a throwaway repo whose preflight and `xcodebuild` are
stubs: a match and an unanswerable pgrep both refuse and start nothing, only a
clean "nothing matched" builds, and `--dry-run`, `--last` and `--flakes` all
answer without reading the process list at all. The preflight is read off the
same call list,
which each stub now names itself in: a run that gets through calls all five, in
`PREFLIGHT` order, ahead of `xcodebuild` — and one case per entry makes that stub
fail and asserts the run stops there, exits with that stub's own status rather
than a constant, names which check failed, and appends no row.

`scripts/test-kiteloop-verify.py` asserts the `--json` contract of
`scripts/kiteloop-verify.py`, the control harness: that stdout carries one JSON
document and nothing else, on each of the three paths that narrate (smoke,
`--run`, `--marathon`), with the narration on stderr — and that human mode still
prints what it always has, on stdout, with stderr empty. That contract is read by
machines, and it broke once by printing `Smoke checks (read-only):` ahead of the
object, which `jq` and `json.load` fail on at the first byte. Nothing here needs
a running Kiteloop: the paths are driven against port 1 with a stub token, so
every request refuses instantly, and the marathon lines that only appear once
items are moving go through the real function with a stub client. It starts no
build and reads no process list, so it is safe on its own or as part of the suite
while Kiteloop is running.

`scripts/test-export-coverage-lcov.py` drives `scripts/export-coverage-lcov.py`,
the postflight step that writes the one LCOV file the changed-coverage gate
reads (see "CRAP: complexity the tests do not pay for" below), over saved
inputs in a throwaway repository: an executable app line is a record with its
count and a non-executable one is not; the package's file that the app bundle
records at 0% is dropped in favour of the package's own export; llvm-cov's
generated test runner is dropped; a missing bundle, missing package coverage
and a config naming no roots are each refused naming what to pass. It runs no
xcrun and starts no build, so it is safe while Kiteloop is running.

cleat's own suites come next, twenty-six `test-*.py` under `quality/tests`:
one per gate, and one each for the shared loader (`test-quality-config.py`),
the ratchet engine (`test-ratchet.py`), the runner (`test-gate.py`), attach
(`test-attach.py`) and the per-language conformance fixtures
(`test-conformance.py`). Each runs ahead of the gate it asserts, for the
reason the tally reader is asserted ahead of the run that uses it: a gate that
has stopped judging what it claims to judge should stop the run rather than
report OK from inside it. Every one drives its script over a throwaway tree it
writes in a temporary directory, starts no build and reads no process list;
`test-mutate.py`'s few seconds of `swift test` run against a fixture package,
not this one. What each asserts is its own docstring's to say — they are
cleat's, refreshed with the template — and `quality/tests/run.sh` runs the
whole set in one command outside the suite.

Then `quality/bin/gate.py --skip-missing-tools`, cleat's runner: every gate
`quality.json` configures, in one process, exiting non-zero naming what
failed. The gates it runs here and what each refuses:

- **doc-size** — `CLAUDE.md` past its word ceiling. That file is loaded into
  every agent's context, and four thousand words of history once crowded out
  the rules; the way to add a rule without spending words is to encode it as a
  check.
- **doc-citations** — a backticked `.swift` path in `docs/features.md`, the
  capability-to-test map, that resolves under none of the app, package,
  companion and test roots. A row whose file has since been renamed or deleted
  still reads as coverage somebody checked; eleven did before the retired
  features-map check existed.
- **reachability** — a `Services/*` file under the app, the package or the
  companion that no other swept source names by a type it declares. A service
  can sit in the tree, compile, be unit-tested, and be constructed by nothing
  the app runs, and the suite tally then counts coverage of code no run can
  reach; nine were in that state when the pass was written. Declared names
  rather than the filename, since `Services/ItemDossier.swift` declares
  `ItemDisagreements`. It is a ratchet: `"exempt"` in the section names any
  service accepted on purpose, with its reason, and an exemption for a service
  that is reached again or gone fails. Today the list is empty.
- **test-hygiene**, **layering**, **guard-suites** — the same three ratchets
  this document describes below under their own names; the runner is how they
  are reached now.
- **complexity** — a production function over cyclomatic 8 or 60 lines beyond
  `quality/complexity-baseline.json`, described below.
- **escapes** — a new place where the code opts out of a check: a force try
  or force cast, a `swiftlint:disable`, a skipped test, a `|| true` in a
  script, a `# type: ignore` — ratcheted by site in
  `quality/escapes-baseline.json`, so the 59 that stand there are accepted
  once and a new one fails naming the line and what the
  escape hides.
- **duplication** — a copied block of ten or more significant lines in the
  lines changed against the base, judged without a baseline since there is
  nothing to accept in new work; and the duplicated share of the whole tree
  rising past `quality/duplication-baseline.json`.
- **conventions** — a new site breaking one of this repository's own rules,
  each a regex with the rule's sentence as the message at the site. One rule
  today: a blocking `Thread.sleep(` or `usleep(` in production Swift, with
  CLAUDE.md's "Orchestrator is @MainActor — never block it with synchronous
  I/O" as the message; the 8 sites that stood are in
  `quality/conventions-baseline.json`.

A machine missing a gate's tool (`lizard`, `swiftlint`, `ast-grep`, `xcrun`)
reports that gate as skipped rather than failing it, which is what the flag is
for; install `lizard` and `swiftlint` (`CONTRIBUTING.md`) and nothing is
skipped. CRAP is the one gate the runner does
not run in the preflight: it reads a coverage run, so it stays the postflight.
`quality/bin/check-features-map.py` is this repository's spelling of the
doc-citations and reachability pair — kept because the verify map's rule for a
`docs/features.md` change and older `verify:` lines call it, and not part of
cleat's template, so a refresh removes it and `git checkout --` restores it.

`quality/bin/check-layering.py` reads every source under each root in
`layering.roots`, strips comments and string literals, and reads each
capitalised identifier that names a type declared in another file as a
reference to that file's layer — the top-level directory under the root.
Three roots are judged: the app, `Kiteloop/Kiteloop/`, the local package,
`Kiteloop/KiteloopCore/Sources/KiteloopCore/`, and the iOS companion,
`KiteloopMobile/Sources/`, so a reference that crosses the layering cannot
leave the ratchet by moving from one into another. Layers
may depend downward only: Views and the app entry on anything, ViewModels on
Services and below, Services on Runtime and Models, Runtime on Models, Models
on Extensions — that table is shared by all three roots; `Testing/` is reachable
from anywhere, being a fact about the process rather than a layer. It is a
ratchet, per root: the references that crossed the layering when a root was
added — models that load themselves through stores, services that read the
backlog through its view model, a runtime that locates its own binary — are in
that root's `exempt` list with the reason each stands and what would remove
it, the success line prints one row per root with how many are exempt beside
how many were judged, and an entry whose reference is gone fails the check so
a root's list can only shrink by someone deleting the entry — an exemption
written for one root is never read against another's tree. A violation is
reported by file, line and type. It reads the tree and starts no build, so it
is safe while Kiteloop is running.

`quality/tests/test-check-layering.py` drives that reading through the real script
against throwaway trees standing in for both roots: a model referencing a
service fails and is named with its line, for either root's shape; the same
name in a comment or a string is not a reference; the downward and same-layer
directions pass and the success line counts what was judged; `Testing/` passes
from a model; a pair taken from a root's own exemption list is not reported
while a dead exemption is; an exemption written for one configured root is not
reported dead while the other is judged, and vice versa; a config missing the
`roots` key fails naming it; and the script run in place against this checkout
exits 0 with a success line per root. It starts no build and reads no process
list, so it is safe on its own or as part of the suite while Kiteloop is
running.

The complexity gate, `quality/bin/check-complexity.py` under the runner, is
the gate Robert C. Martin describes for agent-written code, in its simplest form:
cyclomatic complexity over 8 or a body over 60 lines fails, read by `lizard`
(`brew install lizard`) over the app target, the package, the iOS companion,
the Python tooling under `scripts/` and the bridge extension's TypeScript, so
a function keeps its gate when it moves between them. Agents write long
functions and do not notice, and a reviewer reading a diff cannot see that the
function was already long; a threshold a tool enforces is the one kind of rule
an agent cannot soften. It is a ratchet through `quality/bin/ratchet.py`: the
174 functions over the gate are in
`quality/complexity-baseline.json`, keyed by file and declaration so a shifted
line still matches, and a run reports only what is new or has grown worse. A
baseline entry that matches nothing — a function shortened, split, renamed or
deleted since it was accepted — is named as stale while the gate still passes,
and `--strict` fails it; the baseline records the tool and
config it was measured under, so a tool upgrade is noticed rather than read as
a change in the code. `quality/bin/check-complexity.sh` is this repository's
spelling of that gate, kept because the verify map's rule for every
`**/*.swift` change, the chat tool's default clean command and every ready
item's `verify:` line call it by that name; it runs the gate and exits with its
status, and after a refresh it is restored with `git checkout --`. `Kiteloop/.swiftlint.yml`
and `Kiteloop/.swiftlint-baseline.json` are no longer the gate's; they stay
because `scripts/core-package/core-move.py` reads them to judge a move.

`quality/bin/check-test-hygiene.py` is the ratchet behind the August 2026 cleanup
of the suite: each habit the tests were migrated away from — a fixed
`Task.sleep` where `eventually` belongs, a loopback-port probe or `isListening`
copied into a file instead of `ControlServerHarness`, a `URLSession` built by
hand for loopback, a temp directory built by hand instead of
`makeTemporaryDirectory`, a file-local `waitUntil` — is counted in the test
trees, outside `Support/` and in code only, against the ceiling it had when the
check was written. A count above its ceiling fails the preflight and names the
habit and the spelling to use; a count that falls is the new ceiling to write
down, and the success line prints them all so lowering one is a one-line
commit. `quality/tests/test-check-test-hygiene.py` drives it over throwaway trees —
clean passes with the counts printed, a probe over a zero ceiling fails and is
named, comments and `Support/` are not counted — and over this checkout.

`quality/bin/check-doc-size.py` keeps `CLAUDE.md` under a word ceiling. The file
is loaded into every agent's context and a rule in it competes with every
other sentence there; it was 6,734 words in August 2026 and is a third of
that now, with the history in this file and the Autonomy section cut to what
a reviewer cannot decide by machine. The way to add a rule is to encode it as
a check, which costs no words. `quality/tests/test-check-doc-size.py` drives the
ceiling over a throwaway file and this checkout.

`quality/tests/test-check-crap.py` runs here rather than only from
`quality/tests/run.sh`, which nothing standing calls — the CRAP gate itself,
`quality/bin/check-crap.py`, stays a postflight, run only after a green row
since it reads that row's coverage, but its own test needs no coverage to read:
it is stdlib Python driving the formula and both readers over files it writes in
a temporary directory, so it costs the preflight nothing to reach and a reader
that has stopped scoring correctly stops the run before a build starts rather
than silently misjudging the postflight after one. What it asserts is under
"CRAP: complexity the tests do not pay for" below.

`quality/tests/test-report-hotspots.py` runs here too, asserting
`quality/bin/report-hotspots.py`, the churn × complexity ranking that carries
no preflight entry of its own — it runs on demand, whoever asks for it, never
as a gate, so a break in its reader would say nothing until someone happened
to run it by hand. It drives the ranking over throwaway git repos with real
commits at real dates: a hot complex file's function tops the list, a cold
complex file's zero churn keeps it off despite matching complexity, and a hot
simple file's low complexity keeps it below despite matching churn.
Complexity is fed in from a fabricated SwiftLint report via `--lint`, exactly
as `test-check-crap.py`'s own test feeds one in, so it starts no real lint
run; then the same repo again under a fixture `quality.json` with only
`--config`, so the window and the lint roots come from the file rather than
flags. It builds nothing and writes only under a temporary directory.

`quality/tests/test-mutate.py` runs here too — see "Mutation testing" below for
what it drives `quality/bin/mutate.py` through. A mutation harness that stopped
actually flipping operators, or stopped judging a survivor correctly, would
otherwise report a clean run over mutants it never touched, and nothing would
say so until the next Monday's `--all` pass, or on demand from whoever happened
to run it by hand. It costs the preflight seconds: a throwaway fixture package
with one untested branch, a handful of mutants, `swift test` as the oracle. Only
its own test runs standing — `mutate.py --all` over the real package stays a
weekly and on-demand job, since a full pass takes hours.

`scripts/test-make-mobile-release.sh` runs `scripts/make-mobile-release.sh`
in a throwaway git repo against a stub `xcodebuild`: a dry run with no
credentials prints the archive and upload steps and runs nothing, a real run
missing the App Store Connect key or the team refuses before anything builds,
the team is read from `KiteloopMobile/Signing.local.xcconfig`, the build number
moves with HEAD, and a drifted `MARKETING_VERSION` is refused.

`scripts/test-make-release.sh` asserts the readers and the refusals in
`scripts/make-release.sh`: that the three `MARKETING_VERSION` sites resolving to
one version is what a release requires, and that a Debug/Release pair that
disagrees, or a `project.yml` that disagrees with the pbxproj, is refused with
the drifting values named; that the notes
cut from `CHANGELOG.md` are exactly the tagged section, stopping at the next
heading, with an `unreleased` heading called out; and that the signed path with a
missing credential, a tag that does not match the tree, or a missing section
exits non-zero *and starts no build* — a refusal that half-signs being the
failure those cases exist to prevent. None of that shows on the one path anyone
exercises by hand, the dry run, and until this became a preflight it ran only
when a release was being cut — the worst moment to learn that the drift check
has stopped reading the version. It sources `make-release.sh`, which returns when sourced,
and drives the end-to-end cases against a throwaway checkout whose `xcodebuild`
is a stub, so it builds nothing, signs nothing and talks to no notary service:
safe on its own or as part of the suite while Kiteloop is running.

`scripts/test-verify-map-replay.sh` drives `scripts/verify-map-replay.sh` — the
tool that replays a repo's `kiteloop-verify.json` against a real diff —
against fixture repos of its own: a real merge commit, an ordinary commit, a
file of paths, and stdin all reach a real verdict for both a covered diff and a
genuine gap; and every way to reach an empty changed-file list — an empty
file, blank lines, empty stdin, or a rev that touches nothing — is refused
with exit 2 rather than printed as `COVERED`, since `VerifyCoverage.evaluate`'s
`guard !paths.isEmpty else { return .covered }` is a documented fail-open that
an empty diff would otherwise turn into coverage nobody actually checked. It
ran nowhere a suite run could see it before this. It builds nothing and takes
about ten seconds: a handful of `git init`, `commit` and `merge` calls against
throwaway repos under a temp directory, then the real script run against them.

`scripts/test-install-control-forwarder.sh` runs `scripts/install-control-forwarder.sh`
end to end and asserts what it installs, uninstalls and leaves alone: that
`--install` copies `control-forwarder.py` into `~/.kiteloop/bin`, writes the
LaunchAgent plist and bootstraps it through `launchctl`; that `--uninstall`
boots it out and removes both files, and does so cleanly when nothing was
installed; and that `--dry-run` on either path touches neither file and calls
`launchctl` not at all. It ran nowhere a suite run could see it before this —
only when a contributor remembered to invoke it by hand — so a break in the
installer a phone reaches the control server through went unnoticed until the
next person tried to reach it. `HOME` is a throwaway temp directory for the
whole run and `launchctl` is a stub, first on `PATH`, that only records the
arguments it was called with: nothing here loads, unloads or asks the real
launchd about anything, so it is safe on its own or as part of the suite while
Kiteloop is running.

`scripts/check-test-host-hook.sh` reads the `PreToolUse` hook's `grep -E`
pattern out of `.claude/settings.json` — not a copy of it, which could agree
with itself while disagreeing with the hook that actually runs — and asserts
which xcodebuild actions it classifies as `deny`: `test` and
`test-without-building`, both of which launch the app-hosted test host, and not
`build-for-testing` or a plain `build`, neither of which does. It only judges
classification; whether the hook then actually denies is the pgrep guard's
business, and that is what the next check covers. It does judge one thing about
that guard, because the judgement is textual: the `pgrep -f` pattern read out of
the same hook must not match the hook's own command line, and must still match a
real Kiteloop's. `pgrep -f` matches whole command lines, and the command line the
harness runs the hook on *is* the hook, pattern included, so a pattern spelled as
a literal instance of what it searches for finds the shell asking the question.
It reads no process list, starts no build and spawns no `xcodebuild`, so it is
safe on its own or as part of the suite while Kiteloop is running.

`scripts/test-test-host-hook.sh` runs that same hook command end to end, with a
stub `pgrep` on `PATH` standing in for both of its answers, and asserts what the
hook actually does rather than what its pattern alone would suggest. `grep`
reads one line at a time, so a command laid out across backslash continuations —
`xcodebuild` on one line, `test` on the next, which is how anyone writes one
this long — used to put the two halves in front of separate matches and slip
past denial, while the identical command on one line was denied; this drives
both layouts, and a later line that merely starts with `test`, through the real
hook and asserts the real denial message names the app, what would happen, and
the way out. One case drops the stub: it runs the hook against the real `pgrep`
and holds the verdict against the process list read a way that cannot match the
reader — the pids whose *argv[0]* is the app binary, which a shell merely
carrying the path as an argument never is. The two must agree, so the one case
says both halves at once: with Kiteloop quit the hook lets a test run through,
with Kiteloop up it still refuses, and which is true while the check runs does
not matter. It reads the process list but starts no build and spawns no
`xcodebuild`, so it too is safe on its own or as part of the suite while
Kiteloop is running.

`scripts/check-repo-map.py` fails a file under `scripts/`, `quality/bin/` or
`quality/tests/` that this file, `docs/repo-map.md`, names nowhere.
`.gitignore` already states the rule out loud — a file "would have to earn a
row in `docs/repo-map.md` to be tracked" — and nothing enforced it before
this: the map drifted twice, most
recently leaving four files under `scripts/core-package/` silently unlisted
while the row beside them named the other eight. A row does not repeat a
file's whole path — it is spelled once and its neighbours in the same
directory are named bare — so the check reads every backticked span in the
file by its basename, the one spelling every row agrees on, and reports a
scanned file whose basename appears in none of them. It skips `__pycache__/`
the way `.gitignore` already does. It reads the tree and starts no build, so
it is safe while Kiteloop is running. `--quiet` prints only on failure.

`scripts/test-check-repo-map.py` runs immediately ahead of it, for the reason
the tally reader is asserted ahead of the run that uses it. It drives
`named_basenames`, `scanned_files` and `missing_files` directly: a full path in
backticks and a bare basename in backticks both read by their basename, several
spans on one line all read, text outside backticks not a span, an unclosed
backtick naming none, and a non-path span such as `` `--dry-run` `` read
harmlessly by its own basename since nothing here judges what a span means.
Over a throwaway tree it builds and tears down itself: a file with no row
fails and is named, files with a row do not appear in the report, and a
`__pycache__` file is never named, passing or failing. Then the check itself,
end to end through `--repo` and `--repo-map`: it fails while a file is
unlisted, `--quiet` still fails and still names the offender, and it passes,
quietly under `--quiet`, once every file has a row. Last, the real check
against this checkout. It starts no build, reads no process list and writes
nothing outside a temporary directory, so it is safe on its own or as part of
the suite while Kiteloop is running.

`scripts/check-doc-links.py` (run through cleat's runner, as the `doc-links`
command in `quality.json`) fails a relative Markdown link, anywhere in the
tracked Markdown of the checkout, that resolves to nothing. Two shipped that
way: `docs/suite-status.md` linked a dated triage note and `docs/autonomy.md` a
dated memory-audit note, both among the internal records the 2026-08-17
pre-publish audit removed, and both 404'd for anyone reading the repository on
GitHub. Nothing caught it — the doc-citations gate resolves paths, but only the
ones cited in `docs/features.md`, and `check-repo-map.py` reads backticked
spans by basename, which a link's target is not. The sweep is what
`git ls-files` lists, so `dist/`, `.build/` and everything else `.gitignore`
prunes stay out by construction rather than by a hand-kept list. What it refuses is one thing
and nothing else: a `[text](target)` whose target is relative and names no file
when resolved against the linking file's own directory, reported with the file,
the line, the link text and the target. A `#fragment` is cut off first —
whether a heading anchor exists is a different question from whether the
document does — and a bare `#anchor`, an `http`/`https` target and a `mailto:`
one are never resolved against the filesystem at all, since an external link
would need a network call, which has no place in a preflight. Code is masked
before any link is read, which is what makes an exemption list unnecessary:
`docs/backlog-format.md` and `Kiteloop/GETTING_STARTED.md` both illustrate the
shape of a detail link, `[detail](backlog/<id>.md)`, inside a fence or a code
span, and an illustration of a link is not a link. It reads the tree and starts
no build, so it is safe while Kiteloop is running. `--quiet` prints only on
failure.

`scripts/test-check-doc-links.py` runs in the preflight, before cleat's runner reaches the check, the same way.
It drives `masked` — a fence and an inline code span each blanked to spaces of
the same length, so an offset into the result still indexes the original, which
is where the link's text is read back from — then `links_in`, `resolve` and
`is_filesystem_target` over synthetic Markdown, one fixture per shape: a title
after the target, an angle-bracketed target, a `../` climb, a leading `/` read
as repo-root-relative rather than as the machine's filesystem root, and each
kind of target that must never be resolved. Then the check itself, end to end
through `--repo` over a throwaway checkout carrying a good link, a dangling
one, an anchor, an `http` link, a `mailto:` link, and dangling links inside a
fence and inside a code span: it fails naming only the real one, `--quiet`
still fails and still names it, an untracked file is not swept and the same
file once tracked is, and saying the thing in the sentence instead of linking a
document that is gone closes the failure. Last, the real check against this
checkout. It starts no build, reads no process list and writes nothing outside
a temporary directory, so it is safe on its own or as part of the suite while
Kiteloop is running.

`quality/bin/check-guard-suites.py` fails a guard suite — a `test-*.py` or
`test-*.sh` under `quality/tests`, `scripts` or `scripts/core-package` — that
is named by no entry in `PREFLIGHT`. This is the third time the same class of
bug shipped: a suite sits on disk, asserts something real, and runs nowhere a
standing measurement reads it. Nine were in that state when this was
written — `quality/tests/test-check-complexity.py`,
`quality/tests/test-report-hotspots.py`, and the seven `test-*.py` under
`scripts/core-package/` — seeded into `"exempt"` in `quality.json` naming the
two backlog items that tracked wiring each group in. All are wired into
`PREFLIGHT` now (the `quality/tests` pair through `quality/tests/run.sh`, six
of the seven under `scripts/core-package/` by name) and `"exempt"` is empty;
the seventh, `scripts/core-package/test-move.py`, is the tool that `git mv`s
an app-hosted test into the package rather than a test, and stands in
`"not_suites"` saying so. The check reads
`PREFLIGHT` out of `scripts/run-unit-suite.sh` as text rather than importing
or running it, takes the leading path off each quoted entry, and compares
that set against every guard suite found directly under each swept root — not
recursively, which is why `scripts/core-package/` is its own root rather than
left to a recursive walk of `scripts/` that would double-count it. An
`"exempt"` entry naming a path no swept root has fails the same way a stale
`"exempt"` entry does in `check-reachability.py`: the tree moved
past it, and left alone it would go on exempting whatever suite is later
added at that path. It reads the tree and one script's text and starts no
build, so it is safe while Kiteloop is running. `--quiet` prints only on
failure.

`quality/tests/test-check-guard-suites.py` runs immediately ahead of it, for
the reason the tally reader is asserted ahead of the run that uses it. It
drives the real check over a throwaway checkout: a suite named by no
`PREFLIGHT` entry fails and is named, one that is listed or exempt does not,
an `"exempt"` entry naming nothing under any swept root fails and is not
confused with a still-valid one, an entry's flags after its path do not stop
its path from matching, and a run-unit-suite.sh stand-in with no `PREFLIGHT`
array — or an empty one — exits 2 rather than passing on nothing read. Last,
the real check against this checkout, quiet and not. It starts no build,
reads no process list and writes nothing outside a temporary directory, so it
is safe on its own or as part of the suite while Kiteloop is running.

The twenty-fourth runs from `Kiteloop/`, printing the passed/failed tally and exiting
with xcodebuild's status — except when xcodebuild exits 0 having reported no
tally at all, which the script exits non-zero on its own account: a run that
matched no tests measured nothing, and handing that back as success is the
"green because it never ran" reading this preflight exists to prevent. The
recorded `exit` cell still carries what xcodebuild itself returned, so the row
stays an instrument reading rather than the script's verdict. Those
twenty-three spellings are the only ones in the repository.

Every finished run appends a line to **`docs/suite-status.md`** — timestamp,
commit, whether anything under `Kiteloop/` or `scripts/` was uncommitted, the
tally, xcodebuild's exit status, the
result bundle it wrote, the names of the tests that failed and of the ones
that skipped, and how long the run took — red runs
included, so the newest line is the last measurement rather than the last good
one, a red one says what is red without a re-run, a green one says which
coverage was absent rather than only how much, and whether the suite is getting
slower is read off the rows rather than remembered. `--last` prints it along with
`git rev-list --count` from the recorded commit to `HEAD`, which is how far the
tree has moved since anything actually executed a test — and, when more than one
row sits at that commit and they reached opposite verdicts, a line saying so and
naming what the red one recorded, so a suite that is green on the second try
does not read as simply green. A test can also fail at one commit and pass at
the next, which that comparison cannot see at all, so the readout names the tests
the newest twenty rows record red at an earlier commit and ✔ in a later row —
`docs/suite-status.md` holds exactly that pair twice, and both cost somebody a
chase. Both lines apply the dirty-row rule `--flakes` applies above: a row whose
tree cell says dirty is no reading of the commit it names, so it is left out of
the disagreement line's count and names, and out of the flaky line's — it
neither sets the green reading a red row is said to have passed since, nor the
red reading a later green row is read against. It reports what was recorded and
no more: whether a name there is a flake
or a test somebody fixed is not decidable from the rows. Commits are not the only
way a tree moves, so it also names how many files are uncommitted under
`Kiteloop/` or `scripts/` — an
edit nobody has committed moves neither count, and a modified source file used to
read exactly like a tree nobody had touched. That count is scoped to those paths,
which is what keeps the row a finished run appends out of it; a clean tree prints
no such line. There is no CI here, so
that file is the only standing answer to "is the suite green, and at what
commit?"; `--last` reads it, the git graph and the working tree and starts
nothing, so it works while Kiteloop is up.

**The script is the only writer.** A row is a measurement, so hand-editing that
file is fabricating one — it has happened, and `--last` duly reported a
full-suite pass that nobody had run. The result bundle cell is why a row can now be checked rather than trusted:
it names the `.xcresult` bundle xcodebuild opened, timestamped by xcodebuild
itself and present on disk only because a build ran, so a typed row names a
bundle that
`find ~/Library/Developer/Xcode/DerivedData -name '<the cell>'` cannot find. A
diff touching this file from an unrelated item is a blocking review finding.


## The parallel shape

The shared scheme (`Kiteloop.xcodeproj/xcshareddata/xcschemes/Kiteloop.xcscheme`,
mirrored in `project.yml`) marks `KiteloopTests` parallelizable and the script
passes `-parallel-testing-enabled YES`, so xcodebuild spreads the suite over
clones of the host app — eleven of them on an eighteen-core machine — and the
run that took 657 s on one core takes 93 s, preflight and build included. Under
XCTest the app sets itself to an accessory process and `NotificationService`
stops short of the system, so the clones take no Dock tile, badge nothing and
post no banners; before that a parallel run filled the Dock with badged
Kiteloops.

Parallel xcodebuild prints a different shape: no `Test Suite` opens or closes,
no `Executed N tests`, no `Test run with` from swift-testing — one line per
case, `Test case 'FooTests.testBar()' passed on 'My Mac - Kiteloop (86621)'`,
with swift-testing cases spelled `Suite/name()`, and a `** TEST SUCCEEDED **` or
`** TEST FAILED **` marker at the end. The first parallel run was recorded as
`no tally — xcodebuild exited before running tests` over 4,931 passed lines.
That output is also not line-atomic: eleven clones write to one pipe, and the
second parallel run's log held 4,929 lines saying `passed on` of which 4,904
began with `Test case` — the other 25 were tails cut mid-name by another clone
— so a reader counting lines recorded `✔ 4904 tests passed` over a run of
4,931. So when the serial summaries are absent the readers in
`run-unit-suite.sh` go to the result bundle first — the `.xcresult` the row
already names, which xcodebuild writes from its own record of every case —
through `xcrun xcresulttool get test-results tests`, parsed with python3 (what
every preflight check already runs under). The tally, the failing names and the
skipped names all come from it; an XCTest case is spelled
`KiteloopTests.Class.method`, a swift-testing one `Suite/name()`, told apart by
whether the bundle's identifier URL keeps the `()`. Only when the bundle cannot
be read — never written, an older xcresulttool, no python3 — are the parallel
case lines counted from the log, and then a `** TEST FAILED **` marker over
lines in which no failure was read still records one failure, so a run that
lost the line naming its failure does not round down to green. Case lines with
no close marker record no tally, the way an unclosed run suite does, and
nothing in this shape announces a case before it finishes, so the hung cell
records a dash for a parallel run. `scripts/test-run-unit-suite.sh` drives each
of those through the production readers — the bundle reader over a listing it
writes, the preference over the log through an `xcrun` shim standing in for
xcresulttool over a garbled log — and asserts the flag is on the command the
build stub was actually handed.

A test that runs in parallel owns its temp directory and its loopback port and
writes nothing under `~/.kiteloop`; `KiteloopTestSupport` — a library target
of the package both test targets link, re-exported into each by one
`@_exported import` in its `Support/` — holds the one spelling of each.

Its log lines are part of "writes nothing under `~/.kiteloop`", and they were
the hard half: `KiteloopFileLogger.shared` is the singleton every service logs
through, and until a project is opened it writes under the Kiteloop home — so a
test process, which opens none, appended every line a fixture provoked to the
day's real log, over a hundred thousand of them a day. The destination is now
`KITELOOP_LOG_BASE_DIRECTORY` when that names somewhere, the Kiteloop home
otherwise, and a test process sets it before the first line is logged, which is
before any test runs: `Tests/KiteloopTestLogRedirect` is a C target — C for the
one thing Swift has no spelling of, a load-time constructor — that points the
process at a fixed directory under `TMPDIR`, and `KiteloopTestSupport` depends
on it, so linking the shared helpers is what installs it. `swift test` on its
own is covered, not only `scripts/run-core-tests.sh`, which names a scratch
directory it deletes on exit. A test that knowingly provokes log lines calls
`redirectSharedLoggerToTemporaryDirectory()` on top of that, so its lines go
away with it; `SharedLoggerDestinationTests` is the guard on the constructor
still running, a failure otherwise invisible until somebody's log filled up
again.

## The host-less core

`Kiteloop/KiteloopCore` is a local Swift package the app depends on. What it
holds is code the app runs that needs no app to run it, and what it gives back
is a test target with no host: `cd Kiteloop/KiteloopCore && swift test` runs
`KiteloopCoreTests` in a plain `xctest` process, so it is safe while Kiteloop
is up — the hook does not deny it, since it launches no Kiteloop — and an
autopilot item's `verify:` can run real tests rather than only a build. The
suite runs those tests too, as preflight step fourteen (`scripts/run-core-tests.sh`,
asserted by `scripts/test-run-core-tests.sh` with a stub `swift`): a red package
stops the run with swift's own status before any build, like every other
preflight. The row the suite appends records the app-hosted suite's tally in
one cell — xcodebuild builds a package test target only from a scheme Xcode
itself wrote, and a hand-written testable for one is ignored, so that cell
never counts the package — and the package's own tally in the row's last
cell, read from the `OK: KiteloopCore — …` line that preflight entry prints
for itself.

A file moves in when every type it references is already in — the dependency
graph decides, not the directory. The app sees the package's declarations
through `package` access: every target carries `SWIFT_PACKAGE_NAME =
kiteloopcore`, the identity SPM passes as `-package-name`, and a moved type's
declarations the app uses are marked `package` (its `init` included, since a
`package` struct's memberwise init is still internal). The package holds 140
files — the line buffer, the loggers and watchers, the SQLite wrapper, the
HTTP server and router, the knowledge index, the hook, skill, scope and card
models, the backlog item and message models, the atomic writer and the
subprocess seam — and about 2,150 tests (2,115 XCTest and 41 swift-testing,
as `scripts/run-core-tests.sh` tallies them), many written to kill mutation
survivors. The mover is mechanical (`git mv`, `package` on every
declaration at type scope, a synthesised `package` memberwise init wherever
the app constructs a type, `import KiteloopCore` wherever a moved type or
function is named); what it cannot decide is which tests belong with the
code and which with the app — a test of the note against the app's routing
table stays app-hosted even when its subject moved — but `core-check.py`,
run at the end of every move, names each such test with the identifier and
line, so the decision is made before the build rather than after it. The test that
comes back, or the app-hosted half of a split one, is put back in the pbxproj
by `pbx-register.py` — the mover's counterpart, so neither direction is a hand
edit of the project file. The other direction has a tool too: `test-move.py`
lists the app-hosted test files that reference nothing app-side — no app type,
no helper only the app's `KiteloopTests/Support` has — and moves the ones named, which is
how a package function the CRAP gate read as untested gets the tests it always
had: they were hosted by the app for no reason. Thirteen files, 254 tests,
moved that way after slice nine. The next candidates are
whatever the hubs unlocked (`scripts/` has no picker yet; the graph script that
chose each slice is the kind of tool worth keeping); the three references
holding the rest out of the package are `Orchestrator` → `NotificationService`,
`ChatViewModel` and `ToolCallView`. The three test helpers and the scripted
subprocess runner live once, in the package's `KiteloopTestSupport` target;
`Kiteloop/KiteloopTests/Support/TestSupport.swift` re-exports them for the
app-hosted target.

## The template: `quality/`

`quality/` is cleat, vendored — the gates, their suites and their engine as a
template a project carries with it. `python3 ../cleat/quality/bin/attach.py
--into . --refresh`, from a cleat checkout beside this one, replaces the
template's files (`bin/`, `tests/`, `README.md`, `STRATEGY.md`,
`quality.example.json`) and keeps everything else, so what is this
repository's lives outside the template: `quality.json` at the root and the
baselines it names. The two shims `bin/check-complexity.sh` and
`bin/check-features-map.py`, which keep the retired names answering, are the
exception: they sit inside `bin/`, which a refresh replaces wholesale, so
after every refresh put them back with `git checkout --` on both paths — the
verify map fails loudly rather than silently while they are missing, and the
refresh is a person's commit to begin with. Every fact
about this project is in `quality.json` — source roots, the layer order and
its exemptions, the hygiene ceilings, the baselines' paths, the coverage
readers — and nothing under `bin/` names Kiteloop except those two shims. A
check finds the file walking up from the working directory, or is handed one
with `--config`, which is how its test drives it over a throwaway tree; a key
the file lacks fails naming the key, never a default. `core-move.py` edits the
file too — a layering exemption whose reference it moved into the package is
dropped there. `quality/README.md` is cleat's adoption guide, key by key.

## CRAP: complexity the tests do not pay for

`quality/bin/check-crap.py` is the other half of the complexity gate. For every
function SwiftLint reports with more than one path, it takes the coverage the
last run measured — the app target's from the `.xcresult` through `xcrun
xccov`, the package's from the llvm-cov export `swift test
--enable-code-coverage` writes — and scores `cc² × (1 − coverage)³ + cc`: a
fully covered function scores its complexity, an uncovered one about its
square. Over 8 is a finding. Functions are matched by file and declaration
line, walking up through attribute lines where xccov records the function on
its `@MainActor` and SwiftLint on its `func`, and down through a signature
that spans lines to the brace that opens the body — the first `{` after the
parameter list's parentheses balance, since a default argument may be a
closure with a brace of its own; a function with no coverage record at all is
uncovered. Two readings that are not the function are set aside: llvm-cov's
record for each default argument (the body's mangled name plus `fA<n>_`, keyed
at the argument's line and never run by a test that passes every argument),
and the app bundle's records of package files, which sit under a root that
merely begins with the app root's spelling. It is a ratchet like the others —
`Kiteloop/.crap-baseline.json` holds what was over the gate when it was
written, keyed by file and declaration text so a shifted line still matches
(`core-move.py` rekeys the entries of a file it moves, path and the `package`
the declaration gains) —
and it runs as a postflight: `run-unit-suite.sh` runs it after a green row,
since it reads that row's coverage, and a red gate makes the script's exit
red while the row stands. Without a bundle named, the app-side reader takes
the newest `.xcresult` matching `crap.xccov.bundles` — a glob that, on a
machine with several autopilot worktrees, matches one DerivedData directory
per checkout — so `run-unit-suite.sh` hands it this run's own bundle with
`--bundle`, read out of this run's own log by `bundle_path_from_log`, rather
than leaving it to guess among them; the OK line and a FAIL both name the
bundle and the package export the verdict came from, under `--quiet` too.
A package function's coverage is what `swift test` measured and nothing else.
The app-hosted run links the package and exercises much of it, and xcodebuild
can be asked to list `KiteloopCore` among the scheme's coverage targets — but
whether the bundle then carries the package came and went between runs with
what that invocation happened to rebuild, and a gate cannot stand on a reading
that changes with the build cache. So a function that moves into the package
with its only tests still app-hosted reads as uncovered there, which is the
fact: its tests have not moved with it. Nine such functions were baselined when
slice seven landed; `test-move.py`, the split of the tests that reached the
app, and new package tests for the rest released all but one — the plugin
scan of `SkillRegistry.defaultScanPaths`, which reads this machine's
`~/.claude` and is asserted by shape rather than walked.
`quality/tests/test-check-crap.py` drives the formula at
its corners, both readers over files it writes, the join (one line off through
an attribute, and never into the neighbour below), the baseline both ways,
`--write-baseline`, and `--bundle` — a glob matching a newer bundle than the
one named is never consulted, and the bundle and package export are named in
both an OK line and a FAIL, quiet or not.

### Changed lines the suite did not run

CRAP answers whether the tree's complexity is paid for; the question against
an agent is narrower — did it test what it just wrote — and cleat's
changed-coverage gate asks exactly that, but reads LCOV or Cobertura, which
this suite never wrote. So after a green row, ahead of the CRAP gate,
`scripts/export-coverage-lcov.py` writes `.kiteloop/coverage/suite.lcov` from
the same two sources CRAP reads: `xcrun xccov view --archive --json` over
this run's bundle, the per-line view, kept to files under the app root
(xccov records the package's files in the app's bundle at 0%, so those are
dropped); and `xcrun llvm-cov export -format=lcov` over the package's test
binary and the `.profdata` that `scripts/run-core-tests.sh` refreshed in the
preflight, kept to files under the package's source root, which drops the
generated runner. The roots are `crap.xccov.sources` and
`crap.llvm_cov.sources` in `quality.json`, so the two gates read the same
files. Then `quality/bin/gate.py --postflight --gate changed-coverage`: the
lines this checkout changed against its base — the merge-base with `main`,
or `HEAD` on `main` itself — that the report calls executable and the suite
did not execute, judged only when twenty or more changed lines are
executable, failing under the `minimum` share `changed_coverage` in
`quality.json` sets, and naming the uncovered lines by file and range. No
baseline: the scope is the change itself. The file lives under `.kiteloop/`,
which is gitignored and outside every path the record's `dirty` reading
looks at, so a run that wrote it does not make the next one read as dirty.

## Mutation testing

`quality/bin/mutate.py` is the hardener: it flips one operator at a time in
a file under `KiteloopCore/Sources` — `==`/`!=`, `<`/`<=`, `>`/`>=`, `&&`/`||`,
`true`/`false`, a dropped `!` — runs `swift test`, and expects red. A mutant the
suite lets through is a path no test pins down, named by file, line and flip.
Binary operators count only where written as operators, with a space on each
side, so a generic's `<` and `->` are never touched; comments and strings are
masked first. Each mutant goes into the real file and the original is written
back whatever happens, including an interrupt; the tree must be clean for the
files mutated, and a suite that is already red is refused, since it would kill
every mutant for the wrong reason. A mutant that does not compile is neither a
kill nor a survivor. Each mutant is judged narrowly first — the test classes in files named after
the source run alone through `swift test --filter` — and only one those let
through goes to the whole suite, so a kill reads `killed (narrow)` or `killed
(full)` and a survivor is always the whole suite's verdict. That is what keeps
a run over the package to minutes: at 514 tests a full run per mutant cost
forty seconds, and the package's 378 mutants took five hours before narrowing.
It is scoped to the package because the package builds and tests in seconds,
which is exactly why this was impractical on the app-hosted suite and is not
now. `mutate.py --all` over the real package is not a preflight step: run it on
the file you just wrote, or over `--all` when reviewing, and write the test
that kills each survivor. Its score is a number to read, not a gate; a full
pass took five hours before narrowing and still does not belong in the
preflight every suite run pays for.
The workflow also runs
`quality/tests/test-mutate.py` as its own step, ahead of the Mutate step and
failing the job if it fails, since a broken mutation harness would otherwise
report a clean run over mutants it never actually flipped — the same reason
`run-unit-suite.sh` now runs that test in its own preflight too, in a few
seconds against a throwaway fixture package rather than the real one, so a
broken harness stops a suite run before a build starts instead of surfacing
only once a Monday `--all` pass silently stopped meaning anything.
`quality/tests/test-mutate.py` drives it over a
fixture package with one untested branch: the mutants are what the table says,
nothing lands in prose, the untested branch's mutants survive and the tested
one's is killed, the file comes back byte for byte, a red suite is refused.

## The seams

Two places the app touches the world now have one door each, and a test can
stand in that door.

**Subprocesses.** Every `Process()` the app runs to completion goes through
`SubprocessOutput` (`Services/SubprocessOutput.swift`), which goes through
`SubprocessRunning`: `LiveSubprocessRunner` holds the bodies that spawn —
drain-before-wait, null-device stdin, kill-with-descendants past a deadline —
and `SubprocessOutput.runner` is where a test installs
`ScriptedSubprocessRunner` (`KiteloopTestSupport`), which records every call
and answers from a script. `withScriptedSubprocesses(runner) { … }` installs it
for the closure and puts the live runner back. Before the seam, twelve sites
built their own `Process()`; `runDiff`, `PullRequestPublisher.run`,
`RepoCloneService.runGit`, `ChatView.runGitBranch`, `unregisterFromLaunchServices`,
`isGitRepository` and `runShellNodeCommand` now route through it — three of them
carried their own copy of the deadline-and-kill logic — and the long-lived or
stdin-fed children (the agent CLI, hooks, the status line) keep their own. A
test that needs a git to refuse, a push to time out or a tool to be missing
scripts it in microseconds, with no child and no clock; the tests that exist
to prove the spawning itself (`SubprocessOutputTests`, `ProcessTreeTests`)
still spawn.

**The control server.** `KiteloopControlServer.handle(_:)` answers an
`HTTPServer.Request` exactly as the socket would — `start(port:)` hands every
request off the wire to the same function — so a test of an endpoint's
behaviour needs no port, no probe and no retry. `ControlServerHarness` remains
the way to take the whole loopback path, and
`KiteloopControlServerInProcessTests` holds the two paths to one answer.

## The test-host hook

`KiteloopTests` is hosted by
`Kiteloop.app` (`TEST_HOST`, bundle id `ai.kasatkin.kiteloop`), so
`xcodebuild … test` launches a second Kiteloop as the XCTest host and macOS
terminates the running instance — including the app running the autopilot, which
kills the run mid-item and strands it as `active`. This is not hypothetical: it has taken the app down mid-run and lost
in-flight items. Verify with
`xcodebuild … build-for-testing`, which compiles the test bundles and launches
no host, so it stays safe while Kiteloop is running; the harness runs the item's
`verify:` for you. A `PreToolUse` hook in `.claude/settings.json` denies the
command while the app is running — its pattern matches the two actions that run
the tests, `test` and `test-without-building`, and not `build-for-testing` or a
plain `build`, which launch no host. `test-without-building` was allowed until
recently, and it is the natural next command after the `build-for-testing`
recommended just above, so the hole sat directly in the path this paragraph
points down; `./scripts/check-test-host-hook.sh` now reads that pattern out of
`.claude/settings.json` — rather than keeping a copy that could drift from it —
and runs a table of commands through it, so the next such hole fails a check
instead of being discovered by an app that goes down mid-run. The pattern being
right is not the same as the hook denying, though: `grep` reads one line at a
time, so a command laid out across backslash continuations — `xcodebuild` on one
line, `test` on the next, which is how anyone writes one this long — put the two
halves in front of separate matches and was allowed, while the same command on
one line was denied. The hook now joins continuations the way the shell does
before it matches (only those, not every newline: a later line that merely starts
with `test` is a different command and must still run), and
`./scripts/test-test-host-hook.sh` drives the hook command itself — read out of
`.claude/settings.json`, with a stub `pgrep` for both answers — over each of those
layouts. It starts no build, and the one case that reads the real process list
only reads it, so it is safe while Kiteloop is running. The hook is still
a backstop; don't reach for the test suite in the first place. To run the full
suite by hand, quit
Kiteloop first and use `./scripts/run-unit-suite.sh`, which tests the same pgrep
pattern as the hook and refuses — without starting xcodebuild — if you forget.

Both probes pass `pgrep -a`. BSD pgrep leaves its own ancestors out of a match
unless told to include them, and the one shell these guards exist for — a
worker the app spawned, inside an autopilot run — descends from Kiteloop. Without
`-a` that shell asks whether Kiteloop is running and hears "no": on 2026-09-07 a
worker ran `./scripts/run-unit-suite.sh` from its worktree, the guard read an
empty process list, and the suite launched a second Kiteloop as its host while
the first kept running the fleet. Both test harnesses read the flag off the stub
`pgrep`'s recorded arguments, so the case the guard is for is the one it asserts.

`-a` is also what made the probe's own spelling matter. `pgrep -f` matches a
whole command line, and with ancestors back in the match the probe's own shell is
one of the command lines it reads — and the command line the harness runs the
hook on *is* the hook, pattern and all. Spelled
`Kiteloop.app/Contents/MacOS/Kiteloop`, the pattern was a literal instance of what
it searched for, so it matched the shell asking the question: measured on
2026-09-09 with the app quit, `sh -c 'pgrep -a -f "…"'` printed two pids and
exited 0, and the hook refused every test run through xcodebuild with nothing
running to protect. Both probes now bracket the first dot —
`Kiteloop[.]app/Contents/MacOS/Kiteloop` — which matches the same command lines
and is no longer one of them. `./scripts/check-test-host-hook.sh` asserts both
halves of that against the pattern text, and
`./scripts/test-test-host-hook.sh` asserts it end to end against the real
`pgrep`. `scripts/run-unit-suite.sh` keeps its pattern in a variable rather than
on a command line, so it was never the one that self-matched; it is spelled the
same way because the two guards are meant to mean the same thing by "running".

Two more hooks sit beside it in `.claude/settings.json`, both cleat's, written
by its attach and kept as written. The **Stop hook**, `python3
quality/bin/gate.py --hook --changed`, runs when an agent session stops: the
gates that scope to a diff (complexity, escapes, conventions, duplication)
over the files changed against the base, the rest over the tree, and a
failure is handed back to the agent as its next task with the file, the line
and what fixes it — while the context that produced the code is still
loaded. It blocks one stop, not every stop: on `stop_hook_active` the runner
reports and lets the agent stop, so a red gate cannot loop a session. The
**PreToolUse guard**, `python3 quality/bin/gate.py --guard` on `Bash`,
`Edit`, `Write` and `MultiEdit`, refuses the edits an agent reaches for when
blocked: a `--write-baseline`, a shell edit, copy or redirect aimed at
`quality.json`, anything under `quality/`, or the settings file itself, and
an Edit or Write to those paths. Running a gate is fine; changing what it
accepts is a person's, in a reviewed commit. Neither reads the process list
or starts a build. Every firing of either is one line in
`quality/.events.jsonl`, gitignored, and `python3 quality/bin/gate.py --stats
--since 7d` reports firings, fail rate, fixes after the hook fed a failure
back, and what the guard refused. A hook fires whatever permission mode the
session runs in, so an unattended worker under bypass meets both.

