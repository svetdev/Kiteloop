#!/bin/bash
# run-unit-suite — execute KiteloopTests, or refuse because the app is running.
#
# Nothing else in the repository can answer "is the suite green?". The command
# lived only in prose, in spellings that had already drifted apart, and typing
# the wrong one while Kiteloop is up is not a typo you get to take back:
# KiteloopTests is hosted by Kiteloop.app (TEST_HOST, ai.kasatkin.kiteloop), so
# `xcodebuild … test` launches a second Kiteloop as the XCTest host and macOS
# terminates the running instance — including any autopilot run inside it. That
# happened on 2026-08-04 and stranded two in-flight items.
#
# So this is one invocation with two outcomes: it refuses — because the app is
# running, or because pgrep could not tell it whether the app is running — or it
# runs the unit suite and exits with xcodebuild's status, unless xcodebuild came
# back green having reported no tests at all, which is its own
# non-zero status, see "What the script exits with" below. Either
# way a finished run leaves a record in docs/suite-status.md, so "is the suite
# green, and at what commit?" is answered by the repository rather than by a
# terminal someone has since closed. Nothing but this script may append to that
# file: a row is an instrument reading, and the only thing entitled to write one
# is the thing that took it. The Provenance section below is what makes a row
# written by hand tell you so.
#
# Before xcodebuild it runs a preflight, in order, from the repo root.
# scripts/test-check-target-membership.py, then (through cleat's runner below)
# the check it asserts — that order for the reason the tally reader is asserted
# ahead of the run that uses it. The membership check is regex over project.pbxproj whose failure mode is
# silence: one pattern that stops matching and it vouches for every file
# forever, which is the state it was written to end.
# scripts/check-target-membership.py itself: a .swift file absent from
# project.pbxproj compiles nowhere, so xcodebuild cannot report it — a test file
# in that state is not a failure, it is a silence, and 26 of them had
# accumulated before that check existed. Then scripts/test-run-unit-suite.sh,
# which asserts the tally reader below against synthetic logs, so a tally reader
# that has stopped reading xcodebuild's output correctly stops the run before a
# build starts rather than quietly recording a wrong row. Then
# scripts/test-kiteloop-verify.py, which holds scripts/kiteloop-verify.py's
# --json mode to one JSON document on stdout: that is the contract every machine
# reader of the control harness parses, and it broke once already by narrating a
# header onto stdout, which no reader survives. Then
# scripts/test-export-coverage-lcov.py, which drives
# scripts/export-coverage-lcov.py — the postflight step that writes the one
# LCOV file the changed-coverage gate reads, from the run's bundle and the
# package's profile data — over saved inputs in a throwaway repository: an
# executable line kept with its count, a non-executable one dropped, the
# package's 0% shadow copy in the app bundle and llvm-cov's generated runner
# both left out, and a missing input refused naming what to pass. No xcrun,
# no build.
#
# Then quality/tests/run.sh — cleat's own suites, every one of them, ahead of
# the gate it asserts, for the reason the tally reader is asserted ahead of the
# run that uses it: a gate that has stopped judging what it claims to judge
# should stop the run rather than report OK from inside it. run.sh runs every
# suite beside it, so a suite cleat adds is run here without an edit to this
# array (the guard-suites gate reads a run.sh entry as every suite in its
# directory).
# One suite per gate, and one each for the shared loader, the ratchet engine,
# the runner, attach and the per-language conformance fixtures. Each drives its
# check over a throwaway tree it writes in a temporary directory; none reads the
# process list or starts a build, and quality/tests/test-mutate.py's few seconds
# of swift test run against a fixture package, not this one. Then quality/bin/gate.py
# --skip-missing-tools, cleat's runner, which runs every gate quality.json
# configures — cleat's, and Kiteloop's own checks from its `commands` list:
# scripts/check-target-membership.py, scripts/check-test-host-hook.sh,
# scripts/check-repo-map.py, scripts/check-control-api-docs.py and
# scripts/check-companion-api-list.py, each right after the guard suite that
# asserts it ran here — and exits non-zero naming what failed: doc-size (CLAUDE.md under
# its word ceiling), doc-citations (every path docs/features.md cites resolves),
# test-hygiene (the habits the suite was cleaned of stay under their ceilings),
# guard-suites (every test-* under the swept roots is named in this array or
# exempt with a reason), complexity (no production function over cyclomatic 8
# or 60 lines beyond quality/complexity-baseline.json — lizard reading the app,
# the package, the iOS companion and the Python and TypeScript tooling),
# layering (Views/App > ViewModels > Services > Runtime > Models > Extensions,
# downward only, exemptions per root with reasons) and reachability (every
# Services/* file is constructed by something). Every gate is a ratchet: the
# debt that stood the day it was adopted is in its baseline and goes
# unreported, an entry that matches nothing is named, and a machine missing a
# gate's tool reports that gate as skipped rather than failing it, which is what
# the flag is for — CI's install step keeps lizard and swiftlint present. CRAP
# is the one gate it does not run here: it reads a coverage run, so it stays
# the postflight below.
#
# Then the six guard suites for the tooling that moves code into
# KiteloopCore, immediately ahead of the package's own tests since they
# maintain the package that entry runs: scripts/core-package/test-core-check.py,
# scripts/core-package/test-core-inits.py, scripts/core-package/test-core-move.py,
# scripts/core-package/test-core-pick.py, scripts/core-package/test-pbx-register.py
# and scripts/core-package/test-test-move.py, each asserting its own script's
# readers and refusals over a throwaway tree or fixture text — no move, no git
# command, no build — and none reading the process list, so all six stayed safe
# here from the day they were written. Three open backlog items had named
# wiring them in as their own out-of-scope, which is how they ran nowhere
# standing until now. scripts/core-package/test-move.py is deliberately absent
# from this preflight: despite its name it is the mover for app-hosted tests,
# not a guard suite, and running it here would run a migration tool over this
# checkout on every suite run rather than assert one; test-test-move.py above
# is its guard suite.
#
# Then scripts/test-run-core-tests.sh, then scripts/run-core-tests.sh itself —
# the one entry that compiles and runs real tests rather than only reading the
# tree. KiteloopCore is a local Swift package whose test target needs no host,
# so swift test runs it in a plain xctest process with no Kiteloop.app involved;
# a red package stops the run with swift's own status before xcodebuild starts,
# the way every other preflight entry stops it, and this is also the one entry
# with no timeout of its own, so a hang here used to hold the whole suite
# silently before any build. The test drives a copy of the script against a stub
# swift on PATH from a throwaway root, asserting the status handed back is
# swift's own rather than a constant the script invented.
#
# Then scripts/test-make-release.sh, which asserts the readers in
# scripts/make-release.sh — the check that the three MARKETING_VERSION sites
# have not drifted, and the notes it cuts from the CHANGELOG. Those two ran
# nowhere a suite run could see them: the features map only when a contributor
# remembered it, and the release readers only when a v* tag had already started
# a release, which is the worst moment to learn the drift check has stopped
# reading the version.
#
# Then scripts/test-make-mobile-release.sh, which runs
# scripts/make-mobile-release.sh in a throwaway repo against a stub xcodebuild
# and asserts its refusals — a missing App Store Connect key or team stops it
# before anything builds — and that the build number moves with HEAD.
#
# Then scripts/test-verify-map-replay.sh, which drives
# scripts/verify-map-replay.sh — the tool that replays a repo's
# .kiteloop/verify-map.json against a real diff — over fixture repos of its
# own: a real merge commit, an empty file, empty stdin, and a commit that
# touches nothing, holding both ends of the one bug worth guarding, that an
# empty changed-file list must be refused rather than printed as covered. It
# ran nowhere a suite run could see it, builds nothing, and takes ~10s.
#
# Then scripts/test-install-control-forwarder.sh, which runs
# scripts/install-control-forwarder.sh end to end against a temp HOME and a
# stub launchctl and asserts what it installs, uninstalls and leaves alone —
# it ran only when someone happened to invoke it by hand, so a break in the
# installer that copies control-forwarder.py, writes its LaunchAgent plist or
# drives launchctl went unnoticed until the next person tried to reach the
# control server from their phone.
#
# Then, through cleat's runner, scripts/check-test-host-hook.sh, which reads the
# PreToolUse hook's grep -E pattern out of .claude/settings.json — not a copy of
# it, which could agree with itself while disagreeing with the hook that
# actually runs — and asserts which xcodebuild actions it classifies as deny:
# test and test-without-building, which launch the app-hosted test host, and not
# build-for-testing or a plain build, which do not. And
# scripts/test-test-host-hook.sh, which drives that same hook command end
# to end against a stub pgrep and asserts what it actually does rather than what
# its pattern alone would suggest: grep reads one line at a time, so a command
# laid out across backslash continuations used to slip past denial while the
# same command on one line was denied, and this exercises both layouts against
# the real hook and its real denial message.
#
# Then scripts/test-check-repo-map.py, then scripts/check-repo-map.py (through cleat's runner),
# which fails a file under scripts/, quality/ or .github/ that docs/repo-map.md
# names nowhere: .gitignore already states the rule — a file "would have to earn a
# row in docs/repo-map.md to be tracked" — and nothing enforced it before this,
# so the map drifted twice, most recently leaving four files under
# scripts/core-package/ silently unlisted. It reads every backticked span in
# the file by its basename, since that is the one spelling every row agrees
# on: a row spells a file's path once and its neighbours in the same
# directory bare. The test drives that reading over a throwaway tree of its
# own, then runs the real check against this checkout.
#
# Then scripts/test-check-doc-links.py, the suite ahead of scripts/check-doc-links.py
# (which itself runs through cleat's runner, as a quality.json command); the check
# fails a relative Markdown link, anywhere in the tracked Markdown, that
# resolves to nothing. Two shipped that way: docs/suite-status.md and
# docs/autonomy.md each linked a dated record the 2026-08-17 pre-publish audit
# had removed, so both 404'd for anyone reading the repository on GitHub, and
# nothing said so — the doc-citations gate resolves paths, but only the ones
# cited in docs/features.md. Code is masked before any link is read, so an
# illustration of a link written inside a fence or a code span is not one, and
# no exemption list is needed. An http, mailto or bare-anchor target is never
# resolved against the filesystem: an external link would need a network call,
# which has no place in a preflight. The test drives the maskers and readers
# over synthetic Markdown, then the check itself over a throwaway checkout
# carrying one link of each shape.
#
# Then scripts/test-control-forwarder.py, which asserts
# scripts/control-forwarder.py's address readers — hostname_addresses(),
# routing_table_addresses(), and addresses(), which composes them — over a
# synthetic socket.getaddrinfo and a fake UDP socket standing in for the
# routing-table probe, asserting the tailnet address leads, duplicates and
# non-private rows drop out, and an address getaddrinfo misses is still found
# through the probe. It runs after the guard-suite pair: the
# forwarder itself binds real sockets and runs forever, which is exactly what
# a preflight step must not do.
#
# Then scripts/test-check-control-api-docs.py, then (through cleat's runner)
# scripts/check-control-api-docs.py, which fails when docs/control-api.md
# disagrees with ControlRouter.table: an endpoint documented that the API does
# not answer, one answered that is not documented, a duplicated index row, or
# a `### METHOD /path` section with no matching row. Two retired endpoints,
# POST /v1/coordinator/action and PUT /v1/coordinator/policy, stayed
# documented for a day after the routes themselves were deleted, and nothing
# said so. A `:id` capture segment in the table and its `{runId}` doc spelling
# are read as the same request, not a disagreement. The test drives its
# readers over synthetic table and doc text, one fixture per disagreement the
# check exists to name, then runs the check itself against mutated copies of
# the real files through --router/--doc.
#
# Then scripts/test-check-companion-api-list.py, then (through cleat's runner)
# scripts/check-companion-api-list.py, which fails when the phone companion's
# KiteloopMobile/README.md lists a different control API than its sources
# call: a `/v1/…` path called under KiteloopMobile/Sources with no row in the
# README's table, a row nothing calls, or a path either names that is no
# route in ControlRouter.table. The table is the list of what the Mac has to
# keep answering for the phone to work, and a screen that starts calling
# something new leaves it quietly incomplete unless something says so. Query
# strings are ignored — the table spells `?project=` for the reader. The test
# drives the readers over synthetic sources, table and router text, then runs
# the check end to end over a scratch tree with one disagreement of each kind.
#
# None of the preflight launches the app-hosted test host or reads the process
# list, which is what makes it safe while Kiteloop is running — not that none
# of it runs anything: scripts/run-core-tests.sh compiles and runs
# KiteloopCore's own tests under swift test, quality/bin/gate.py shells out to
# lizard for the complexity gate, and quality/tests/test-mutate.py runs swift
# test itself over a throwaway fixture package, and all three stay safe on that
# narrower ground. test-check-target-membership.py drives the membership
# check's readers over synthetic pbxproj text and its reports over mutated
# copies written to a temporary directory, test-kiteloop-verify.py drives
# kiteloop-verify.py against a port nothing listens on, with a stub token,
# cleat's twenty-six suites each drive their own gate, reader or engine piece
# over a throwaway tree written to a temporary directory — the complexity
# suite over a saved lizard CSV, the CRAP suite over coverage files it writes
# itself, the hotspots suite over throwaway git repos of its own — and gate.py
# itself only reads the tree and starts no build,
# test-core-check.py, test-core-inits.py, test-core-move.py, test-core-pick.py,
# test-pbx-register.py and test-test-move.py each drive their own script's
# readers and refusals over a throwaway tree or fixture text, moving nothing
# and starting no build, test-run-core-tests.sh drives run-core-tests.sh against a stub swift on PATH,
# test-make-release.sh
# sources make-release.sh and drives its refusals against a
# throwaway checkout whose xcodebuild is a stub, test-make-mobile-release.sh
# does the same for make-mobile-release.sh, test-verify-map-replay.sh
# drives verify-map-replay.sh against fixture repos of its own,
# test-install-control-forwarder.sh
# drives install-control-forwarder.sh against a temp HOME with a stub launchctl
# first on PATH, which loads, unloads and asks launchd about nothing real,
# check-test-host-hook.sh only
# reads .claude/settings.json and grep's a table of commands through the pattern
# it finds there, test-test-host-hook.sh drives the hook itself with a stub
# pgrep on PATH standing in for the process list, test-check-repo-map.py reads
# only a throwaway tree it builds and tears down itself, test-control-forwarder.py
# drives control-forwarder.py's address readers over a synthetic
# socket.getaddrinfo and a fake UDP socket, opening no real one, and the last
# drives check-control-api-docs.py's readers over synthetic table and doc
# text and its report over mutated copies of the real files written to a
# temporary directory, and test-check-companion-api-list.py reads only a
# scratch tree under a temporary directory — so each is safe while
# Kiteloop is up. A failed preflight exits with that command's own status and
# writes no record: nothing was measured.
#
#   ./scripts/run-unit-suite.sh             # run the suite (refuses if Kiteloop is up)
#   ./scripts/run-unit-suite.sh --dry-run   # print the commands, run nothing
#   ./scripts/run-unit-suite.sh --last      # print the newest record and the drift since
#   ./scripts/run-unit-suite.sh --flakes    # every test the whole record has decided both ways at one commit
#
# xcodebuild also has a ceiling, SUITE_TIMEOUT_SECONDS: a run that outlives it
# is ended by this script rather than left to sit. A wedged build reads exactly
# like a slow one to whoever is not watching it — one sat 7h45m before a person
# noticed and killed it by hand, recorded at 0b618076 next to green runs on
# either side that took about 520s each. A run this script ends this way is not
# recorded as an ordinary crash: its tally cell says so and names the ceiling,
# read the same way NO_TALLY_CELL is everywhere a tally states a verdict, and
# this script still exits non-zero for it.
#
# A run also holds a power assertion for as long as xcodebuild is up —
# `caffeinate -i -s -w $build_pid` — so a Mac left alone does not idle- or
# system-sleep partway through one. The wall clock a sleeping machine spends is
# charged against the ceiling above just as a wedge's is, so an unattended run on
# a Mac that slept was ended at the limit and recorded as a build that outran its
# time limit: a red measurement of nothing, and in docs/suite-status.md
# indistinguishable from the wedge the ceiling exists to catch. `-w` rather than
# running the build under caffeinate, because the ceiling has to signal
# xcodebuild's own process group and `wait` has to report xcodebuild's own exit
# status, and both want $build_pid to be xcodebuild itself. A machine with no
# caffeinate on PATH runs exactly as it always did.
#
# The refusal tests the same pgrep pattern as the PreToolUse hook in
# .claude/settings.json, so the two cannot disagree about what "running" means —
# and both now refuse when pgrep could not answer at all, rather than reading
# that as a no; see "Is Kiteloop running?" below. The hook denies the dangerous
# command; this is the positive path beside it.
#
# -only-testing:KiteloopTests is named explicitly so the script keeps meaning
# "the unit suite" whether or not the shared scheme is ever narrowed — and so a
# headless KiteloopUITests, which cannot enable automation mode and exits 65,
# never stands in for a unit failure.

set -u

# The first dot is bracketed so the pattern text is not itself an instance of
# what it searches for. `pgrep -f` matches a whole command line, and `-a` puts
# the probe's own ancestors back in the match, so a pattern spelled
# `Kiteloop.app/...` finds any shell that merely carries those characters as an
# argument — which is exactly the shape of the PreToolUse hook's own `sh -c`
# command line, where it answered "Kiteloop is running" on a quiet machine.
# `Kiteloop[.]app/...` matches the same command lines and no longer matches
# itself. This script holds the pattern in a variable rather than on a command
# line, so it was not the one that self-matched; it is spelled the same way
# because the two guards are meant to mean the same thing by "running", and a
# pattern that is safe only where it happens to be stored is a trap for whoever
# copies it next.
KITELOOP_PATTERN="Kiteloop[.]app/Contents/MacOS/Kiteloop"
RECORD_RELPATH="docs/suite-status.md"

# The tally cell a finished run records when no framework reported a summary at
# all: the run matched no tests, so nothing was measured. Spelled here rather
# than at the append below, because show_last now reads it too — a writer and a
# reader of one sentence, written twice, are two sentences waiting to drift.
#
# It is the same string as SUITE_RECORD_NO_TALLY in scripts/kiteloop-verify.py,
# which fails such a row for the same reason: the `exit` cell beside it is
# xcodebuild's own 0, and read alone that is the "green because it never ran"
# answer.
NO_TALLY_CELL="no tally — xcodebuild exited before running tests"

# How long xcodebuild may run before this script ends it. A wedged build reads
# exactly like a slow one until someone is watching it: the row at 0b618076
# sat 7h45m (27929s) before a person noticed and killed it by hand, next to
# green runs either side of it that took about 520s each. 1800s is a little
# over three times that — room for a slow machine, not room for a wedge to
# hide in.
#
# Read from the environment, with the default falling in only when the
# variable is unset or empty, so scripts/test-run-unit-suite.sh can drive a
# ceiling small enough to hit inside a test without touching what anyone else
# sees.
SUITE_TIMEOUT_SECONDS=${SUITE_TIMEOUT_SECONDS:-1800}
# The other ceiling: a run that prints nothing for this long is wedged, however
# far it is from SUITE_TIMEOUT_SECONDS. The app-hosted run once sat silent after
# 4279 of 4301 cases with no case open in the log, and only the outer ceiling —
# twenty-five minutes further on — would have ended it. A test never takes ten
# minutes without a line; a host that does has stopped.
SUITE_IDLE_SECONDS=${SUITE_IDLE_SECONDS:-600}

# The tally cell a row gets when this script itself ended a run that outlived
# SUITE_TIMEOUT_SECONDS, rather than one xcodebuild ever reported a summary
# for or crashed out of on its own. Split into a prefix and a suffix, with the
# seconds in between, so tally_states_no_measurement below can recognise the
# cell however many seconds it names without hard-coding one number into the
# match.
TIMEOUT_TALLY_PREFIX="no tally — xcodebuild ran past its "
TIMEOUT_TALLY_SUFFIX="s time limit and was ended"
IDLE_TALLY_PREFIX="no tally — xcodebuild printed nothing for "
IDLE_TALLY_SUFFIX="s and was ended"

timeout_tally_cell() {
  printf '%s%s%s' "$TIMEOUT_TALLY_PREFIX" "$1" "$TIMEOUT_TALLY_SUFFIX"
}
idle_tally_cell() {
  printf '%s%s%s' "$IDLE_TALLY_PREFIX" "$1" "$IDLE_TALLY_SUFFIX"
}

# Whether a tally cell states that nothing was measured: an empty cell (a row
# from before the tally column existed), NO_TALLY_CELL, or a cell recording a
# run this script ended at its ceiling. All three are read the same way
# everywhere a tally is read for a verdict — verdict_of below, and the
# "nothing was measured" line in show_last — because none of the three is a
# claim about whether the suite passed.
tally_states_no_measurement() {
  case "$1" in
    ''|"$NO_TALLY_CELL") return 0 ;;
    "$TIMEOUT_TALLY_PREFIX"*"$TIMEOUT_TALLY_SUFFIX") return 0 ;;
    "$IDLE_TALLY_PREFIX"*"$IDLE_TALLY_SUFFIX") return 0 ;;
    *) return 1 ;;
  esac
}

# Whether a tally cell is one this script wrote for a run it ended at its
# ceiling, as against the other two cells that state no measurement. That
# distinction is what lets the readout call a test hung rather than failed: the
# names beside a ceiling row are cases that never came back, which is a different
# fact about them than having been reported as failures.
#
# The prefix alone, which is the same discrimination `suite_record` in
# scripts/kiteloop-verify.py makes on this cell. tally_states_no_measurement
# above matches the suffix too, because there the job is to admit three cells;
# here it is to tell one of the three from the others.
tally_states_timeout() {
  case "$1" in
    "$TIMEOUT_TALLY_PREFIX"*) return 0 ;;
    "$IDLE_TALLY_PREFIX"*) return 0 ;;
    *) return 1 ;;
  esac
}

# What a test outcome can depend on: the app and test sources, the scripts that
# run and read them, and the quality gates the preflight enforces — quality.json
# and everything under quality/bin and quality/tests. A commit landing anywhere
# else — backlog, docs, design notes — cannot change what the suite reports, and
# this backlog produces a great many of those, so --last counts the commits since
# a measurement that touched these separately from the commits since.
CODE_PATHS=(Kiteloop quality quality.json scripts)

# --- The output of a run that did not come back clean -------------------------
#
# A red row names the tests that failed and cannot say why any of them did, and
# both places that could were destroyed by the time anyone read it. The output
# went to a mktemp file this script removes in its own EXIT trap, and the
# .xcresult bundle the row names is swept out of DerivedData within a day: the
# row at 2026-08-11T09:23:01Z (349e40d) names
# Test-Kiteloop-2026.08.10_23-23-02--1000.xcresult, which `find` no longer turns
# up, so the assertion that failed in
# Phase2BIntegrationTests.testFullLifecycleWithCheckpoints — the reading that
# says something in this suite does not decide the same way twice — is gone.
#
# So a run that did not come back clean keeps its whole output beside the
# record, and --last says where. The whole log, not a summary of it: what in
# those four minutes of output explains a failure is not decidable in advance,
# and a reader who has the log can find it while a reader who has this script's
# guess at it cannot.
#
# .kiteloop/ is gitignored and sits under none of the CODE_PATHS entries, so
# nothing written here can make a later run record a `dirty` tree or the readout
# call one dirty.
SUITE_LOG_RELDIR=".kiteloop/suite-logs"

# How many are kept. Enough to hold a week of a red afternoon and its re-runs;
# few enough that the directory never becomes something to manage.
SUITE_LOG_KEEP=20

# Held as repo-relative command lines — that is how you would type them, and it
# is what --dry-run prints — then run in this order against the resolved $root,
# so the caller's directory never decides which copy of a script executes. Each
# entry is split on whitespace, so no argument in one may contain a space.
PREFLIGHT=(
  "scripts/test-check-target-membership.py"
  "scripts/test-run-unit-suite.sh"
  "scripts/test-kiteloop-verify.py"
  "scripts/test-export-coverage-lcov.py"
  "quality/tests/run.sh"
  "quality/bin/gate.py --skip-missing-tools"
  "scripts/core-package/test-core-check.py"
  "scripts/core-package/test-core-inits.py"
  "scripts/core-package/test-core-move.py"
  "scripts/core-package/test-core-pick.py"
  "scripts/core-package/test-pbx-register.py"
  "scripts/core-package/test-test-move.py"
  "scripts/test-run-core-tests.sh"
  "scripts/run-core-tests.sh"
  "scripts/test-make-release.sh"
  "scripts/test-make-mobile-release.sh"
  "scripts/test-verify-map-replay.sh"
  "scripts/test-install-control-forwarder.sh"
  "scripts/test-test-host-hook.sh"
  "scripts/test-check-repo-map.py"
  "scripts/test-control-forwarder.py"
  "scripts/test-check-control-api-docs.py"
  "scripts/test-check-companion-api-list.py"
  "scripts/test-check-doc-links.py"
)

# The unit-test target: what the build is narrowed to, and the prefix the
# parallel reader below puts on an XCTest case name, since that shape prints the
# name without it.
TEST_TARGET=KiteloopTests

# `-parallel-testing-enabled YES` spreads the suite over clones of the host app
# — the shared scheme marks KiteloopTests parallelizable — which took the run
# from 657s on one core to 93s on eighteen. It also changes what xcodebuild
# prints; see "The parallel shape" below.
XCODEBUILD=(
  xcodebuild
  -project Kiteloop.xcodeproj
  -scheme Kiteloop
  -destination "platform=macOS"
  -only-testing:$TEST_TARGET
  -parallel-testing-enabled YES
  -enableCodeCoverage YES
  test
)

# Run after a green row, from the repo root: the CRAP gate reads the coverage
# the run just wrote, so it cannot be a preflight. A failure here leaves the
# row as recorded — the suite did pass — and makes this script's exit red, so
# a gate nobody reads still stops a pipeline. Not run after a red or unmeasured
# row, where its answer would be noise on top of the reason the row is red.
#
# quality/bin/check-crap.py's own glob over DerivedData matches every checkout
# on the machine, newest wins — harmless on a machine with one, and a coin
# flip on one with an autopilot worktree's DerivedData beside this one. The
# loop below hands it this run's own bundle path with --bundle, read off this
# run's own log by bundle_path_from_log, so it is never left to guess.
#
# Ahead of it, scripts/export-coverage-lcov.py writes .kiteloop/coverage/suite.lcov
# from the same bundle (handed the same --bundle) and the package's profile
# data under KiteloopCore/.build, which scripts/run-core-tests.sh refreshed in
# this run's preflight: the one LCOV file cleat's changed-coverage gate reads.
# After the CRAP gate, quality/bin/gate.py --postflight --gate changed-coverage
# judges the lines this checkout changed against its base that the suite did
# not execute — no baseline, the scope is the change itself. Under .kiteloop/
# so nothing lands in the tree or makes a later run read as dirty.
POSTFLIGHT=(
  "scripts/export-coverage-lcov.py --out .kiteloop/coverage/suite.lcov"
  "quality/bin/check-crap.py --quiet"
  "quality/bin/gate.py --postflight --gate changed-coverage"
)

# The header block above, which is the only place the refusal, the preflight and
# the exit-status rules are stated to someone at a terminal. It is read as what
# it is — the run of comment lines after the shebang, ending at the first line
# that is not one — rather than as a line range: `sed -n '2,53p'` was correct on
# the day it was written and silently wrong afterwards, cutting the tail off the
# help when a paragraph was added and printing `set -u` and the code under it as
# documentation when one was removed.
#
# ${BASH_SOURCE[0]} rather than "$0" because under `source` those differ: $0 is
# then the sourcing script, so a sourced copy would print that file's header
# instead of this one — which is why this was the one reader
# scripts/test-run-unit-suite.sh could not exercise where it exercises all the
# others.
usage() {
  awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}" |
    sed 's/^# \{0,1\}//'
}

# Print one argument the way you would have to type it. Anything outside the
# characters a shell leaves alone gets quoted, so the printed line is both a
# faithful record of what runs and safe to paste.
quote_arg() {
  case "$1" in
    *[!A-Za-z0-9._/:-]*) printf '"%s"' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

print_command() {
  local arg sep=""
  for arg in "$@"; do
    printf '%s' "$sep"
    quote_arg "$arg"
    sep=" "
  done
  printf '\n'
}

# Every command, in the order it runs: the preflight from the repo root, then
# xcodebuild from Kiteloop/. Anything that changes here changes what --dry-run
# says, which is what the docs quote.
command_line() {
  local entry
  local -a argv
  for entry in "${PREFLIGHT[@]}"; do
    argv=($entry)
    print_command "${argv[@]}"
  done
  print_command "${XCODEBUILD[@]}"
  for postflight_entry in "${POSTFLIGHT[@]}"; do printf '%s   # postflight, after a green row\n' "$postflight_entry"; done
}

# Records are written with a single space of padding around each cell so the
# file reads as a table; take it back off before using a field.
trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# Every table row in the record, oldest first, or nothing. A row is any table
# line whose first cell starts with a year, which is what distinguishes it from
# the header and the rule.
table_rows() {
  [ -e "$1" ] || return 0
  grep -E '^\| [0-9]{4}-' "$1"
}

# The newest record, or empty.
newest_record() {
  table_rows "$1" | tail -n 1
}

# --- A run that disagreed with itself ----------------------------------------
#
# The newest row is the last measurement, not the only one. A test that fails and
# then passes at one commit leaves two rows a few minutes apart, and --last read
# the second one alone: docs/suite-status.md holds exactly that pair at 349e40d —
# `✘ 3362 tests, 2 failures` naming
# KiteloopTests.Phase2BIntegrationTests.testFullLifecycleWithCheckpoints, then
# `✔ 3362 tests passed` six minutes later — and from the newest row the tree is
# simply green there. It is green on the second try, which is a different fact
# about the suite and the more useful one: the first reading is the evidence that
# something in it does not decide the same way twice.
#
# So the readout says when the rows at the newest row's commit did not agree. It
# stays a readout: nothing is written, no column is added, and the rows
# themselves are left exactly as the run that took them wrote them.

# The verdict a row states, as the glyph combine_tally writes — read from its
# `exit` cell ($1), which is xcodebuild's own status: `0` is ✔ and any other
# integer ✘. That is the cell `row_verdict` in scripts/kiteloop-verify.py reads,
# and reading it here means one row cannot be red to that check and invisible to
# this one. It used to read the tally glyph ($2), which a single framework's line
# passed through verbatim carries none of — so a red row spelled that way stated
# no verdict at all here while stating `exit 65` plainly to the reader beside it.
#
# The glyph stays as the fallback, for a cell carrying no integer: a row from a
# record layout without an `exit` column reads exactly as it did. Empty when
# neither cell states a verdict, and a row stating none cannot disagree with
# anything, so those are passed over rather than guessed at.
verdict_of() {
  local status=$1 tally=$2
  # A tally stating no measurement states no verdict either, whatever the exit
  # cell holds — checked ahead of it rather than after. The classic no-tally
  # row's own exit cell is xcodebuild's own 0, which the branch below would
  # otherwise read as a pass; a row this script ends at its ceiling carries a
  # real non-zero exit, which the branch below would otherwise read as a fail.
  # Neither is a verdict this row states.
  if tally_states_no_measurement "$tally"; then
    return 0
  fi
  case "$status" in
    0) printf '✔'; return 0 ;;
    ''|*[!0-9]*) ;; # no status to read — fall through to the tally glyph
    *) printf '✘'; return 0 ;;
  esac
  case "$tally" in
    ✔*) printf '✔' ;;
    ✘*) printf '✘' ;;
    *) printf '' ;;
  esac
}

# Whether two recorded commit cells ($1, $2) name the same commit.
#
# The cell is a git abbreviation, and its width is not fixed: `rev-parse --short`
# picks a width that grows with the object store and moves again when it is
# repacked, so docs/suite-status.md holds cells of two widths already — 92 of
# eight characters and four of seven. Read with a string equality test, one
# commit spelled `349e40d` in one row and `349e40db` in the next is two commits,
# and the three readings that group rows by commit each lose a measurement that
# way: a test that decided both ways across the pair is invisible to --flakes,
# uncounted by --last's earlier line, and called fixed rather than flipped by
# the flaky line.
#
# Equal, or one a prefix of the other, is the whole rule. An abbreviation is a
# prefix of the object name it abbreviates, so two abbreviations of one commit
# are prefixes of each other, and two cells where neither is a prefix of the
# other name two commits — including two different cells of the same width,
# which the prefix test rejects on its own. An empty cell abbreviates nothing
# and matches nothing, not even another empty one.
#
# Two commits sharing an abbreviation would defeat this, but git chooses the
# width so that no two objects in the repository do; and the same collision
# would make the record's own commit cells ambiguous to a person reading them.
same_commit_cell() {
  local a=$1 b=$2
  [ -n "$a" ] && [ -n "$b" ] || return 1
  case "$a" in "$b"*) return 0 ;; esac
  case "$b" in "$a"*) return 0 ;; esac
  return 1
}

# One line about the measurements at commit $2 that reached a verdict other than
# $3, or nothing when they all agreed. The disagreement is what is reported, in
# either direction: a green row under a red newest one says the same thing about
# the suite as a red row under a green one.
#
# The names come from the failing-tests cells of the rows that disagreed, so the
# line names what was red at a commit whose newest row is green. A row from
# before that column existed simply carries none, and contributes only to the
# count — there is nothing to name and nothing is printed in its place.
disagreement_line() {
  local record=$1 newest_commit=$2 newest_verdict=$3
  local row commit tree tally exit_status failing verdict other total=0 against=0 names=""
  local nl=$'\n'
  [ -n "$newest_verdict" ] || return 0

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r _ _ commit tree tally exit_status _ failing _ _ <<ROW
$row
ROW
    same_commit_cell "$(trim "$commit")" "$newest_commit" || continue
    # A dirty row is no reading of the commit it names, the same rule and the
    # same reason show_flakes applies it — skipped before it is counted, so it
    # neither joins the total nor the count that disagreed.
    [ "$(trim "$tree")" = 'clean' ] || continue
    verdict=$(verdict_of "$(trim "$exit_status")" "$(trim "$tally")")
    [ -n "$verdict" ] || continue
    total=$((total + 1))
    [ "$verdict" = "$newest_verdict" ] && continue
    against=$((against + 1))
    failing=$(trim "$failing")
    case "$failing" in
      ''|'—') ;;
      *) names="$names${names:+$nl}${failing//, /$nl}" ;;
    esac
  done <<ROWS
$(table_rows "$record")
ROWS

  [ "$against" -gt 0 ] || return 0
  other=✔
  [ "$newest_verdict" = '✔' ] && other=✘
  printf '%s of %s measurements at %s recorded %s' \
    "$against" "$total" "$newest_commit" "$other"

  # Deduplicated, keeping first appearance: a test that failed in each of three
  # red rows at one commit is one name, said once, and saying it three times
  # would read as three different tests.
  names=$(printf '%s\n' "$names" | awk 'NF && !seen[$0]++ { printf "%s%s", sep, $0; sep = ", " }')
  [ -n "$names" ] && printf ' — %s' "$names"
  printf '\n'
}

# --- A test that did not decide the same way at two commits -------------------
#
# The line above compares rows at one commit, which is the shape a re-run leaves.
# The other shape is a red row and a green one a commit or two apart, and nothing
# reported it: the readout answered green off the newest row and remembered
# nothing, so the red reading scrolled out of view the moment a later run landed.
# docs/suite-status.md holds that pair twice —
# KiteloopTests.SessionTitleGeneratorTests.testEmptyAnswerIsNoTitle red at
# fdcf4add and green in the row after it, and
# KiteloopTests.CoordinatorQueueRefillTests.testEachStalledPassIsCountedOnceHoweverItWasEnded
# red at f4405428 and green at b7c6214c — and both cost somebody a chase.
#
# What is reported is what was recorded and nothing more: a test the record has
# red at an earlier commit and ✔ in a later row. Whether that is a flake or a
# test somebody fixed is not decidable from the rows, and the line does not
# guess.

# How many of the newest rows that reading looks at. Twenty is about a day of
# runs here — long enough to hold a red afternoon and the green runs after it,
# short enough that a test fixed a month ago stops being news.
FLAKY_WINDOW_ROWS=20

# The tests the newest FLAKY_WINDOW_ROWS rows record red at a commit other than
# $2 — the newest row's — and ✔ in a strictly later row, or nothing when there
# are none.
#
# Red rows *at* the newest commit are left to disagreement_line above, which
# already names them; reporting them here too would print one pair of rows twice
# under two labels.
flaky_line() {
  local record=$1 newest_commit=$2
  local row commit tree tally exit_status failing verdict
  local nl=$'\n' names="" newest_failing="" seen_green="" newest_read="" kept count

  # Newest row first, so a green row is read before the red rows it comes after
  # and one flag says "a later row recorded ✔" — no second pass, and no array to
  # index, which keeps this readable under the bash 3.2 macOS ships.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r _ _ commit tree tally exit_status _ failing _ <<ROW
$row
ROW
    commit=$(trim "$commit")
    # A dirty row is no reading of the commit it names, the same rule
    # show_flakes and disagreement_line apply — skipped before it can set
    # seen_green, fill newest_failing, or contribute a name. Without this a
    # dirty green row would still grant a red row its "✔ since".
    [ "$(trim "$tree")" = 'clean' ] || continue
    verdict=$(verdict_of "$(trim "$exit_status")" "$(trim "$tally")")
    failing=$(trim "$failing")

    # A test the newest row still records red has not passed since anything, and
    # the readout has just printed it on its own `failing` line. Whatever an
    # older row says about it, this line does not get to call it green.
    if [ -z "$newest_read" ]; then
      newest_read=yes
      if [ "$verdict" = '✘' ]; then
        newest_failing=$failing
      fi
    fi

    if [ "$verdict" = '✔' ]; then
      seen_green=yes
      continue
    fi
    [ "$verdict" = '✘' ] || continue
    [ -n "$seen_green" ] || continue
    same_commit_cell "$commit" "$newest_commit" && continue
    case "$failing" in
      ''|'—') ;;
      # Prepended, since the walk is backwards: the list ends up in the record's
      # own order, so the dedup below keeps the first appearance the way
      # disagreement_line's does.
      *) names="${failing//, /$nl}${names:+$nl}$names" ;;
    esac
  done <<ROWS
$(table_rows "$record" | tail -n "$FLAKY_WINDOW_ROWS" |
  awk '{ row[NR] = $0 } END { for (i = NR; i > 0; i--) print row[i] }')
ROWS

  kept=$(printf '%s\n' "$names" | awk -v red="$newest_failing" '
    BEGIN { n = split(red, still_red, ", "); for (i = 1; i <= n; i++) still[still_red[i]] = 1 }
    NF && !still[$0] && !seen[$0]++ { print }
  ')
  [ -n "$kept" ] || return 0

  count=$(printf '%s\n' "$kept" | grep -c '[^[:space:]]')
  printf '%s recorded ✘ at an earlier commit and ✔ since — %s\n' \
    "$(count_phrase "$count" test)" \
    "$(printf '%s\n' "$kept" | awk '{ printf "%s%s", sep, $0; sep = ", " }')"
}

# --- --flakes: the same question, over the whole record -----------------------
#
# flaky_line above answers "did a test flip?" over the newest FLAKY_WINDOW_ROWS
# rows, keyed to the newest commit, because that is the shape --last already has
# rows for. A test that flips once a week can scroll out of that window before
# anyone reads it, so this widens the same reading into its own command over
# every row docs/suite-status.md holds.
#
# It answers a narrower question than flaky_line on purpose. flaky_line's own
# comment above says red at one commit and green at a later one is not
# decidable as a flake or a fix, and does not guess — a test can go red because
# it is flaky, or because something else broke it, and come back green because
# it stopped being flaky, or because somebody fixed it. --flakes does not guess
# either: it reports only the one shape the record can call a flake without
# guessing — red and green recorded at the *same* commit over rows the record
# calls clean, which is two readings of identical code deciding two ways. A
# test red at commit A and green only from commit B on is what a fix looks
# like from the rows, and --flakes leaves it out, the way the acceptance
# criteria for this command ask.
show_flakes() {
  local record=$1 rows row when commit tree tally exit_status failing skipped verdict
  local nl=$'\n' lines="" ledger test flips commits first last
  # Counted as the loop below skips, by the reason it skipped for, so the reader
  # can tell "no test flipped" from "no row was readable".
  local rows_total=0 dirty_rows=0 mute_rows=0 unnamed_red_rows=0
  rows=$(table_rows "$record")
  if [ -z "$rows" ]; then
    printf 'run-unit-suite: no suite run has been recorded yet in %s.\n' "$RECORD_RELPATH"
    printf 'Run the suite once — every finished run appends its own record.\n'
    return 0
  fi

  # One tab-separated line per row that states a verdict at all — a row with no
  # tally to read (NO_TALLY_CELL, or one this script ended at its own ceiling)
  # says nothing about any test, and is left out exactly as flaky_line leaves it
  # out. So is a red row naming no test: that is an exit cell and a tally text
  # disagreeing about the same run rather than an ordinary failure (verdict_of
  # trusts the exit cell), and there is no name here to call red or, by its
  # absence from the list, green — asserting either would be a guess. So is a
  # row whose tree cell says dirty: the uncommitted content it measured is
  # unknown and unrecoverable, so it is no reading of the commit it names —
  # left out the same way, for the same reason.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|' read -r _ when commit tree tally exit_status _ failing skipped _ <<ROW
$row
ROW
    when=$(trim "$when")
    commit=$(trim "$commit")
    tree=$(trim "$tree")
    rows_total=$((rows_total + 1))
    if [ "$tree" != 'clean' ]; then
      dirty_rows=$((dirty_rows + 1))
      continue
    fi
    verdict=$(verdict_of "$(trim "$exit_status")" "$(trim "$tally")")
    if [ -z "$verdict" ]; then
      mute_rows=$((mute_rows + 1))
      continue
    fi
    failing=$(trim "$failing")
    case "$failing" in
      ''|'—') failing="" ;;
    esac
    skipped=$(trim "$skipped")
    case "$skipped" in
      ''|'—') skipped="" ;;
    esac
    if [ "$verdict" = '✘' ] && [ -z "$failing" ]; then
      unnamed_red_rows=$((unnamed_red_rows + 1))
      continue
    fi
    lines="$lines${lines:+$nl}$when	$commit	$failing	$skipped"
  done <<ROWS
$rows
ROWS

  # The failing-tests cell names every test that failed in that row, so a known
  # test absent from both it and the skipped-tests cell passed there — true
  # whether that row's own verdict is ✔ or ✘ for some other test. A test named
  # in the skipped-tests cell did not run in that row at all, so that row is no
  # reading for it either way — not red, not green — the same silence
  # show_flakes already grants a row with no tally to read. Grouping those
  # per-row readings by commit and looking for a commit where a test read both
  # ways is the whole test:
  # "distinct outcomes per commit" greater than one, at any one commit, is a
  # flip; only ever one outcome, however many commits it took to get there, is
  # not.
  ledger=$(printf '%s\n' "$lines" | awk -F'\t' '
    NF < 3 { next }
    {
      rn++
      row_when[rn] = $1
      row_commit[rn] = $2
      row_failing[rn] = $3
      row_skipped[rn] = $4
    }
    END {
      # The grouping key is a canonical spelling shared by every cell that names
      # one commit, not the cell as the row wrote it. git abbreviates to a width
      # that moves as the object store grows, so one commit reaches this reading
      # spelled two ways, and keying on the cell verbatim splits its rows into
      # two commits that have each seen only one outcome — which is exactly the
      # shape this reading calls "not a flip". The canonical spelling is the
      # shortest cell in the record that this cell begins with: the prefix rule
      # same_commit_cell applies in the shell, spelled as a key. A cell no
      # shorter cell prefixes is its own key, so two cells that name two commits
      # are never brought together.
      for (r = 1; r <= rn; r++) cell[row_commit[r]] = 1
      for (c in cell) {
        canon[c] = c
        for (p in cell) {
          if (length(p) >= length(canon[c])) continue
          if (substr(c, 1, length(p)) != p) continue
          canon[c] = p
        }
      }
      for (r = 1; r <= rn; r++) row_key[r] = canon[row_commit[r]]
      for (r = 1; r <= rn; r++) {
        n = split(row_failing[r], names, ", ")
        for (i = 1; i <= n; i++) {
          t = names[i]
          if (t == "") continue
          if (!(t in known)) { order[++ntests] = t; known[t] = 1 }
          failed[r, t] = 1
        }
        n = split(row_skipped[r], snames, ", ")
        for (i = 1; i <= n; i++) {
          t = snames[i]
          if (t == "") continue
          if (!(t in known)) { order[++ntests] = t; known[t] = 1 }
          skippedt[r, t] = 1
        }
      }
      for (ti = 1; ti <= ntests; ti++) {
        t = order[ti]
        delete saw_red
        delete saw_green
        delete counted
        nflips = 0; flip_commits = ""; first_ts = ""; last_ts = ""
        for (r = 1; r <= rn; r++) {
          if ((r, t) in skippedt) continue
          c = row_key[r]
          if ((r, t) in failed) { saw_red[c] = 1 } else { saw_green[c] = 1 }
        }
        for (r = 1; r <= rn; r++) {
          if ((r, t) in skippedt) continue
          c = row_key[r]
          if (!((c in saw_red) && (c in saw_green))) continue
          if (!(c in counted)) {
            counted[c] = 1
            nflips++
            flip_commits = flip_commits (flip_commits == "" ? "" : ", ") c
          }
          if (first_ts == "") first_ts = row_when[r]
          last_ts = row_when[r]
        }
        if (nflips > 0) {
          printf "%s\t%d\t%s\t%s\t%s\n", t, nflips, flip_commits, first_ts, last_ts
        }
      }
    }
  ')

  printf 'run-unit-suite: flake ledger\n'
  rows_skipped_line "$rows_total" "$dirty_rows" "$mute_rows" "$unnamed_red_rows"
  if [ -z "$ledger" ]; then
    printf '  none — no test in %s has recorded both a red row and a green row at the same commit.\n' \
      "$RECORD_RELPATH"
    return 0
  fi
  while IFS=$'\t' read -r test flips commits first last; do
    [ -n "$test" ] || continue
    printf '  %s\n' "$test"
    printf '    %s at %s — %s .. %s\n' \
      "$(count_phrase "$flips" flip)" "$commits" "$first" "$last"
  done <<LEDGER
$ledger
LEDGER
}

# One line stating how much of the record the reading above actually read, and
# what it passed over. Without it "none" is two sentences wearing one: no test
# flipped, and no row was readable at all. Every row recorded on 2026-09-10 in
# docs/suite-status.md carries a dirty tree cell, so that record is the second
# case and said so nowhere — the ledger printed the same "none —" line a fully
# read history with no flips gets.
#
# Printed at the header's own indent, never two spaces and never four: those two
# shapes are the contract FlakeLedgerReader.read parses — two spaces is a test
# name, four is that test's flip line — so a line at either indent would be read
# as a finding about a test called "read 0 of 4 rows ...".
rows_skipped_line() {
  local total=$1 dirty=$2 mute=$3 unnamed_red=$4
  local skipped=$((dirty + mute + unnamed_red)) reasons=""
  if [ "$skipped" -eq 0 ]; then
    printf 'run-unit-suite: read all %s in %s.\n' "$(count_phrase "$total" row)" "$RECORD_RELPATH"
    return 0
  fi
  # Named in the order the loop applies them, so the counts read as the reading
  # itself: a row is judged dirty before it is asked for a verdict, and asked for
  # a verdict before it is asked which tests it names.
  [ "$dirty" -gt 0 ] && reasons="$reasons${reasons:+, }$dirty with a dirty tree"
  [ "$mute" -gt 0 ] && reasons="$reasons${reasons:+, }$mute with no verdict to read"
  [ "$unnamed_red" -gt 0 ] && reasons="$reasons${reasons:+, }$unnamed_red red naming no test"
  printf 'run-unit-suite: read %s of %s in %s — skipped %s.\n' \
    "$((total - skipped))" "$(count_phrase "$total" row)" "$RECORD_RELPATH" "$reasons"
}

# CODE_PATHS as a sentence — `Kiteloop/ or quality/ or quality.json or scripts/`.
# Spelled from the array rather than beside it, so the line --last prints cannot
# come to name paths the count was not taken over. An entry is a directory unless
# its name carries a dot — quality.json is the one entry that does, and it reads
# as a file rather than as `quality.json/`.
code_paths_phrase() {
  local path sep=""
  for path in "${CODE_PATHS[@]}"; do
    case "$path" in
      *.*) printf '%s%s' "$sep" "$path" ;;
      *) printf '%s%s/' "$sep" "$path" ;;
    esac
    sep=" or "
  done
}

# How many files are uncommitted under CODE_PATHS — modified, staged or untracked
# — as one number, and 0 when the tree is clean or git cannot answer. The drift
# counts above read the graph alone, so an edit that has not been committed is
# invisible to them and a modified source file reads byte-for-byte like a tree
# nobody has touched.
#
# Scoping to CODE_PATHS is also what keeps the previous run's own appended row
# out of the count: RECORD_RELPATH is docs/suite-status.md, which is under none
# of these paths, so the state every finished run leaves behind never makes the
# readout call the tree dirty. `-uall` names untracked files one by one rather
# than collapsing a directory into a single entry, so the number means files.
uncommitted_code_files() {
  git -C "$root" status --porcelain -uall -- "${CODE_PATHS[@]}" 2>/dev/null |
    grep -c '[^[:space:]]'
}

# How many characters of HEAD's object name a row's commit cell carries.
#
# Asked for explicitly rather than left to git. `rev-parse --short` with no
# width picks one that grows with the object store and moves again when it is
# repacked, so the record accumulated cells of two widths — 92 of eight and four
# of seven — and every reading that groups rows by commit had to be taught that
# two spellings can name one commit (same_commit_cell above). Eight is the width
# the overwhelming majority of the existing rows already carry, so asking for it
# leaves the record's own spelling where it was and stops new rows from adding a
# third width to it.
COMMIT_CELL_WIDTH=8

# The commit cell a run records for the tree it is about to measure: HEAD
# abbreviated to COMMIT_CELL_WIDTH, whatever width git would have chosen on its
# own. `unknown` when git cannot answer — a checkout with no commits, or none at
# all — which is what the cell held before and what the readers already pass
# over as a commit they cannot resolve.
#
# git widens past the width it is asked for when that many characters would name
# two objects, which is the one case where a wider cell is the honest one; the
# prefix rule the readers apply reads it as the same commit either way.
head_commit_cell() {
  local commit
  commit=$(git -C "$root" rev-parse --short="$COMMIT_CELL_WIDTH" HEAD 2>/dev/null)
  [ -n "$commit" ] || commit=unknown
  printf '%s' "$commit"
}

# `clean` or `dirty` for the tree cell a run records — the same question the
# readout's dirty line above asks, over the same scope, so the row and the
# readout cannot answer it differently about one tree. They used to: this looked
# at the whole checkout minus the record file, so an uncommitted backlog or docs
# edit recorded the measurement as taken against a `dirty` tree while --last
# printed no dirty line at all for it. Neither can change what a test reports,
# and the cell exists to say whether anything that could had been left
# uncommitted.
#
# The explicit exclude that carried the record file falls away with the scope:
# RECORD_RELPATH is under none of the code paths, so the row every finished run
# appends is out of this by the same reasoning that keeps it out of the count.
code_worktree_state() {
  if [ -n "$(git -C "$root" status --porcelain -uall -- "${CODE_PATHS[@]}" 2>/dev/null)" ]; then
    printf 'dirty'
  else
    printf 'clean'
  fi
}

# Where the output of the run recorded at `when` is kept. Derived from the cell
# rather than stored beside it, so the row needs no new column and the rows
# already in docs/suite-status.md keep reading — and derived here rather than at
# each end, so the writer and the readout cannot come to name different files,
# which is the reasoning code_paths_phrase and code_worktree_state already carry.
#
# `:` is legal in a macOS filename and is the path separator the Finder still
# shows as `/`, so the timestamp's colons become dashes: the name stays sortable,
# stays chronological, and stays something you can type.
suite_log_path() {
  printf '%s/%s/%s.log' "$root" "$SUITE_LOG_RELDIR" "${1//:/-}"
}

# Whether this run's output is worth keeping: it came back with a non-zero
# status, or with no tally at all — nothing was measured, and the output is the
# only evidence of why — or with tests named in its failing cell. A run that came
# back clean has nothing anyone will want to read, and keeping those too would
# bury the handful that matter under a directory of green.
run_output_is_worth_keeping() {
  local status=$1 tally=$2 failing=$3
  [ "$status" -ne 0 ] && return 0
  [ -z "$tally" ] && return 0
  [ "$failing" = '—' ] || return 0
  return 1
}

# Drop all but the SUITE_LOG_KEEP newest. The names are UTC timestamps, so
# sorting them is ordering them by when the run started — no stat call, and no
# dependence on a mtime a copy or a backup could have rewritten.
prune_suite_logs() {
  local dir=$1 name kept=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    kept=$((kept + 1))
    if [ "$kept" -gt "$SUITE_LOG_KEEP" ]; then
      rm -f "$dir/$name" "$dir/${name%.log}.samples.txt"
    fi
  done <<LOGS
$(ls -1 "$dir" 2>/dev/null | grep -E '\.log$' | sort -r)
LOGS
  return 0
}

# Where each test host was when the run at $1 went silent: a `sample` of every
# Kiteloop process, written beside the log the run keeps, before the wedge is
# ended. Every Kiteloop running now is a test host — this script refused to
# start while the app was up — so the process list is the set of clones. The
# 2026-09-22 wedge was ended with nothing but its last output line to go on;
# the stack of the clone that stopped answering is what would have named it.
# Best effort: a machine without `sample` still has the run ended and recorded.
sample_test_hosts() {
  local dest pid
  dest="$root/$SUITE_LOG_RELDIR/${1//:/-}.samples.txt"
  command -v sample >/dev/null 2>&1 || return 0
  mkdir -p "${dest%/*}" || return 0
  : >"$dest" || return 0
  for pid in $(pgrep -f "$KITELOOP_PATTERN"); do
    { printf '=== pid %s\n' "$pid"; sample "$pid" 2 2>&1; } >>"$dest"
  done
  printf 'run-unit-suite: sampled the test hosts before ending the wedge — %s\n' "$dest"
}

# Keep the log at $1 as the output of the run recorded at $2, and prune. Fails
# without writing anything if the directory cannot be made or the copy cannot be
# taken — a run that could not keep its output is worth saying so about, and is
# not worth failing a measurement over.
keep_suite_log() {
  local src=$1 when=$2 dest
  dest=$(suite_log_path "$when")
  mkdir -p "${dest%/*}" || return 1
  cp "$src" "$dest" || return 1
  prune_suite_logs "${dest%/*}"
}

# --last: what the last run found, and how far the tree has moved since. It
# reads the record and the git graph and starts nothing, so it stays usable
# while Kiteloop is up — which is most of the time, and is exactly when you want
# to know whether the last measurement still describes this tree.
show_last() {
  local record=$1 row when commit tree tally exit_status bundle failing skipped elapsed
  local core_tally
  local ahead noun disagreement flaky dirty log_path
  row=$(newest_record "$record")
  if [ -z "$row" ]; then
    printf 'run-unit-suite: no suite run has been recorded yet in %s.\n' "$RECORD_RELPATH"
    printf 'Run the suite once — every finished run appends its own record.\n'
    return 0
  fi

  # Named through to the last cell so a row that carries a result bundle and the
  # names of the tests that failed or skipped can be read out. Rows written
  # before a column existed simply run out of fields — read leaves the
  # remaining variables
  # empty — so those lines are omitted for them rather than printed blank or
  # filled from the wrong cell.
  IFS='|' read -r _ when commit tree tally exit_status bundle failing skipped elapsed core_tally _ <<RECORD
$row
RECORD
  when=$(trim "$when")
  commit=$(trim "$commit")
  tree=$(trim "$tree")
  tally=$(trim "$tally")
  exit_status=$(trim "$exit_status")
  bundle=$(trim "$bundle")
  failing=$(trim "$failing")
  skipped=$(trim "$skipped")
  elapsed=$(trim "$elapsed")
  core_tally=$(trim "$core_tally")

  # The bundle cell is printed verbatim, and reading it is the whole point: it is
  # the one cell CLAUDE.md and the record's own header point a reviewer at to
  # tell a measured row from a typed one, and until it was printed here that
  # meant opening the table by hand. What it says is the row's business — a
  # bundle name, `none named in the output`, or `not recorded` on rows written
  # before the column existed — and whether the named bundle is still on disk is
  # a question for `find`, not for a readout that starts nothing.
  printf 'run-unit-suite: last recorded run\n'
  printf '  when    %s\n' "$when"
  printf '  commit  %s (%s tree)\n' "$commit" "$tree"
  printf '  tally   %s\n' "$tally"
  # The package's own tally, beside the app-hosted one above — present only for
  # a row that carries the column at all: an empty cell here is a row written
  # before it existed, not a run whose package tally could not be read, which is
  # the dash core_tally_from_output records instead.
  [ -n "$core_tally" ] && printf '  package %s\n' "$core_tally"
  printf '  exit    %s\n' "$exit_status"
  [ -n "$bundle" ] && printf '  bundle  %s\n' "$bundle"

  # The same cell under two labels, because on a ceiling row it holds a different
  # kind of name: a case that never came back, not one that was reported as a
  # failure. `failing HookEngineTests.testTimeout` beside a tally saying the run
  # was ended at its limit invites the reading that the test failed and the run
  # then stopped, when nothing failed at all — the run stopped *on* it. The tally
  # is what says which row this is, read the way scripts/kiteloop-verify.py reads
  # the same cell.
  #
  # On a ceiling row the dash is passed over as well, the way the skipped line
  # passes over its own: a build wedged before any case started has no test to
  # name, and `hung —` would be a line saying so twice. The failing line is
  # untouched for every other row, dash included — that is what almost every row
  # in the record carries, and it reads out today exactly as it always has.
  if tally_states_timeout "$tally"; then
    case "$failing" in
      ''|'—') ;;
      *) printf '  hung    %s\n' "$failing" ;;
    esac
  else
    [ -n "$failing" ] && printf '  failing %s\n' "$failing"
  fi

  # Unlike the failing line, this one is omitted for a dash as well as for an
  # empty cell. A run that skipped nothing has already said so in the tally,
  # which carries no `(N skipped)` parenthesis then, and a `skipped —` line on
  # the ordinary row would be a line saying nothing on almost every readout. It
  # appears when the row recorded a skip at all — which is when the tally above
  # it says so — and answers the question that count leaves open.
  case "$skipped" in
    ''|'—') ;;
    *) printf '  skipped %s\n' "$skipped" ;;
  esac

  # How long the run took. Printed the way the bundle line is — omitted entirely
  # when the cell is empty, which is every row written before the column existed,
  # rather than printed blank or filled from the cell next door. Every finished
  # run has an elapsed time, so unlike the skipped line there is no dash to pass
  # over: a cell is either a duration or a row that predates the column.
  #
  # `elapsed` rather than `duration` for the label because the readout pads every
  # label to the same column and the others are seven characters wide; the record
  # already spells `bundle` for a cell headed `result bundle`, so the label being
  # the shorter word is the convention here rather than a departure from it.
  [ -n "$elapsed" ] && printf '  elapsed %s\n' "$elapsed"

  # And the run's own output, when it was kept — which is when the run did not
  # come back clean. The path is derived from the `when` cell through the same
  # function the writer used, so this line names the file that run wrote rather
  # than a second opinion about where it should have gone. Nothing is printed
  # when the file is not there: a green run kept none, and a red one old enough
  # to have been pruned has none left to offer.
  log_path=$(suite_log_path "$when")
  [ -f "$log_path" ] && printf '  log     %s\n' "$log_path"

  # Whether that run measured anything at all. A run that matched no tests exits
  # 0, because that is what xcodebuild returns for it, so the cells above read
  # `exit 0` beside a tally cell nobody scans as closely — and the readout was
  # then word for word the readout of a green suite, with nothing in it saying
  # the suite had not run. `suite_record` in scripts/kiteloop-verify.py fails
  # exactly this row and says why, so the repository's two readouts of one row
  # disagreed, and the one CLAUDE.md points a person at was the one reading
  # green.
  #
  # Said as that check says it — the run matched no tests, so the zero status
  # read on its own is the "green because it never ran" answer — rather than as a
  # second version of it. An empty cell is read the same way here as it is there:
  # a row stating no tally states no measurement, whichever way it came to say
  # so.
  #
  # A qualification like the three below it, printed first because it qualifies
  # the whole reading: a row that measured nothing has no verdict for the
  # `earlier` line to compare, and no measurement for the drift to have made
  # stale.
  if tally_states_no_measurement "$tally"; then
    printf "  nothing that run matched no tests, so nothing was measured — the exit above is xcodebuild's own status and not a passing suite.\n"
  fi

  # Whether the rows at this commit agreed with each other. Printed under the
  # newest row's own cells because it qualifies them: green here and green here
  # on the second try are different readings, and only the first is what the
  # cells above say on their own.
  disagreement=$(disagreement_line "$record" "$commit" "$(verdict_of "$exit_status" "$tally")")
  [ -n "$disagreement" ] && printf '  earlier %s\n' "$disagreement"

  # And whether anything in the recent rows went red at one commit and green at
  # another. The line above is about this commit; this one is about the window of
  # rows behind it, which is where a test that does not decide the same way twice
  # otherwise disappears the moment a later run lands. Quiet when there is
  # nothing to say, the way the two lines around it are.
  flaky=$(flaky_line "$record" "$commit")
  [ -n "$flaky" ] && printf '  flaky   %s\n' "$flaky"

  # A recorded commit git cannot resolve is normal, not an error: the record
  # outlives rebases, and a squashed or pruned commit still tells you the
  # measurement does not describe this tree. Say so and stay green.
  #
  # Two counts, because the raw one overstates what it is asked. Measured from
  # the row at 2e6d3d1 the tree was 63 commits ahead, of which 31 had touched
  # CODE_PATHS — the rest were backlog and docs, which cannot change what a test
  # reports. The total says how far the tree has moved; the second says how much
  # of that move the last measurement could have been invalidated by. Both come
  # from one rev-list each, so --last still starts nothing.
  ahead=""
  code_ahead=""
  if git -C "$root" rev-parse --quiet --verify "$commit^{commit}" >/dev/null 2>&1; then
    ahead=$(git -C "$root" rev-list --count "$commit..HEAD" 2>/dev/null)
    code_ahead=$(git -C "$root" rev-list --count "$commit..HEAD" -- "${CODE_PATHS[@]}" 2>/dev/null)
  fi
  if [ -z "$ahead" ]; then
    printf '  drift   unknown — git cannot resolve %s in this checkout.\n' "$commit"
  else
    noun=commits
    [ "$ahead" = 1 ] && noun=commit
    printf '  drift   %s %s on HEAD since that measurement, %s of them touching %s.\n' \
      "$ahead" "$noun" "$code_ahead" "$(code_paths_phrase)"
  fi

  # And what the graph cannot see at all. Both counts above are commit counts, so
  # an uncommitted edit under the code paths moves neither: the readout for a
  # tree with a modified source file in it was byte-for-byte the readout for a
  # tree nobody had touched, and the one question --last exists to answer was
  # being answered wrong. This line qualifies the drift line the way the earlier
  # line qualifies the cells above it, and stays quiet on a clean tree — the way
  # the skipped line stays quiet for a dash — so the ordinary readout reads
  # exactly as it did. git status reads the index and the tree and no process
  # list, so --last still starts nothing.
  dirty=$(uncommitted_code_files)
  if [ "${dirty:-0}" -gt 0 ] 2>/dev/null; then
    printf '  dirty   %s uncommitted under %s — the last measurement does not describe this tree.\n' \
      "$(count_phrase "$dirty" file)" "$(code_paths_phrase)"
  fi
}

# --- The tally ---------------------------------------------------------------
#
# KiteloopTests runs under two frameworks at once: it is overwhelmingly XCTest,
# plus two swift-testing suites, and each writes its own summary counting only
# its own tests. Those summaries are not two views of one number — 3,038 and 18
# are disjoint — so the last line to speak is not a better answer than the first,
# it is the other framework's answer with this one's discarded. Reading both
# formats and letting the last one win did exactly that: the run of 2026-08-10
# executed 3,038 XCTest cases and was recorded as "18 tests", and had those 3,038
# contained failures the row would still have read passed, because the exit
# status comes from xcodebuild and the tally from a line that never mentioned
# them.
#
# So each format is read on its own and both are reported. Within a format the
# last line wins — which is right for swift-testing, whose summary is printed
# once.
#
# XCTest prints one `Executed N tests` line per suite, and taking the last of
# them assumed the outermost — the run total — closes last. That holds only for
# a run that finished. XCTest's run total is the line directly beneath
# `Test Suite 'All tests' passed|failed at …`, and a run that dies never prints
# that closing line, so the last match is whichever nested suite happened to
# close before the process went away. The run of 2026-08-13 died with its test
# bundle unloaded and was recorded as
# `Executed 7 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds` —
# a complete, passing measurement, beside `exit 65` and a 359-second duration,
# taken from an inner suite of seven.
#
# So the run total is read from the close rather than from the last line, and a
# run whose outermost suite never closed reports no XCTest total at all. That is
# not a gap in the row: the caller already prints "no test tally in the output",
# records the no-tally cell and keeps the log, which is the true reading of a run
# that never got to say how many tests it ran.
#
# xcodebuild names that outermost suite `All tests` when the bundle ran whole and
# `Selected tests` when something narrowed it, so both spellings open a run — and
# a log can hold several, because a crashed run is retried: the log of 2026-08-13
# opens `All tests` once and `Selected tests` twice, and closes none of the
# three. A pass that did close is not the run's answer while another never did,
# so a total is only reported when every pass that opened also closed. Otherwise
# a retry of eleven tests would be recorded exactly as the inner suite of seven
# was.
#
# A log naming no run suite at all is a fragment rather than a run — the
# synthetic logs in test-run-unit-suite.sh are mostly this shape — and keeps the
# old reading, since there is no close in it to read from and no run boundary to
# be inside of.
XCTEST_SUMMARY='Executed [0-9]+ test'
SWIFT_TESTING_SUMMARY='Test run with [0-9]+ test'
XCTEST_RUN_OPEN="Test Suite '(All|Selected) tests' started at"
XCTEST_RUN_CLOSE="Test Suite '(All|Selected) tests' (passed|failed) at"

# --- The parallel shape -------------------------------------------------------
#
# With `-parallel-testing-enabled YES` xcodebuild spreads the suite over several
# clones of the host app and reports it in a different shape entirely: no
# `Test Suite` opens or closes, no `Executed N tests` total, no `Test run with`
# from swift-testing — one line per case, from either framework,
#
#   Test case 'FooTests.testBar()' passed on 'My Mac - Kiteloop (86621)' (0.076 seconds)
#   Test case 'SkillTests/parseAllFields()' passed on 'My Mac - Kiteloop (86619)' (0.005 seconds)
#
# and `** TEST SUCCEEDED **` or `** TEST FAILED **` once the clones are done.
# The first parallel run went into the record as `no tally — xcodebuild exited
# before running tests` over a log holding 4,931 of those lines, so the readers
# take this shape when the serial summaries are absent. The frameworks are told
# apart by the separator: XCTest spells a case `Class.method()`, swift-testing
# `Suite/name()`. A case line is one test reported once — no per-suite repeat
# to dedup — and a failing case is one failure, since nothing in this shape
# counts assertions, so a red cell here always reads `N failing tests (N
# failures)`. The close marker stands in for XCTest's run close: case lines with
# no marker are a run that died mid-flight, and record no tally for the reason
# xctest_run_total records none for an unclosed run suite. Nothing in this shape
# announces a case before it finishes, so hung_tests_from_log has nothing to
# subtract from and records a dash for a parallel run.
PARALLEL_CASE="^Test case '[^']+' (passed|failed|skipped) on '"
PARALLEL_RUN_CLOSE='^\*\* TEST (SUCCEEDED|FAILED) \*\*'

# Each parallel case line of log $1 as `<state> <name>`, the name in the
# spelling the cells carry: an XCTest case prefixed with the test target and
# stripped of its `()` — the dotted spelling the serial reader produces and
# -only-testing: takes — and a swift-testing case as printed.
parallel_cases() {
  sed -n -E \
    -e "s#^Test case '([^'/]+)\(\)' (passed|failed|skipped) on '.*#\2 $TEST_TARGET.\1#p" \
    -e 't' \
    -e "s#^Test case '([^']+)' (passed|failed|skipped) on '.*#\2 \1#p" \
    "$1"
}

# The tally cell for a parallel run, in the spelling combine_tally gives a run
# of both frameworks, or nothing when the log is not one — no case lines — or
# the run never closed. $2 is how many tests the failing-names cell names,
# passed for the reason combine_tally takes it: the two cells describe one run.
parallel_tally() {
  local log=$1 named=${2:-0} close
  grep -qE "$PARALLEL_CASE" "$log" || return 0
  close=$(grep -E "$PARALLEL_RUN_CLOSE" "$log" | tail -n 1)
  [ -n "$close" ] || return 0
  parallel_cases "$log" | cases_tally "$named" "$close"
}

# The tally cell from `<state> <name>` lines on stdin — a parallel log's or a
# bundle's — in the spelling combine_tally gives a run of both frameworks. $1 is
# how many tests the failing-names cell names. Nothing when there are no lines.
#
# $2 is the run's own close marker, when the lines came from a log. A marker
# saying FAILED over lines in which no case failed is a log that lost the line
# that said so — which a parallel log can, see below — and is recorded as one
# failure rather than none: the verdict is the point, and a red run must never
# round down to green, which is the rule failures_in applies to a serial
# summary naming no count. A bundle passes no marker; it has lost nothing.
cases_tally() {
  local named=${1:-0} close=${2:-} counts
  counts=$(awk '
    { swift = index($2, "/") > 0 }
    swift  { sn++; if ($1 == "failed") sf++ }
    !swift { xn++; if ($1 == "failed") xf++ }
    $1 == "skipped" { skipped++ }
    END { if (NR) printf "%d %d %d %d %d", xn, sn, xf, sf, skipped }')
  [ -n "$counts" ] || return 0
  # shellcheck disable=SC2086
  set -- $counts
  case "$close" in
    *FAILED*) [ $(($3 + $4)) -eq 0 ] && set -- "$1" "$2" 1 "$4" "$5" ;;
  esac
  spell_tally "$1" "$2" "$3" "$4" "$5" "$named"
}

# --- The result bundle as the reader ------------------------------------------
#
# Parallel xcodebuild output is not line-atomic. Eleven clones write to one
# pipe, and a case line one of them is half-way through is cut by another's:
# the second parallel run's log held 4,929 lines saying `passed on` and 4,904 of
# them began with `Test case` — the other 25 were tails like
#
#   rBacklogApproveTests.testApproveDoesNotMarkDoneWhenTheMergeVerifyFails()' passed on …
#
# and the row read `✔ 4904 tests passed` over a run of 4,931. That is a green
# row 27 tests short, which nothing on it would have caught: a count that is
# merely lower reads as a suite somebody trimmed.
#
# The result bundle has no such problem — xcodebuild writes it from its own
# record of every case — and the row already names it: it is the provenance
# cell, on disk only because a run happened. So the bundle is read for the
# tally and the names whenever it can be, and the log only when it cannot: no
# bundle written (a build that died before testing), an xcresulttool that
# predates `get test-results`, or no python3 to parse its JSON with — python3
# being what every preflight check already runs under. The serial summaries,
# when a log has them, are still read first: a serial log is line-atomic, its
# summary is exact, and every row before the parallel scheme was read that way.
#
# Each case comes back as `<state> <name>` in the spelling the cells carry. The
# frameworks are told apart by the identifier URL, which keeps a swift-testing
# case's `()` and drops an XCTest case's; an XCTest case is prefixed with the
# bundle it ran in — KiteloopTests, or the package's KiteloopCoreTests — and
# spelled dotted, a swift-testing case as `Suite/name()`. An expected
# failure is a pass — XCTest does not count it against the run — and any other
# result xcresulttool names is carried as itself, so it counts as a test and as
# nothing else.
BUNDLE_CASES_READER='
import json, sys
target = sys.argv[1]
roots = json.load(sys.stdin).get("testNodes") or []
def walk(node, bundle):
    if node.get("nodeType") == "Unit test bundle":
        bundle = node.get("name") or bundle
    yield node, bundle
    for child in node.get("children") or []:
        yield from walk(child, bundle)
for node, bundle in (pair for root in roots for pair in walk(root, target)):
    if node.get("nodeType") != "Test Case":
        continue
    identifier = node.get("nodeIdentifier") or ""
    url = node.get("nodeIdentifierURL") or ""
    result = (node.get("result") or "unknown").lower()
    if result == "expected failure":
        result = "passed"
    if url.endswith("()"):
        name = identifier
    else:
        name = bundle + "." + identifier.replace("/", ".").removesuffix("()")
    print(result, name)
'

# The path of the bundle log $1 names, or nothing — result_bundle_from_log's
# reading with the directory kept.
bundle_path_from_log() {
  grep -oE '/[^[:space:]]+\.xcresult' "$1" | tail -n 1
}

# The cases in the `xcresulttool get test-results tests` listing on stdin, as
# `<state> <name>` — the pure half, so a test can drive it with a listing it
# wrote.
bundle_cases_in() {
  python3 -c "$BUNDLE_CASES_READER" "$TEST_TARGET" 2>/dev/null
}

# The cases of the bundle at $1, or nothing when there is no such bundle or it
# cannot be read here.
bundle_cases() {
  [ -n "$1" ] && [ -d "$1" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  xcrun xcresulttool get test-results tests --path "$1" --compact 2>/dev/null |
    bundle_cases_in
}

# The cases of the bundle log $1 names, if it names one this machine can read.
bundle_cases_for_log() {
  bundle_cases "$(bundle_path_from_log "$1")"
}

# The last line of $1 matching format $2, without the indentation xcodebuild
# writes its suite summaries with. Empty if that framework never reported.
last_summary() {
  grep -E "$2" "$1" | tail -n 1 | sed 's/^[[:space:]]*//'
}

# XCTest's run total for the log $1: the summary line that closes the outermost
# suite. Empty when a run suite was opened and never closed — a run that died
# mid-suite — and, for a log that names no run suite at all, the last summary
# line, which is what this read before there was anything better to anchor on.
xctest_run_total() {
  awk -v run_open="$XCTEST_RUN_OPEN" -v run_close="$XCTEST_RUN_CLOSE" \
      -v summary="$XCTEST_SUMMARY" '
    $0 ~ run_open  { in_run = 1; opened++; next }
    $0 ~ run_close { in_run = 1; closed++; closing = 1; next }
    $0 ~ summary   {
      if (closing) { total = $0; closing = 0 } else { last = $0 }
      next
    }
    END {
      if (!in_run) total = last
      else if (opened > closed) total = ""
      print total
    }
  ' "$1" | sed 's/^[[:space:]]*//'
}

# How many tests a summary line reports; 0 if it names no number.
tests_in() {
  local n
  n=$(printf '%s\n' "$1" | sed -n -E 's/.*(Executed|Test run with) ([0-9]+) test.*/\2/p')
  printf '%s' "${n:-0}"
}

# How many failures a summary line reports. XCTest writes `N failures`,
# swift-testing `N issues` — and nothing at all when it passed. A line that says
# it failed while naming no number counts as one: the verdict is the point, and a
# red run must never round down to green.
#
# The count is read wherever it sits, not only straight after `with`. XCTest
# writes `with 1 test skipped and 0 failures` when anything was skipped, and
# anchoring on `with` missed that line entirely — which dropped through to the
# `*fail*` fallback below, where the words `0 failures` matched and a green run
# was recorded as `✘ … 1 failure`. Every suite run with a skipped test read red.
failures_in() {
  local n
  n=$(printf '%s\n' "$1" | sed -n -E 's/.*[^0-9]([0-9]+) (failure|issue)s?([^a-z]|$).*/\1/p')
  if [ -n "$n" ]; then
    printf '%s' "$n"
    return
  fi
  case "$1" in
    *fail*) printf '1' ;;
    *) printf '0' ;;
  esac
}

# How many tests a summary line reports as skipped; 0 if it names none. XCTest
# counts a skipped test inside `Executed N tests` and then says so in the same
# clause failures_in reads past — `with 1 test skipped and 0 failures` — so
# without this the run where a block of tests opted out is recorded as
# `✔ N tests passed`, indistinguishable from the run where every one of them
# executed. That is precisely the "green because it never ran" reading
# docs/suite-status.md exists to make impossible: 46 lines in KiteloopTests
# mention XCTSkip, several conditional on a bindable port or an installed
# `claude` binary, so how much of the suite opted out is a property of the
# machine that ran it and belongs in the row.
#
# swift-testing's `Test run with N tests …` summary names no skips at all, so
# there is nothing to read from it and nothing to add: whatever this returns for
# a run is XCTest's count alone.
skips_in() {
  local n
  n=$(printf '%s\n' "$1" | sed -n -E 's/.*[^0-9]([0-9]+) tests? skipped.*/\1/p')
  printf '%s' "${n:-0}"
}

# "1 test" / "3038 tests" — the record is prose someone reads, not a field.
count_phrase() {
  if [ "$1" = 1 ]; then
    printf '%s %s' "$1" "$2"
  else
    printf '%s %ss' "$1" "$2"
  fi
}

# One tally cell from what the frameworks reported. With a single framework its
# line is passed through unchanged — there is nothing to combine, and the row
# should read as it always has. With both, the counts are added and each
# framework is named, and the cell reads failed if *either* framework failed,
# whatever the other one said.
#
# A run that skipped anything says so — `✔ 3058 tests passed (1 skipped) — …` —
# so a green row also tells you how much of the suite declined to run. The
# parenthesis is omitted entirely when nothing was skipped, which is the ordinary
# case: a cell reading `(0 skipped)` on every row would be noise, and the absence
# is the same statement. Only XCTest reports skips, so the count is XCTest's
# whole answer rather than a partial view of both frameworks'.
#
# $3 is how many tests the failing-names cell beside this one names, and a red
# cell spells it: `✘ 3362 tests, 1 failing test (2 failures) — …`. Both numbers
# are true and they are answers to different questions — XCTest's `N failures`
# counts assertions, and one test that fails twice reports two of them — but the
# row said only the second, so the row at 349e40d read `✘ 3362 tests, 2 failures`
# beside a names cell naming a single test. Nothing on it said they were
# different questions, and the reading it invites is that the names cell dropped
# one, which is exactly what the names cell was added to make impossible.
#
# The count comes from the reader that fills that cell rather than from a second
# pass over the log, so the two cannot drift apart: whatever the cell names, the
# tally counts.
#
# A red run naming no test at all — a framework that reported a failed verdict
# without ever printing a case, which is the log that records a dash in the names
# cell — keeps the old spelling. There is nothing to reconcile, and `0 failing
# tests` beside a failed verdict would be the round-down-to-green reading
# failures_in above refuses.
combine_tally() {
  local xctest=$1 swift=$2 named=${3:-0} xn sn xf sf skipped skips="" failures
  [ -n "$xctest" ] || { printf '%s' "$swift"; return; }
  [ -n "$swift" ] || { printf '%s' "$xctest"; return; }

  xn=$(tests_in "$xctest"); xf=$(failures_in "$xctest")
  sn=$(tests_in "$swift"); sf=$(failures_in "$swift")
  skipped=$(skips_in "$xctest")
  spell_tally "$xn" "$sn" "$xf" "$sf" "$skipped" "$named"
}

# The two-framework cell from its counts — XCTest tests and failures,
# swift-testing tests and failures, tests skipped, tests the names cell names.
# One spelling, so a parallel run and a serial one read alike in the record.
spell_tally() {
  local xn=$1 sn=$2 xf=$3 sf=$4 skipped=$5 named=${6:-0} skips="" failures
  [ "$skipped" -ne 0 ] && skips=" ($skipped skipped)"

  if [ $((xf + sf)) -eq 0 ]; then
    printf '✔ %s passed%s — %s XCTest, %s swift-testing' \
      "$(count_phrase $((xn + sn)) test)" "$skips" "$xn" "$sn"
  else
    failures=$(count_phrase $((xf + sf)) failure)
    [ "$named" -gt 0 ] && \
      failures="$(count_phrase "$named" 'failing test') ($failures)"
    printf '✘ %s, %s%s — %s XCTest (%s), %s swift-testing (%s)' \
      "$(count_phrase $((xn + sn)) test)" "$failures" "$skips" \
      "$xn" "$(count_phrase "$xf" failure)" \
      "$sn" "$(count_phrase "$sf" failure)"
  fi
}

# The tally cell for a finished run's log. Empty if no framework reported one —
# which includes the run that died before XCTest could total itself up.
tally_from_log() {
  local named cell cases
  named=$(failing_test_count_from_log "$1")
  cell=$(combine_tally "$(xctest_run_total "$1")" \
    "$(last_summary "$1" "$SWIFT_TESTING_SUMMARY")" "$named")
  if [ -z "$cell" ]; then
    cases=$(bundle_cases_for_log "$1")
    if [ -n "$cases" ]; then
      cell=$(printf '%s\n' "$cases" | cases_tally "$named")
    else
      cell=$(parallel_tally "$1" "$named")
    fi
  fi
  printf '%s' "$cell"
}

# --- Which tests failed ------------------------------------------------------
#
# A count is not an answer. `✘ 3058 tests, 2 failures` tells you the tree is red
# and nothing about what is red, and the names existed only in the log below —
# which is a mktemp file this script deletes on its way out, so the row sent you
# back to a four-minute run to learn what a passing glance at the output already
# knew. So the names go in the record too.
#
# Both frameworks are read, in one pass, so the cell is in the order the run
# reported them rather than grouped by whichever reader ran first:
#
#   XCTest         Test Case '-[KiteloopTests.FooTests testBar]' failed (0.1 seconds).
#   swift-testing  ✘ Test someTest() failed after 0.001 seconds with 1 issue.
#
# An XCTest name is rewritten from its ObjC selector spelling to
# KiteloopTests.FooTests.testBar — dotted, which is what -only-testing: takes,
# so a name in the cell can be pasted straight back into a narrowed re-run.
#
# `Test run with N tests … failed after …` is swift-testing's *run summary*, not
# a test, and it matches the same shape as a failing test — hence the branch
# that drops it first. Recording it would put "run with 18 tests in 2 suites"
# in the cell as though it were something you could go and look at.
#
# Names are deduplicated, keeping first appearance: XCTest prints a failing case
# once per suite it is reported under, and the same name twice in a cell says
# nothing the first one did not.
#
# The names come out one per line, and the cell and the tally's count of them are
# both taken from here. That is the point of the split: the tally says how many
# tests failed and the cell says which, so a second reader for the number would
# be a second answer to one question, free to disagree with the names sitting
# next to it.
#
# When neither spelling appears in a red run's log, xcodebuild's own trailing
# block is read instead — the tab-indented names it prints under `Failing
# tests:`, closed by the blank line before `** TEST FAILED **`:
#
#   Failing tests:
#   	NotificationStoreTests.testActionablePendingCountIgnoresAmbientTypes()
#
#   ** TEST FAILED **
#
# That is the run of 2026-08-13, which failed three tests and recorded a dash
# beside them, sending a reader back to a four-minute suite to learn what a
# glance at the output already knew. It is a fallback and never a union: the
# block spells a name `FooTests.testBar`, without the `KiteloopTests.` prefix
# the per-case reader produces, so merging the two would put one test in the
# cell twice under two spellings.
failing_test_names() {
  local names
  # The bundle first, for the reason given above it: a parallel log can have
  # lost the line that named a failure. A green bundle names none, and the log
  # readers below then find none either.
  names=$(bundle_cases_for_log "$1" | awk '$1 == "failed" { print substr($0, 8) }')
  [ -n "$names" ] || names=$(sed -n -E \
    -e '/Test run with/b' \
    -e "s/^.*Test Case '-\[([^][ ]+) ([^][]+)\]' failed.*/\1.\2/p" \
    -e "s#^Test case '([^'/]+)\(\)' failed on '.*#$TEST_TARGET.\1#p" \
    -e "s#^Test case '([^']+)' failed on '.*#\1#p" \
    -e 't' \
    -e 's/^.*Test (.+) failed after .*/\1/p' \
    "$1")
  [ -n "$names" ] || names=$(xcodebuild_failing_block "$1")
  printf '%s\n' "$names" | awk 'NF && !seen[$0]++'
}

# The names in xcodebuild's trailing `Failing tests:` block, in the order it
# printed them, with the `()` its spelling carries stripped. Only the indented
# lines are taken, so the blank line and the `** TEST FAILED **` that close the
# block cannot be mistaken for names of their own.
xcodebuild_failing_block() {
  sed -n -E \
    -e '/^Failing tests:/,/^\*\* TEST/{' \
    -e 's/^[[:space:]]+([^[:space:]].*)$/\1/p' \
    -e '}' \
    "$1" | sed -E 's/\(\)$//'
}

failing_tests_from_log() {
  local names
  names=$(failing_test_names "$1" | awk '{ printf "%s%s", sep, $0; sep = ", " }')
  # The dash is the recorded cell for a green run, and for a run that died
  # before any test could fail. It belongs here rather than at the call site so
  # that what the row will say is what the tests can assert.
  printf '%s' "${names:-—}"
}

# How many tests that cell names — the number the tally spells beside the
# failure total. Zero for a run that named none, which is the dash above.
failing_test_count_from_log() {
  failing_test_names "$1" | awk 'END { print NR }'
}

# --- Which tests skipped -----------------------------------------------------
#
# `(1 skipped)` in the tally says how much of the suite opted out and nothing
# about which part of it did, and the two readings are not interchangeable: 47
# XCTSkip sites live in KiteloopTests, most of them conditional on a free
# loopback port for the control server and two on an installed `claude` binary.
# So one row's skip is an expected opt-out on a busy machine and the next row's
# is a control-server endpoint whose coverage silently went missing — the same
# eleven characters either way. The names are the difference, and like the
# failing ones they lived only in the log this script deletes on its way out.
#
# XCTest writes them in the same shape as a failure, and they are read the same
# way — selector rewritten to the dotted spelling `-only-testing:` takes, so a
# name can be pasted straight into a narrowed re-run to see why it opted out:
#
#   Test Case '-[KiteloopTests.HTTPServerTests testBinds]' skipped (0.001 seconds).
#
# Only XCTest is read, because only XCTest is counted: swift-testing's run
# summary names no skips, so skips_in above reports XCTest's number alone and a
# swift-testing name in this cell would be a name the count beside it does not
# include.
#
# Names are deduplicated, keeping first appearance, for the same reason as the
# failing cell: XCTest reports a case once per suite it is nested under.
skipped_tests_from_log() {
  local names
  # The bundle first, as for the failing cell.
  names=$(bundle_cases_for_log "$1" | awk '$1 == "skipped" { print substr($0, 9) }')
  [ -n "$names" ] || names=$(sed -n -E \
    -e "s/^.*Test Case '-\[([^][ ]+) ([^][]+)\]' skipped.*/\1.\2/p" \
    -e "s#^Test case '([^'/]+)\(\)' skipped on '.*#$TEST_TARGET.\1#p" \
    -e "s#^Test case '([^']+)' skipped on '.*#\1#p" \
    "$1")
  names=$(printf '%s\n' "$names" | awk 'NF && !seen[$0]++ { printf "%s%s", sep, $0; sep = ", " }')
  # A dash for a run that skipped nothing, matching the failing cell beside it:
  # an empty field reads as a column somebody forgot to fill in.
  printf '%s' "${names:-—}"
}

# --- Which test hung ----------------------------------------------------------
#
# The one failure mode SUITE_TIMEOUT_SECONDS exists for, and the one the record
# could not describe. A run ended at the ceiling reports no summary and fails no
# test, so both readers above come back with nothing and the row recorded a dash
# in each: the row at 3eaccf6a says a run was ended at its 1800s limit and names
# nothing, and which test it sat on lived only in the kept output and in a commit
# message somebody typed. The row is this repository's standing answer to what
# the suite last did, and for the case the ceiling was added to catch it said
# that the run stopped without saying what it stopped on.
#
# A hung test is not a reported one, so it is read by subtraction rather than by
# a line of its own: XCTest opens every case with
#
#   Test Case '-[KiteloopTests.HookEngineTests testTimeout]' started.
#
# and closes it with a `passed`, `failed` or `skipped` line carrying the same
# name. Whatever was open when the build was killed never got its close, and that
# is the case the run was in when the ceiling fired — usually one, but a build
# ended mid-flight can leave several open, and all of them are named.
#
# The spelling, the first-appearance dedup and the dash-for-none are the failing
# and skipped cells' exactly, so the cell reads like its neighbours and a name in
# it can be pasted straight into a narrowed re-run — which, for a test that
# hangs, is the whole of reproducing it. Only XCTest is read, for the reason the
# skipped cell reads only XCTest: swift-testing announces no per-case start, so
# there is nothing to subtract from.
hung_tests_from_log() {
  local names
  names=$(sed -n -E \
    -e "s/^.*Test Case '-\[([^][ ]+) ([^][]+)\]' (started|passed|failed|skipped).*/\3 \1.\2/p" \
    "$1" |
    awk '
      { state = $1; name = substr($0, length(state) + 2) }
      # XCTest announces a case once per suite it is nested under, opening and
      # closing it each time, so `open` is a state and `order` records where the
      # name was first seen — a case that hung is one name, said once, in the
      # place the run first mentioned it.
      state == "started" {
        if (!(name in open)) order[++n] = name
        open[name] = 1
        next
      }
      { open[name] = 0 }
      END { for (i = 1; i <= n; i++) if (open[order[i]]) print order[i] }
    ' | awk '{ printf "%s%s", sep, $0; sep = ", " }')
  # A dash when the ceiling fired before any case had started — a build wedged in
  # compilation, which is the other shape this catches and has no test to name.
  printf '%s' "${names:-—}"
}

# --- Provenance --------------------------------------------------------------
#
# Every other cell of a record is something a person can simply type. On
# 2026-08-11 a worker did: an item about the grounding index appended a row
# claiming 3,077 tests passed at c6f6f49, and it read like a real measurement
# because the number was plausible and no cell in it could only have come from a
# run. No run had happened — the app was up the whole time, and this script
# refuses then and writes nothing — but `--last` reported the row as the newest
# record, which is the file being used exactly as designed to return an answer
# nobody measured.
#
# So a record also names the result bundle xcodebuild wrote for the run:
# Test-Kiteloop-2026.08.10_13-13-24--1000.xcresult. xcodebuild chooses that name
# itself, from the wall clock at the moment testing starts, and the bundle exists
# on disk only because a build ran. A row someone typed either leaves the cell
# empty or names a bundle that is nowhere to be found:
#
#   find ~/Library/Developer/Xcode/DerivedData -name '<the cell>'
#
# That does not make fabrication impossible; it makes it checkable, which is what
# a record can offer. The other cells say what the run found. This one says the
# run happened.

# The bundle xcodebuild named in log $1, without its directory. The last path in
# the log wins: a run that dies early writes an error bundle to TMPDIR and prints
# that one instead, which is still this run's bundle and still evidence it ran.
# Empty if the output names none at all, which the caller records as such rather
# than leaving the cell to be read as a name.
result_bundle_from_log() {
  local path
  path=$(grep -oE '/[^[:space:]]+\.xcresult' "$1" | tail -n 1)
  printf '%s' "${path##*/}"
}

# --- How long it took ---------------------------------------------------------
#
# Every other cell says what the run found; none of them says what it cost. "Is
# the suite getting slower?" was therefore answerable only from somebody's memory
# of the last time they watched it scroll, which is not a measurement — and this
# file exists precisely so that the answers to questions about the suite come out
# of the repository instead.
#
# Seconds, with the unit on them, rather than a `4m 14s` phrase: two rows are
# compared far more often than one is read on its own, and 254 against 301 is a
# comparison you can make at a glance where 4m 14s against 5m 1s is arithmetic.

# The elapsed cell for a run that started at epoch $1 and came back at $2.
#
# A negative difference is recorded as 0 rather than passed through. The clock
# can step backwards mid-run — ntpd, or a laptop coming back from sleep with a
# corrected time — and `-3s` is not a reading of anything; the run happened, and
# how long it took is simply no longer knowable from these two stamps.
duration_cell() {
  local elapsed=$(($2 - $1))
  [ "$elapsed" -lt 0 ] && elapsed=0
  printf '%ss' "$elapsed"
}

# The package's own tally cell — Kiteloop/KiteloopCore's, read out of what
# scripts/run-core-tests.sh printed for itself on this run ($1, the whole of
# its captured output) rather than out of anything this script measured on its
# own. That script closes a clean run with one line, `OK: KiteloopCore — …`,
# naming XCTest's own tally the way the rest of this file already trusts —
# taking the last such line, the way every other reader in this file resolves
# a duplicate rather than the first.
#
# A dash — read the way every other unreadable tally in this record is, rather
# than an empty cell nobody can tell from a row predating the column — for a
# red run, which prints `FAIL: …` instead and closes no `OK:` line to read; and
# for a green run that closed one naming no tally of its own, `no XCTest tally
# printed`, which is what a run whose outermost suite never closed leaves for
# scripts/run-core-tests.sh to print about itself.
core_tally_from_output() {
  local line tally
  line=$(printf '%s\n' "$1" | grep -E '^OK: KiteloopCore — ' | tail -n 1)
  tally=${line#OK: KiteloopCore — }
  case "$tally" in
    ''|'no XCTest tally printed') printf '—' ;;
    *) printf '%s' "$tally" ;;
  esac
}

# Whether the record's last byte is a newline.
#
# `tail -c 1` under command substitution: a trailing newline is stripped there,
# so a properly terminated file reads back as the empty string and any other
# last byte reads back as itself. A read that cannot answer says no, so the
# newline goes in — the two mistakes are not the same size, and this is the same
# call the Swift side makes for the JSONL ledgers (`AtomicFileWriter.append`).
ends_in_newline() {
  local last
  last=$(tail -c 1 -- "$1" 2>/dev/null) || return 1
  [ -z "$last" ]
}

# Append one line, whatever xcodebuild exited with. A red run is a measurement
# too, and writing only the green ones would leave the newest record reading
# green while the tree is not.
#
# The row starts on a line of its own even when the record does not end in one. A
# file can lose its final byte — a hand edit, a partial write, a copy that
# dropped it — and a row appended onto that truncated line becomes part of it:
# table_rows matches the merged line once, and show_last reads the *older* row's
# cells out of it. The newest measurement is then in the file and invisible to
# --last, on the one file that is this repository's standing answer to "is the
# suite green, and at what commit?". A blank line costs nothing; a missing one
# costs a whole row.
append_record() {
  local record=$1 when=$2 commit=$3 tree=$4 tally=$5 exit_status=$6 bundle=$7 failing=$8
  local skipped=$9 duration=${10} core_tally=${11}
  if [ ! -e "$record" ]; then
    cat >"$record" <<'HEADER'
# Suite status

One line per `scripts/run-unit-suite.sh` run, appended by the script itself —
nothing else may write here. Red runs are recorded too.
`./scripts/run-unit-suite.sh --last` prints the newest row and how many commits
HEAD has moved since it.

This file is an instrument reading, not documentation. A row means a suite run
happened, and the only thing entitled to say so is the thing that ran it: a hand
edit here is a blocking review finding unless the item is about this recording
mechanism — see the reviewer rubric in `CLAUDE.md`.

The result bundle cell is the bundle xcodebuild wrote for that run. It is named
from the wall clock when testing started and exists only because a build ran, so
a row nobody measured is the row you cannot find a bundle for:

```bash
find ~/Library/Developer/Xcode/DerivedData -name '<the cell>'
```

The failing tests cell names the tests that failed, so a red row says what is red
without a re-run; the skipped tests cell names the ones that opted out, so a
green row says which coverage was absent rather than only how much. Either is a
dash when there were none. The names are spelled as `-only-testing:` takes them.

On a row whose tally says the run was ended at its time limit, the failing tests
cell names the tests that were still in flight when the ceiling fired — cases
that started and never came back, which is what that run hung on. Nothing failed
on such a row, so `--last` prints those names under `hung` rather than `failing`.
It is a dash when the ceiling fired before any test had started.

The duration cell is how long the run took, in seconds — so how much the suite
costs, and whether it is growing, is read off the rows rather than remembered.

The package tally cell is Kiteloop/KiteloopCore's own count, from the same run's
`scripts/run-core-tests.sh` preflight entry — the host-less package's tests,
which xcodebuild never touches and the tally cell above never counts, so a test
moving from KiteloopTests into the package used to read as a test lost rather
than a test relocated. A dash when that entry named no tally of its own.

| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration | package tally |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
HEADER
  fi
  # A no-op on the file the branch above just wrote, which ends in a newline of
  # its own; this is for the record that was already there.
  if [ -s "$record" ] && ! ends_in_newline "$record"; then
    printf '\n' >>"$record"
  fi
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$when" "$commit" "$tree" "$tally" "$exit_status" "$bundle" "$failing" "$skipped" \
    "$duration" "$core_tally" >>"$record"
}

# --- What the script exits with ----------------------------------------------
#
# xcodebuild's status is not on its own an answer to "did the suite pass?". A run
# that matched no tests — a scheme or an -only-testing: that selects nothing, a
# run that stopped before testing began — can exit 0 with no framework summary in
# its output at all, and then the empty tally and the zero status say opposite
# things: nothing was measured, and everything is fine. Anything reading the exit
# status gets the second one, including a person watching it scroll past. That is
# the "green because it never ran" reading the whole preflight exists to prevent,
# arriving through the exit code instead.
#
# So the script's own verdict is xcodebuild's status *and* whether a tally was
# read: zero over an empty tally exits NO_TALLY_STATUS instead. Everything else
# passes through untouched, so a red run still reports its own code — 65 from a
# test failure stays 65 rather than being flattened into this one — and a green
# run that measured something still exits 0.
#
# This is the verdict, not the instrument reading. The `exit` cell of a record
# keeps carrying what xcodebuild itself returned, so a row still says what the
# run did rather than what this script concluded about it.
NO_TALLY_STATUS=70

exit_status_for() {
  local status=$1 tally=$2
  if [ "$status" -eq 0 ] && [ -z "$tally" ]; then
    printf '%s' "$NO_TALLY_STATUS"
  else
    printf '%s' "$status"
  fi
}

# --- Is Kiteloop running? ----------------------------------------------------
#
# The refusal is only as good as the answer it acts on, and pgrep gives three: 0
# when it matched, 1 when nothing matched, and something else when it could not
# look at all — 2 for a usage error, 3 for a fatal one, 127 for a pgrep that is
# not on PATH. Written as `if pgrep … >/dev/null 2>&1` only the first is
# distinguished: every other status falls to the else branch, so "I could not
# tell" reads as "the app is down" and the suite starts. The `2>/dev/null` then
# throws away the one thing that would have said which of the two it was.
#
# That is not a hypothetical reading of the code. On 2026-08-11 a full run was
# recorded at 00:24:03 — commit bf9dd36, 3,364 tests, with a
# Test-Kiteloop-2026.08.11_00-24-05 bundle on disk, so the run certainly
# happened — while Kiteloop had been up continuously since 23:33:52. Run by hand
# a few minutes later the guard refused correctly, and the pattern matches the
# running Release binary, so the pattern is not what failed. What pgrep actually
# said that time is not recoverable, because this script discarded it.
#
# The app survived, which is luck to record rather than a property to rely on —
# possibly only because the running app was the Release build and the XCTest host
# is Debug, a different bundle path than the collision of 2026-08-04, when macOS
# terminated the running instance and stranded two in-flight items.
#
# So "could not tell" is its own outcome and refuses exactly as a match does, and
# what pgrep said is printed rather than discarded: a guard that cannot say why
# it could not look is the one that fails this way twice.

# Which of pgrep's three answers an exit status is. Kept apart from running
# pgrep so each answer can be asserted without a process list to arrange.
guard_verdict() {
  case "$1" in
    0) printf 'running' ;;
    1) printf 'not-running' ;;
    *) printf 'unknown' ;;
  esac
}

# Ask the process list about the app, leaving the status in guard_status and
# whatever pgrep said for itself in guard_output. stdout — the pids, which
# nothing here needs — is dropped; stderr is kept, because on the unknown branch
# it is the entire explanation. A pgrep that is not on PATH lands here too, as
# the shell's own 127 and its own message, so "verify pgrep is usable" needs no
# separate look: failing to run it is one of the answers.
#
# `-a` because BSD pgrep leaves its own ancestors out of the match by default,
# and the one shell this guard exists for — a worker the app spawned, running
# inside an autopilot run — descends from Kiteloop. Without it that shell asks
# "is Kiteloop running" and hears "no" (execution D7913B58, 2026-09-07: the
# suite ran inside a run and launched a second Kiteloop as its host).
probe_kiteloop() {
  guard_output=$(pgrep -a -f "$KITELOOP_PATTERN" 2>&1 >/dev/null)
  guard_status=$?
}

refuse_running() {
  cat >&2 <<'REFUSAL'
run-unit-suite: Kiteloop is running — quit it first.

KiteloopTests is hosted by Kiteloop.app, so running the suite launches a second
Kiteloop as the XCTest host and macOS terminates the one already running, along
with any autopilot run inside it. Nothing was started.

Quit Kiteloop and re-run this script. To compile the test bundles without
launching a host — safe while the app is up — use:

  xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build-for-testing
REFUSAL
}

# The refusal for an answer that was never given. It prints the status and what
# pgrep said, indented, because the cause is the actionable part — a missing
# binary, a restricted process list and a mistyped pattern all arrive here and
# are fixed differently. A pgrep that explained nothing is said in so many words
# rather than left as a blank space where the reason should be.
refuse_unknown() {
  local status=$1 output=$2
  cat >&2 <<REFUSAL
run-unit-suite: cannot tell whether Kiteloop is running — nothing was started.

pgrep exited $status, which is neither a match (0) nor a clean "nothing
matched" (1), so the process list was never read and this script has no evidence
the app is down.
REFUSAL
  if [ -n "$output" ]; then
    printf '\npgrep said:\n\n' >&2
    printf '%s\n' "$output" | sed 's/^/  /' >&2
  else
    printf '\npgrep printed nothing to say why.\n' >&2
  fi
  cat >&2 <<'REFUSAL'

An answer that is not "no" cannot stand in for one. KiteloopTests is hosted by
Kiteloop.app, so a suite started while the app is up launches a second Kiteloop
as the XCTest host and macOS terminates the one already running, along with any
autopilot run inside it. Fix pgrep — or quit Kiteloop and satisfy yourself it is
down — and re-run.

To compile the test bundles without launching a host — safe either way — use:

  xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build-for-testing
REFUSAL
}

# --- Can this machine be held awake? -----------------------------------------
#
# caffeinate ships with macOS, so the answer is yes everywhere this suite is
# meant to run. It is asked anyway, because a run that cannot hold the assertion
# is still a run worth taking: the alternative — refusing, or letting the shell
# report a missing command in the middle of the output — trades a measurement for
# a convenience. What such a machine loses is the guarantee that the wall clock
# the ceiling is measuring is time the build was actually running.
have_caffeinate() {
  command -v caffeinate >/dev/null 2>&1
}

# Sourcing this file defines its functions and does nothing else — which is how
# scripts/test-run-unit-suite.sh exercises the tally reader above without a
# build, a process list or a record. Executing it falls through to the options.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

dry_run=0
last=0
flakes=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --last) last=1 ;;
    --flakes) flakes=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'run-unit-suite: unknown option %s\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

# --dry-run answers before anything else happens: no process list is read, no
# build starts. It exists to make the command inspectable — the docs quote what
# it prints, so a drift between the two is visible instead of theoretical.
if [ "$dry_run" -eq 1 ]; then
  command_line
  printf 'timeout: %ss — xcodebuild is ended, and the row it would have written recorded as such, if it runs past this\n' \
    "$SUITE_TIMEOUT_SECONDS"
  printf 'idle:    %ss — the same, if it prints nothing for this long: a host that has stopped mid-suite\n' \
    "$SUITE_IDLE_SECONDS"
  # Said beside the ceiling because it is what keeps the ceiling measuring the
  # build rather than the machine: a Mac that sleeps under a run is charged the
  # sleeping time too. Neither line is a command — the list above stays the nine
  # things that run — and asking whether caffeinate is here starts nothing, so
  # --dry-run answers as it always did.
  if have_caffeinate; then
    printf 'power:   caffeinate -i -s holds an idle- and system-sleep assertion for as long as xcodebuild runs, so a Mac left alone does not sleep into that ceiling\n'
  else
    printf 'power:   no caffeinate on this machine, so nothing holds the Mac awake — a run it sleeps through is charged the sleeping time against that ceiling\n'
  fi
  exit 0
fi

# The repo root is resolved from where the *script* lives, not the caller's
# directory, so the result is the same from the root, from a subdirectory, or
# from outside the checkout entirely.
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$root" ]; then
  printf 'run-unit-suite: %s is not inside a git checkout.\n' "$script_dir" >&2
  exit 1
fi

record="$root/$RECORD_RELPATH"

# Like --dry-run, --last answers before the pgrep check, so it starts nothing.
if [ "$last" -eq 1 ]; then
  show_last "$record"
  exit 0
fi

# --flakes reads the whole record, the same way --last reads its newest row, so
# it answers before the pgrep check too and starts nothing.
if [ "$flakes" -eq 1 ]; then
  show_flakes "$record"
  exit 0
fi

# Two of pgrep's three answers stop here, and only the third — a clean "nothing
# matched" — is permission to build.
probe_kiteloop
case "$(guard_verdict "$guard_status")" in
  running) refuse_running; exit 1 ;;
  unknown) refuse_unknown "$guard_status" "$guard_output"; exit 1 ;;
esac

# Preflight: the checks that decide whether a measurement would mean anything. A
# .swift file that is not a member of its target is invisible to xcodebuild — it
# compiles nowhere, so the suite comes back green without it — and a tally reader
# that has stopped reading xcodebuild's output correctly writes the wrong row for
# a run that did happen. Checking those first means the tally below describes
# every test file on disk and describes it accurately. The third holds the
# control harness's --json contract, and the last three the features map, its own
# reading of it and the release readers — all of them read by machines or by
# people rather than by
# xcodebuild, and each failing the same way here as it would anywhere: before a
# build, cheaply, instead of at the moment a release is being cut. A failure exits
# with that command's own status and appends no record: no suite ran, so there is
# nothing to have measured.

# The package's own tally, read off scripts/run-core-tests.sh's entry alone —
# a dash until that entry runs, which is every row this loop could still exit
# before reaching it.
core_tally="—"
for preflight_entry in "${PREFLIGHT[@]}"; do
  preflight_argv=($preflight_entry)
  if [ "${preflight_argv[0]}" = "scripts/run-core-tests.sh" ]; then
    # Captured rather than left to stream straight to the terminal, so its
    # closing tally line can be read into the row this run will append —
    # then printed back verbatim, so the terminal reads exactly as it always
    # has.
    core_tests_output=$("$root/${preflight_argv[0]}" "${preflight_argv[@]:1}" 2>&1)
    preflight_status=$?
    printf '%s\n' "$core_tests_output"
    core_tally=$(core_tally_from_output "$core_tests_output")
  else
    "$root/${preflight_argv[0]}" "${preflight_argv[@]:1}"
    preflight_status=$?
  fi
  if [ "$preflight_status" -ne 0 ]; then
    printf '\nrun-unit-suite: preflight failed (%s) — the suite was not run.\n' \
      "${preflight_argv[0]}" >&2
    exit "$preflight_status"
  fi
done

# What the record will say the suite was measured against, captured before the
# run rather than after it, so the commit and the clean/dirty state are the tree
# xcodebuild actually saw.
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The same instant as an epoch stamp, taken beside the one the row carries rather
# than parsed back out of it: `date -d` and BSD `date -j -f` disagree about how
# to read an ISO timestamp, and the second reading could only ever be a worse
# copy of the first.
started_epoch=$(date -u +%s)
head_commit=$(head_commit_cell)
worktree_state=$(code_worktree_state)

cd "$root/Kiteloop" || exit 1

log=$(mktemp -t run-unit-suite) || exit 1
trap 'rm -f "$log"' EXIT

# xcodebuild runs in the background, writing straight to $log, so the loop
# below can end it once it outlives SUITE_TIMEOUT_SECONDS — macOS ships no
# coreutils timeout(1) to reach for instead. A live view is mirrored to the
# terminal by tail rather than by piping through tee: $! needs to be
# xcodebuild's own pid, since that is what has to be signalled, and a pipe's
# $! is its last command's pid instead — and reading $log the moment
# xcodebuild's own process ends is safe only because xcodebuild is what wrote
# it directly, with nothing downstream still holding output back.
#
# Job control is turned on for just this one line so bash makes the job its
# own process group, with $build_pid as its leader — that is what lets a
# timed-out build be ended as a group below instead of as a lone pid, which
# reaches only xcodebuild itself and leaves anything it spawned reparented and
# still running. `set +m` turns job control back off immediately after, so
# tail and the watchdog sleep are ordinary children, not jobs of their own.
set -m
"${XCODEBUILD[@]}" >"$log" 2>&1 &
build_pid=$!
set +m

# Keep the Mac awake for exactly as long as that build is up. A suite run is
# nine unattended minutes of nothing anyone has to touch, which is also the
# shape of a machine deciding it is idle: the run then sleeps with it, and the
# sleeping wall clock is charged against SUITE_TIMEOUT_SECONDS, so the ceiling
# ends a build that was never wedged and the row says it outran its time limit.
#
# `-w "$build_pid"` rather than launching the build under caffeinate: $build_pid
# has to stay xcodebuild's own pid, since the timeout arm signals its process
# group and the wait below reports its status, and caffeinate wrapping the
# command would make both of those caffeinate's instead. It is started after
# `set +m` so it is an ordinary child rather than a job of its own, and it needs
# no tending here — `-w` releases the assertion when that pid goes away, whether
# the build finished, was ended at the ceiling, or this script died without
# reaping anything.
if have_caffeinate; then
  caffeinate -i -s -w "$build_pid" >/dev/null 2>&1 &
fi

tail -n +1 -f "$log" &
tail_pid=$!

sleep "$SUITE_TIMEOUT_SECONDS" &
watchdog_pid=$!

# Monitor mode notifies the terminal of a job's own state change (built by
# name, e.g. "Terminated: 15") asynchronously, the moment the shell next gets
# a chance to notice it — which lands here rather than in $log, since that
# redirection covers only what the job itself writes. Swallowed by redirecting
# this script's own stderr until the final wait below has reaped $build_pid,
# so it never reaches the run's own output; `wait "$build_pid" 2>/dev/null`
# alone would not do it; the notice can land on an earlier checkpoint too, so
# the window has to cover the whole watchdog dance rather than just that call.
exec 3>&2 2>/dev/null

# Poll until one of the two ends — there is no coreutils timeout(1) here, and
# no `wait -n` either, which is a bash newer than the one macOS ships as
# /bin/bash. A one-second poll is coarse beside a ceiling meant in tens of
# minutes and fine beside the few-second one a guard test drives it with.
# The idle ceiling is read off the log: a second with no growth is a second of
# silence, and SUITE_IDLE_SECONDS of them in a row is a wedge — ended the same
# way as the outer ceiling, recorded as its own shape.
went_idle=0
idle_for=0
last_size=$(wc -c <"$log" 2>/dev/null || printf '0')
while kill -0 "$build_pid" 2>/dev/null && kill -0 "$watchdog_pid" 2>/dev/null; do
  sleep 1
  size=$(wc -c <"$log" 2>/dev/null || printf '0')
  if [ "$size" = "$last_size" ]; then
    idle_for=$((idle_for + 1))
    if [ "$idle_for" -ge "$SUITE_IDLE_SECONDS" ]; then
      went_idle=1
      break
    fi
  else
    idle_for=0
    last_size=$size
  fi
done

[ "$went_idle" -eq 1 ] && sample_test_hosts "$started_at" 2>&3

timed_out=0
if kill -0 "$build_pid" 2>/dev/null; then
  # The ceiling won the race and the build is still going: end it. TERM
  # first, with up to two seconds to notice it before KILL for whatever did
  # not — sent to the process group ("-$build_pid"), not just the pid, so
  # anything xcodebuild spawned goes with it rather than being reparented and
  # left running.
  timed_out=1
  kill -TERM -"$build_pid" 2>/dev/null
  for _ in 1 2; do
    kill -0 "$build_pid" 2>/dev/null || break
    sleep 1
  done
  kill -KILL -"$build_pid" 2>/dev/null
fi
# The watchdog is nothing more than a sleep: still running when the build won
# the race or went idle before the ceiling, already gone when the ceiling won.
# Ending it here is the whole of not leaving it running for the rest of its own
# ceiling after this script has already returned — or waiting it out below.
kill "$watchdog_pid" 2>/dev/null
wait "$watchdog_pid" 2>/dev/null

wait "$build_pid"
status=$?
# Restore this script's own stderr now that $build_pid has been reaped —
# nothing left to notify about.
exec 2>&3 3>&-
# The other end of the measurement, taken here rather than after the readers
# below, so the cell is how long xcodebuild took and not how long this script
# spent afterwards grepping its output.
finished_epoch=$(date -u +%s)

# xcodebuild is done and $log already holds everything it wrote. The tail
# mirroring it to the terminal is a courtesy rather than a source of record —
# it does not exit on its own at EOF, which is the point of -f, so nothing
# else will stop it.
kill "$tail_pid" 2>/dev/null
wait "$tail_pid" 2>/dev/null

# The tally is the answer the caller came for; the exit status alone does not
# distinguish "did not build" from "built and three assertions failed" — nor,
# once two frameworks report, which of them the failures were in.
tally=$(tally_from_log "$log")
printf '\n'
if [ "$timed_out" -eq 1 ] && [ "$went_idle" -eq 1 ]; then
  tally=""
  printf 'run-unit-suite: xcodebuild printed nothing for %ss — a wedged run, ended (exited %s).\n' \
    "$SUITE_IDLE_SECONDS" "$status"
elif [ "$timed_out" -eq 1 ]; then
  # Whatever a suite that closed before the hang left in the log is not this
  # run's answer — the run that mattered never finished, so the tally says
  # that instead of whatever fragment survives it.
  tally=""
  printf 'run-unit-suite: xcodebuild ran past its %ss time limit — ended (exited %s).\n' \
    "$SUITE_TIMEOUT_SECONDS" "$status"
elif [ -n "$tally" ]; then
  printf '%s\n' "$tally"
else
  printf 'run-unit-suite: no test tally in the output — no framework reported a summary, so nothing was measured (xcodebuild exited %s).\n' "$status"
fi

bundle=$(result_bundle_from_log "$log")
failing=$(failing_tests_from_log "$log")
skipped=$(skipped_tests_from_log "$log")

if [ "$timed_out" -eq 1 ] && [ "$went_idle" -eq 1 ]; then
  recorded_tally=$(idle_tally_cell "$SUITE_IDLE_SECONDS")
  recorded_failing=$(hung_tests_from_log "$log")
elif [ "$timed_out" -eq 1 ]; then
  recorded_tally=$(timeout_tally_cell "$SUITE_TIMEOUT_SECONDS")
  # Nothing failed in a run that was ended — the failing reader has nothing to
  # find and the cell would be a dash — so the names the row carries are the
  # cases that never came back. $failing itself is left as it is, because
  # run_output_is_worth_keeping below decides on it and this run is kept on its
  # status alone; the swap is to the row, not to the reading.
  recorded_failing=$(hung_tests_from_log "$log")
else
  recorded_tally=${tally:-$NO_TALLY_CELL}
  recorded_failing=$failing
fi

append_record "$record" "$started_at" "$head_commit" "$worktree_state" \
  "$recorded_tally" "$status" \
  "${bundle:-none named in the output}" "$recorded_failing" "$skipped" \
  "$(duration_cell "$started_epoch" "$finished_epoch")" "$core_tally" \
  && printf 'Recorded in %s.\n' "$RECORD_RELPATH" \
  || printf 'run-unit-suite: could not write %s.\n' "$RECORD_RELPATH" >&2

# The record says what this run found; for a run that did not come back clean it
# cannot say why, and until now nothing could — the log below is removed by the
# EXIT trap a few lines from here and the bundle it names is gone from
# DerivedData within a day. So keep the output while it still exists. The trap is
# left exactly as it was: this is a copy, and the mktemp file is still cleaned up.
if run_output_is_worth_keeping "$status" "$tally" "$failing"; then
  kept_log=$(suite_log_path "$started_at")
  if keep_suite_log "$log" "$started_at"; then
    printf 'Full output kept at %s\n' "$kept_log"
  else
    printf 'run-unit-suite: could not keep the run output at %s.\n' "$kept_log" >&2
  fi
fi

final_status=$(exit_status_for "$status" "$tally")
if [ "$final_status" -eq 0 ]; then
  # This run's own bundle, if xcodebuild named one — read the same way the
  # row's own bundle cell is, so the gate and the row can never name two
  # different runs. Empty when the log named none, which leaves the entry
  # below to run exactly as it always has.
  postflight_bundle=$(bundle_path_from_log "$log")
  for postflight_entry in "${POSTFLIGHT[@]}"; do
    postflight_argv=($postflight_entry)
    case "${postflight_argv[0]}" in
      quality/bin/check-crap.py|scripts/export-coverage-lcov.py)
        [ -n "$postflight_bundle" ] && postflight_argv+=(--bundle "$postflight_bundle") ;;
    esac
    if ! (cd "$root" && "${postflight_argv[@]}"); then
      printf 'run-unit-suite: postflight failed (%s) — the row above stands; the gate is red.\n' "${postflight_argv[0]}" >&2
      final_status=1
    fi
  done
fi
exit "$final_status"
