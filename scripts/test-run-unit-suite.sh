#!/bin/bash
# test-run-unit-suite — assert the readers in scripts/run-unit-suite.sh that turn
# xcodebuild's output into a suite record: the tally, the result bundle that says
# the run happened, and the names of the tests that failed — and the guard that
# decides whether a run may start at all.
#
# The tally is the cell of a suite record the script computes rather than
# copies, and it is the cell that was wrong: KiteloopTests reports under two
# frameworks and only the last one to speak was recorded, so a run of 3,038
# XCTest cases went into docs/suite-status.md as "18 tests" — and a red XCTest
# run would have gone in the same way, reading passed, because the exit column
# comes from xcodebuild and the tally from a line that never mentioned those
# cases.
#
# These cases are that bug and its neighbours, run against synthetic logs. They
# source run-unit-suite.sh, which defines its functions and stops when sourced,
# so nothing here builds, reads the process list or writes a record — it is safe
# while Kiteloop is running, which is when you are most likely to touch it. That
# same sourcing guard is why run-unit-suite.sh can run this file as a preflight
# without recursing, which it does: these cases run whenever the suite is
# measured, and a broken tally reader stops the run before a build starts rather
# than recording a wrong row for a run that did happen.
#
#   ./scripts/test-run-unit-suite.sh

set -u

here=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
# shellcheck source=run-unit-suite.sh
. "$here/run-unit-suite.sh"

tmp=$(mktemp -d -t test-run-unit-suite) || exit 1
trap 'rm -rf "$tmp"' EXIT

failed=0

check() {
  local name=$1 expected=$2 actual=$3
  if [ "$actual" = "$expected" ]; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s\n          expected: %s\n          actual:   %s\n' \
      "$name" "$expected" "$actual"
    failed=$((failed + 1))
  fi
}

# The cell a log with this content on stdin would be recorded with — the whole
# production path, from grep to combined line, not a re-implementation of it.
tally_for() {
  cat >"$tmp/log"
  tally_from_log "$tmp/log"
}

# Likewise for the provenance cell: the bundle name a log with this content
# would be recorded with.
bundle_for() {
  cat >"$tmp/log"
  result_bundle_from_log "$tmp/log"
}

# And for the failing-tests cell — including the dash a green run records, which
# is why this drives the reader rather than checking a name list.
failing_for() {
  cat >"$tmp/log"
  failing_tests_from_log "$tmp/log"
}

# And for the skipped-tests cell, the same way and for the same reason.
skipped_for() {
  cat >"$tmp/log"
  skipped_tests_from_log "$tmp/log"
}

# And for the cell a run ended at its ceiling records in the failing column: the
# tests that were still in flight when it was killed.
hung_for() {
  cat >"$tmp/log"
  hung_tests_from_log "$tmp/log"
}

# The line --last prints about failing tests for a record with this content, or
# empty when it prints none. show_last resolves drift against $root, which only
# the executed script sets, so point it at this checkout.
root=$(cd -- "$here/.." && pwd -P) || exit 1
failing_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  failing //p'
}

# The same, for the provenance cell — the line --last prints about the result
# bundle, or empty when it prints none.
bundle_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  bundle  //p'
}

# And for the skipped-tests cell.
skipped_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  skipped //p'
}

# The line --last prints under the label a ceiling row's names get, or empty when
# it prints none. The same cell as failing_readout_for above reads — which is the
# point of having both: exactly one of the two answers for any row.
hung_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  hung    //p'
}

# The whole readout for a record with this content, so the order of its lines
# and the alignment of their labels can be asserted rather than assumed.
readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record"
}

printf 'test-run-unit-suite\n'

# The run of 2026-08-10, as it should have been recorded. The per-suite
# `Executed` lines are here on purpose: XCTest closes every suite with one, so a
# reader that added them all up would say 6,079 instead of 3,038.
actual=$(tally_for <<'LOG'
Test Suite 'SkillTests' passed at 2026-08-10 23:09:01.000.
	 Executed 3 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds
Test Suite 'KiteloopTests.xctest' passed at 2026-08-10 23:13:20.000.
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
Test Suite 'Selected tests' passed at 2026-08-10 23:13:20.000.
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'both frameworks, green — both counted, neither discarded' \
  '✔ 3056 tests passed — 3038 XCTest, 18 swift-testing' "$actual"

# The failure this most needed to stop: three thousand XCTest cases with
# failures in them, behind a swift-testing summary that says passed.
actual=$(tally_for <<'LOG'
	 Executed 3038 tests, with 3 failures (0 unexpected) in 248.100 (250.000) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'XCTest fails behind a passing swift-testing summary — reads failed' \
  '✘ 3056 tests, 3 failures — 3038 XCTest (3 failures), 18 swift-testing (0 failures)' "$actual"

# A skipped test is not a failure — and it is not a pass either, so the green
# cell names it. XCTest switches to `with N test skipped and M failures` the
# moment anything is skipped, and reading the count only after `with` picked up
# the skip count — or, worse, missed the line and let the `*fail*` fallback match
# the words `0 failures`, recording a green run as red. Skipped tests are counted
# inside `Executed N tests`, so without the parenthesis this row and a row where
# all 3,040 executed are the same eleven characters.
actual=$(tally_for <<'LOG'
	 Executed 3040 tests, with 1 test skipped and 0 failures (0 unexpected) in 214.123 (215.038) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'a skipped test is not a failure, and the green cell names it' \
  '✔ 3058 tests passed (1 skipped) — 3040 XCTest, 18 swift-testing' "$actual"

# A whole block opting out — a bindable port that was not free, a `claude` binary
# that is not installed — is the reading this cell exists for: 46 lines in
# KiteloopTests can skip on the state of the machine, and a row that hides them
# is the "green because it never ran" answer docs/suite-status.md is meant to
# make impossible.
actual=$(tally_for <<'LOG'
	 Executed 3040 tests, with 27 tests skipped and 0 failures (0 unexpected) in 214.123 (215.038) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'a block of tests opting out is visible in a green cell' \
  '✔ 3058 tests passed (27 skipped) — 3040 XCTest, 18 swift-testing' "$actual"

# Skips and real failures together: the failures are what counts, and the skips
# are still named beside them — a red run tells you what failed *and* how much of
# the suite never got the chance to.
actual=$(tally_for <<'LOG'
	 Executed 3040 tests, with 3 tests skipped and 2 failures (1 unexpected) in 214.123 (215.038) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'skips alongside failures report only the failures, and name the skips' \
  '✘ 3058 tests, 2 failures (3 skipped) — 3040 XCTest (2 failures), 18 swift-testing (0 failures)' "$actual"

# swift-testing's summary names no skips, so its count is XCTest's alone. A log
# where only swift-testing carries the word must not put a number in the cell —
# there is no number to put there.
actual=$(tally_for <<'LOG'
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'nothing skipped — no parenthesis, the cell reads as it always has' \
  '✔ 3056 tests passed — 3038 XCTest, 18 swift-testing' "$actual"

# The same on the failing branch: an ordinary red run gains nothing.
actual=$(tally_for <<'LOG'
	 Executed 3038 tests, with 2 failures (0 unexpected) in 248.100 (250.000) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'nothing skipped on a red run — no parenthesis either' \
  '✘ 3056 tests, 2 failures — 3038 XCTest (2 failures), 18 swift-testing (0 failures)' "$actual"

# And the reverse, which last-wins happened to get right — for the wrong reason,
# since it was reading the last line rather than every framework.
actual=$(tally_for <<'LOG'
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
✘ Test run with 18 tests in 2 suites failed after 0.005 seconds with 1 issue.
LOG
)
check 'swift-testing fails behind a passing XCTest summary — reads failed' \
  '✘ 3056 tests, 1 failure — 3038 XCTest (0 failures), 18 swift-testing (1 failure)' "$actual"

# A failed verdict with no number attached still has to read failed. Rounding an
# unparsed count down to zero would turn a red run green, which is the whole
# reason this file exists.
actual=$(tally_for <<'LOG'
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
✘ Test run with 18 tests in 2 suites failed after 0.005 seconds.
LOG
)
check 'a failed summary naming no count is one failure, not none' \
  '✘ 3056 tests, 1 failure — 3038 XCTest (0 failures), 18 swift-testing (1 failure)' "$actual"

# The tally's count of failures and the names beside it answer different
# questions — assertions against tests — and a row said only the first. At
# 349e40d it read `✘ 3362 tests, 2 failures` next to a cell naming one test, and
# a reader reconciles that by assuming the names cell dropped one. So a red cell
# now spells both, counted off the reader that fills the names cell: one test
# failing twice is one failing test and two failures. Asserted through both
# readers over the same lines, since agreeing is the whole point.
cat >"$tmp/twice" <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.003 seconds).
	 Executed 3038 tests, with 2 failures (0 unexpected) in 248.100 (250.000) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
actual="$(tally_from_log "$tmp/twice")
$(failing_tests_from_log "$tmp/twice")"
check 'one test failing twice — one failing test, two failures, one name' \
  '✘ 3056 tests, 1 failing test (2 failures) — 3038 XCTest (2 failures), 18 swift-testing (0 failures)
KiteloopTests.SkillTests.testProfileLoads' \
  "$actual"

# And two tests failing once each, which is the same two failures and a different
# answer to the question the cell was hiding.
actual=$(tally_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
Test Case '-[KiteloopTests.SkillTests testKnowledgeLoads]' failed (0.001 seconds).
	 Executed 3038 tests, with 2 failures (0 unexpected) in 248.100 (250.000) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'two tests failing once each — two failing tests, two failures' \
  '✘ 3056 tests, 2 failing tests (2 failures) — 3038 XCTest (2 failures), 18 swift-testing (0 failures)' \
  "$actual"

# Both frameworks red at once: the count is of names, so it crosses the frameworks
# the same way the names cell does rather than reporting XCTest's alone.
actual=$(tally_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
✘ Test needsCycleReadsUnmet() failed after 0.002 seconds with 1 issue.
	 Executed 3038 tests, with 1 failure (0 unexpected) in 248.100 (250.000) seconds
✘ Test run with 18 tests in 2 suites failed after 0.005 seconds with 1 issue.
LOG
)
check 'a failing test in each framework — both counted' \
  '✘ 3056 tests, 2 failing tests (2 failures) — 3038 XCTest (1 failure), 18 swift-testing (1 failure)' \
  "$actual"

# Skips beside real failures: the failing-test count goes where the failure count
# was, and the skipped parenthesis is left exactly where it sat.
actual=$(tally_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.003 seconds).
	 Executed 3040 tests, with 3 tests skipped and 2 failures (1 unexpected) in 214.123 (215.038) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'a named failure with skips — the skipped parenthesis still last' \
  '✘ 3058 tests, 1 failing test (2 failures) (3 skipped) — 3040 XCTest (2 failures), 18 swift-testing (0 failures)' \
  "$actual"

# A red verdict with no case printed under it — the log that records a dash in
# the names cell. There is nothing to reconcile, so the cell keeps the spelling
# it always had; `0 failing tests` beside a failed verdict would read as green.
cat >"$tmp/unnamed" <<'LOG'
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
✘ Test run with 18 tests in 2 suites failed after 0.005 seconds with 1 issue.
LOG
actual="$(tally_from_log "$tmp/unnamed")
$(failing_tests_from_log "$tmp/unnamed")"
check 'a red run naming no test — the old spelling, and a dash beside it' \
  '✘ 3056 tests, 1 failure — 3038 XCTest (0 failures), 18 swift-testing (1 failure)
—' \
  "$actual"

# One framework, one line: nothing to combine, so the row reads exactly as it
# did before any of this.
actual=$(tally_for <<'LOG'
Test Suite 'Selected tests' passed at 2026-08-10 23:13:20.000.
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
LOG
)
check 'XCTest alone — passed through verbatim' \
  'Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds' "$actual"

# And with skips in it: still nothing to combine, so the line still goes in
# untouched — XCTest has already said `with 1 test skipped` in its own words, and
# rewriting it to add a parenthesis would say it twice.
actual=$(tally_for <<'LOG'
	 Executed 3040 tests, with 1 test skipped and 0 failures (0 unexpected) in 214.123 (215.038) seconds
LOG
)
check 'XCTest alone with a skip — still verbatim, skips and all' \
  'Executed 3040 tests, with 1 test skipped and 0 failures (0 unexpected) in 214.123 (215.038) seconds' "$actual"

actual=$(tally_for <<'LOG'
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'swift-testing alone — passed through verbatim' \
  '✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.' "$actual"

# A run that died mid-suite. XCTest opened `All tests` and never closed it, so
# there is no run total in this log at all — only the suites that happened to
# finish before the process went away. Taking the last of those recorded the run
# of 2026-08-13 as seven tests passing in a hundredth of a second, beside exit 65
# and a 359-second duration: a complete, green measurement of a run that measured
# nothing. The right answer is no tally, which is the answer the caller already
# knows how to say.
actual=$(tally_for <<'LOG'
Test Suite 'All tests' started at 2026-08-13 08:15:18.000.
Test Suite 'KiteloopTests.xctest' started at 2026-08-13 08:15:18.000.
Test Suite 'SkillTests' started at 2026-08-13 08:15:18.000.
Test Suite 'SkillTests' passed at 2026-08-13 08:15:18.010.
	 Executed 7 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds
LOG
)
check 'a run that died with All tests unclosed — no total, so no tally' '' "$actual"

# The same log with swift-testing having finished under it: XCTest still has no
# total to give, so the cell is swift-testing's answer alone. The inner seven
# must not reach the tally by the combining path either — that is where it would
# turn into `✔ 25 tests passed` for a run that crashed.
actual=$(tally_for <<'LOG'
Test Suite 'All tests' started at 2026-08-13 08:15:18.000.
Test Suite 'SkillTests' passed at 2026-08-13 08:15:18.010.
	 Executed 7 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'a died run with swift-testing done — its count alone, not the inner seven' \
  '✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.' "$actual"

# A crashed run is retried, so a log can hold several run suites — the real log
# of 2026-08-13 opens `All tests` once and `Selected tests` twice and closes none
# of them. A retry that *did* close is not the run's total: it counted the
# handful of tests it was narrowed to, and recording it would be the inner seven
# again with a different number on it.
actual=$(tally_for <<'LOG'
Test Suite 'All tests' started at 2026-08-13 08:15:18.000.
Test Suite 'SkillTests' passed at 2026-08-13 08:15:18.010.
	 Executed 7 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds
Test Suite 'Selected tests' started at 2026-08-13 08:20:35.670.
Test Suite 'Selected tests' passed at 2026-08-13 08:20:36.100.
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.430 (0.431) seconds
LOG
)
check 'a retry that closed under a run that did not — still no tally' '' "$actual"

# And the close is what the total is read from, not the position of the line: a
# finished run whose innermost suite is the last to print still records the run
# total. Reading the last summary line would say seven here too, for a run that
# executed three thousand tests and said so.
actual=$(tally_for <<'LOG'
Test Suite 'KiteloopTests.xctest' passed at 2026-08-13 08:15:18.000.
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
Test Suite 'All tests' passed at 2026-08-13 08:15:18.000.
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
Test Suite 'SkillTests' passed at 2026-08-13 08:15:18.100.
	 Executed 7 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds
LOG
)
check 'a finished run — the All tests total, not the last suite to close' \
  'Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds' "$actual"

# No tally at all: the caller prints "xcodebuild exited before running tests"
# and records that instead, so an empty string is the right answer here.
actual=$(tally_for <<'LOG'
** BUILD FAILED **
LOG
)
check 'no framework reported — empty, so the caller says so' '' "$actual"

# --- The ceiling's tally spelling ---------------------------------------------
#
# The cell a row gets when run-unit-suite.sh itself ends a run that outlived
# SUITE_TIMEOUT_SECONDS, rather than one that came back from xcodebuild on its
# own — and the reader that has to recognise that cell, and the classic
# NO_TALLY_CELL one, the same way everywhere a tally states a verdict: neither
# is a claim about whether the suite passed.

check 'the ceiling cell names the seconds it was given' \
  'no tally — xcodebuild ran past its 42s time limit and was ended' \
  "$(timeout_tally_cell 42)"

check 'NO_TALLY_CELL states no measurement' \
  0 "$(tally_states_no_measurement "$NO_TALLY_CELL"; printf '%s' $?)"
check 'an empty tally states no measurement' \
  0 "$(tally_states_no_measurement ''; printf '%s' $?)"
check 'a ceiling cell states no measurement, whatever seconds it names' \
  0 "$(tally_states_no_measurement "$(timeout_tally_cell 42)"; printf '%s' $?)"
check 'an ordinary tally states a measurement' \
  1 "$(tally_states_no_measurement '✔ 3058 tests passed'; printf '%s' $?)"

# And the narrower reading beside it, which tells a ceiling cell from the other
# two that state no measurement rather than admitting all three. That is what
# lets the readout call a test hung instead of failed: only on this row are the
# names in the failing cell cases that never came back.
check 'a ceiling cell is recognised as one, whatever seconds it names' \
  0 "$(tally_states_timeout "$(timeout_tally_cell 42)"; printf '%s' $?)"
check 'NO_TALLY_CELL states no measurement but is not a ceiling cell' \
  1 "$(tally_states_timeout "$NO_TALLY_CELL"; printf '%s' $?)"
check 'an empty tally is not a ceiling cell either' \
  1 "$(tally_states_timeout ''; printf '%s' $?)"
check 'nor is an ordinary tally' \
  1 "$(tally_states_timeout '✔ 3058 tests passed'; printf '%s' $?)"

# verdict_of reads a no-measurement tally the same way whatever the exit cell
# beside it says — including the two cases that used to disagree with it: the
# classic no-tally row, whose exit cell is xcodebuild's own 0 and used to read
# as a pass, and a ceiling row, whose exit cell is a real non-zero status and
# would otherwise read as an ordinary red run.
check 'the classic no-tally row is no verdict, not a pass, despite exit 0' \
  '' "$(verdict_of 0 "$NO_TALLY_CELL")"
check 'a ceiling row is no verdict, not a fail, despite a real non-zero exit' \
  '' "$(verdict_of 143 "$(timeout_tally_cell 42)")"

# --- The parallel shape -------------------------------------------------------
#
# What `-parallel-testing-enabled YES` prints instead of the summaries above:
# one line per case from either framework, on whichever host clone ran it, and
# a `** TEST … **` marker once they are all done — no suite opens or closes, no
# `Executed`, no `Test run with`. The first parallel run went into the record
# as `no tally — xcodebuild exited before running tests` over 4,931 passed
# cases, which is the reading these cases exist to stop. XCTest spells a case
# `Class.method()`, swift-testing `Suite/name()`; the separator is how the
# frameworks are told apart, since nothing else in the line says.
actual=$(tally_for <<'LOG'
Test case 'FooTests.testBar()' passed on 'My Mac - Kiteloop (86621)' (0.076 seconds)
Test case 'FooTests.testBaz()' passed on 'My Mac - Kiteloop (86622)' (0.010 seconds)
Test case 'SkillTests/parseAllFields()' passed on 'My Mac - Kiteloop (86619)' (0.005 seconds)
Test case 'BarTests.testQux()' passed on 'My Mac - Kiteloop (86621)' (0.020 seconds)
Test case 'SkillTests/parseMinimalFields()' passed on 'My Mac - Kiteloop (86619)' (0.005 seconds)
** TEST SUCCEEDED **
LOG
)
check 'a parallel run, green — both frameworks counted off their case lines' \
  '✔ 5 tests passed — 3 XCTest, 2 swift-testing' "$actual"

# A failing case is one failure: nothing in this shape counts assertions, so the
# failing-test count and the failure count are the same number, said both ways
# for the reason combine_tally says them both.
actual=$(tally_for <<'LOG'
Test case 'FooTests.testBar()' passed on 'My Mac - Kiteloop (86621)' (0.076 seconds)
Test case 'FooTests.testBaz()' failed on 'My Mac - Kiteloop (86622)' (0.010 seconds)
Test case 'SkillTests/parseAllFields()' passed on 'My Mac - Kiteloop (86619)' (0.005 seconds)
Test case 'BarTests.testQux()' passed on 'My Mac - Kiteloop (86621)' (0.020 seconds)
Test case 'SkillTests/parseMinimalFields()' passed on 'My Mac - Kiteloop (86619)' (0.005 seconds)
** TEST FAILED **
LOG
)
check 'a parallel run with an XCTest failure — reads failed, the frameworks told apart' \
  '✘ 5 tests, 1 failing test (1 failure) — 3 XCTest (1 failure), 2 swift-testing (0 failures)' "$actual"

actual=$(tally_for <<'LOG'
Test case 'FooTests.testBar()' passed on 'My Mac - Kiteloop (86621)' (0.076 seconds)
Test case 'FooTests.testBaz()' failed on 'My Mac - Kiteloop (86622)' (0.010 seconds)
Test case 'SkillTests/parseAllFields()' passed on 'My Mac - Kiteloop (86619)' (0.005 seconds)
Test case 'BarTests.testQux()' passed on 'My Mac - Kiteloop (86621)' (0.020 seconds)
Test case 'SkillTests/parseMinimalFields()' failed on 'My Mac - Kiteloop (86619)' (0.005 seconds)
** TEST FAILED **
LOG
)
check 'a parallel failure in each framework — both counted, and the names cell agrees' \
  '✘ 5 tests, 2 failing tests (2 failures) — 3 XCTest (1 failure), 2 swift-testing (1 failure)' "$actual"

actual=$(tally_for <<'LOG'
Test case 'FooTests.testBar()' passed on 'My Mac - Kiteloop (86621)' (0.076 seconds)
Test case 'HTTPServerTests.testBinds()' skipped on 'My Mac - Kiteloop (86622)' (0.001 seconds)
Test case 'SkillTests/parseAllFields()' passed on 'My Mac - Kiteloop (86619)' (0.005 seconds)
Test case 'BarTests.testQux()' passed on 'My Mac - Kiteloop (86621)' (0.020 seconds)
Test case 'SkillTests/parseMinimalFields()' passed on 'My Mac - Kiteloop (86619)' (0.005 seconds)
** TEST SUCCEEDED **
LOG
)
check 'a parallel skip is counted, named in the cell, and is not a failure' \
  '✔ 5 tests passed (1 skipped) — 3 XCTest, 2 swift-testing' "$actual"

# XCTest alone still reads as a two-framework cell: the shape cannot say which
# frameworks took part, only which cases ran, and `0 swift-testing` is the
# honest count rather than a guess at a serial spelling.
actual=$(tally_for <<'LOG'
Test case 'FooTests.testBar()' passed on 'My Mac - Kiteloop (86621)' (0.076 seconds)
Test case 'FooTests.testBaz()' passed on 'My Mac - Kiteloop (86622)' (0.010 seconds)
** TEST SUCCEEDED **
LOG
)
check 'a parallel run of XCTest cases only — counted, swift-testing at zero' \
  '✔ 2 tests passed — 2 XCTest, 0 swift-testing' "$actual"

# Case lines and no marker: the clones were killed, or the build was. That is
# the unclosed run suite of the serial shape, and records what it records — no
# tally, so the row says nothing was measured rather than counting what got
# through.
actual=$(tally_for <<'LOG'
Test case 'FooTests.testBar()' passed on 'My Mac - Kiteloop (86621)' (0.076 seconds)
Test case 'FooTests.testBaz()' passed on 'My Mac - Kiteloop (86622)' (0.010 seconds)
LOG
)
check 'a parallel run that never closed — no tally' '' "$actual"

# The names, in the spelling the cells carry: the XCTest case gets the target
# prefix and loses its `()`, which is the dotted form the serial reader produces
# and -only-testing: takes; the swift-testing case is recorded as printed.
# xcodebuild's trailing block names the same two tests in its own spelling, and
# is not consulted while per-case lines are there — so each name is in the cell
# once.
actual=$(failing_for <<'LOG'
Test case 'FooTests.testBaz()' failed on 'My Mac - Kiteloop (86622)' (0.010 seconds)
Test case 'SkillTests/parseMinimalFields()' failed on 'My Mac - Kiteloop (86619)' (0.005 seconds)
Test case 'BarTests.testQux()' passed on 'My Mac - Kiteloop (86621)' (0.020 seconds)
Failing tests:
	FooTests.testBaz()
	SkillTests/parseMinimalFields()

** TEST FAILED **
LOG
)
check 'a parallel red run — the dotted XCTest spelling, swift-testing as printed, each once' \
  'KiteloopTests.FooTests.testBaz, SkillTests/parseMinimalFields()' "$actual"

actual=$(failing_for <<'LOG'
Test case 'FooTests.testBar()' passed on 'My Mac - Kiteloop (86621)' (0.076 seconds)
** TEST SUCCEEDED **
LOG
)
check 'a parallel green run — a dash in the failing cell' '—' "$actual"

actual=$(skipped_for <<'LOG'
Test case 'HTTPServerTests.testBinds()' skipped on 'My Mac - Kiteloop (86622)' (0.001 seconds)
Test case 'FooTests.testBaz()' failed on 'My Mac - Kiteloop (86622)' (0.010 seconds)
Test case 'FooTests.testBar()' passed on 'My Mac - Kiteloop (86621)' (0.076 seconds)
** TEST FAILED **
LOG
)
check 'a parallel skip is named in the skipped cell, and a parallel failure is not' \
  'KiteloopTests.HTTPServerTests.testBinds' "$actual"

# --- The result bundle ---------------------------------------------------------
#
# Parallel output is not line-atomic — 25 of the second parallel run's 4,931
# case lines were cut mid-name by another clone writing over them, and the row
# read 4904 — so the readers take the tally and the names from the result
# bundle when the log names one this machine can read. The listing reader is
# driven with a listing written here; the preference over the log is driven
# with an `xcrun` shim standing in for xcresulttool, over a garbled log that
# names a bundle on disk.
bundle_cases_for() {
  bundle_cases_in
}

listing=$(cat <<'JSON'
{"testNodes": [{"nodeType": "Test Plan", "name": "Kiteloop", "children": [
  {"nodeType": "Unit test bundle", "name": "KiteloopTests", "children": [
    {"nodeType": "Test Suite", "name": "FooTests", "children": [
      {"nodeType": "Test Case", "name": "testBar()", "nodeIdentifier": "FooTests/testBar()",
       "nodeIdentifierURL": "test://com.apple.xcode/Kiteloop/KiteloopTests/FooTests/testBar", "result": "Passed"},
      {"nodeType": "Test Case", "name": "testBaz()", "nodeIdentifier": "FooTests/testBaz()",
       "nodeIdentifierURL": "test://com.apple.xcode/Kiteloop/KiteloopTests/FooTests/testBaz", "result": "Failed",
       "children": [{"nodeType": "Failure Message", "name": "XCTAssertEqual failed"}]},
      {"nodeType": "Test Case", "name": "testBinds()", "nodeIdentifier": "FooTests/testBinds()",
       "nodeIdentifierURL": "test://com.apple.xcode/Kiteloop/KiteloopTests/FooTests/testBinds", "result": "Skipped"},
      {"nodeType": "Test Case", "name": "testKnown()", "nodeIdentifier": "FooTests/testKnown()",
       "nodeIdentifierURL": "test://com.apple.xcode/Kiteloop/KiteloopTests/FooTests/testKnown", "result": "Expected Failure"}
    ]},
    {"nodeType": "Test Suite", "name": "Skill Parsing", "children": [
      {"nodeType": "Test Suite", "name": "nested", "children": [
        {"nodeType": "Test Case", "name": "Parses every field", "nodeIdentifier": "SkillTests/parseAllFields()",
         "nodeIdentifierURL": "test://com.apple.xcode/Kiteloop/KiteloopTests/SkillTests/parseAllFields()", "result": "Passed"}
      ]},
      {"nodeType": "Test Case", "name": "Minimal", "nodeIdentifier": "SkillTests/parseMinimalFields()",
       "nodeIdentifierURL": "test://com.apple.xcode/Kiteloop/KiteloopTests/SkillTests/parseMinimalFields()", "result": "Failed"}
    ]},
    {"nodeType": "Runtime Warning", "name": "something"}
  ]}
]}]}
JSON
)
actual=$(printf '%s' "$listing" | bundle_cases_for)
check 'a bundle listing — every case, in order, with the spelling the cells carry' \
  'passed KiteloopTests.FooTests.testBar
failed KiteloopTests.FooTests.testBaz
skipped KiteloopTests.FooTests.testBinds
passed KiteloopTests.FooTests.testKnown
passed SkillTests/parseAllFields()
failed SkillTests/parseMinimalFields()' "$actual"

actual=$(printf '%s' "$listing" | bundle_cases_for | cases_tally 2)
check 'the tally off a bundle — both frameworks, the skip, the expected failure a pass' \
  '✘ 6 tests, 2 failing tests (2 failures) (1 skipped) — 4 XCTest (1 failure), 2 swift-testing (1 failure)' "$actual"

actual=$(printf '{"testNodes": []}' | bundle_cases_for | cases_tally 0)
check 'a bundle with no cases — no tally, not a zero' '' "$actual"

# The case this section exists for. The log below is what a parallel run can
# print — one line cut in half by another clone — and it names a bundle that is
# on disk, which the xcrun shim answers for with a listing of both cases. The
# row records the bundle's two, not the log's one.
bundle_dir=$tmp/Test-Kiteloop-shim.xcresult
mkdir -p "$bundle_dir" "$tmp/xcrun-shim"
printf '%s' '{"testNodes": [{"nodeType": "Unit test bundle", "name": "KiteloopTests", "children": [
  {"nodeType": "Test Case", "name": "testBar()", "nodeIdentifier": "FooTests/testBar()",
   "nodeIdentifierURL": "test://com.apple.xcode/Kiteloop/KiteloopTests/FooTests/testBar", "result": "Passed"},
  {"nodeType": "Test Case", "name": "testCut()", "nodeIdentifier": "BacklogApproveTests/testCut()",
   "nodeIdentifierURL": "test://com.apple.xcode/Kiteloop/KiteloopTests/BacklogApproveTests/testCut", "result": "Failed"}
]}]}' >"$tmp/xcrun-shim/listing.json"
cat >"$tmp/xcrun-shim/xcrun" <<'SHIM'
#!/bin/sh
# Stands in for `xcrun xcresulttool get test-results tests --path … --compact`.
cat "$(dirname "$0")/listing.json"
SHIM
chmod +x "$tmp/xcrun-shim/xcrun"
garbled_log="Test case 'FooTests.testBar()' passed on 'My Mac - Kiteloop (1)' (0.1 seconds)
rBacklogApproveTests.testCut()' failed on 'My Mac - Kiteloop (2)' (0.1 seconds)
** TEST FAILED **
Test session results, code coverage, and logs:
	$bundle_dir"
actual=$( (export PATH="$tmp/xcrun-shim:$PATH"; printf '%s\n' "$garbled_log" | tally_for) )
check 'a garbled parallel log naming a bundle — the bundle'"'"'s count, not the log'"'"'s' \
  '✘ 2 tests, 1 failing test (1 failure) — 2 XCTest (1 failure), 0 swift-testing (0 failures)' "$actual"
actual=$( (export PATH="$tmp/xcrun-shim:$PATH"; printf '%s\n' "$garbled_log" | failing_for) )
check 'the failing name the log lost is in the cell, from the bundle' \
  'KiteloopTests.BacklogApproveTests.testCut' "$actual"

# The same log naming a bundle that is not on disk reads as the log alone: one
# case, since the cut line is not a case line — and still red, since the marker
# says FAILED and a run that lost the line naming its failure must not round
# down to green. Nothing to name, so the failure is counted and not spelled.
actual=$(printf '%s\n' "${garbled_log%$bundle_dir}/nowhere/Test-Gone.xcresult" | tally_for)
check 'a bundle that is not there — the log alone, and the FAILED marker keeps it red' \
  '✘ 1 test, 1 failure — 1 XCTest (1 failure), 0 swift-testing (0 failures)' "$actual"
actual=$(printf '%s\n' "${garbled_log%$bundle_dir}/nowhere/Test-Gone.xcresult" | failing_for)
check 'a bundle that is not there — the lost name stays lost, a dash' '—' "$actual"

# --- Provenance --------------------------------------------------------------
#
# The cell that says a run happened at all. xcodebuild prints the bundle it
# opened, under "Test session results, code coverage, and logs:", on its own
# indented line; the recorded cell is that path's last component, which carries
# the wall clock of the moment testing started.
actual=$(bundle_for <<'LOG'
Test Suite 'Selected tests' passed at 2026-08-10 23:13:20.000.
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds

Test session results, code coverage, and logs:
	/Users/someone/Library/Developer/Xcode/DerivedData/Kiteloop-dymuyphjkdcnmagpqzuuvtwrwwzz/Logs/Test/Test-Kiteloop-2026.08.10_13-13-24--1000.xcresult

** TEST SUCCEEDED **
LOG
)
check 'a finished run — the bundle it named, without its directory' \
  'Test-Kiteloop-2026.08.10_13-13-24--1000.xcresult' "$actual"

# A run that dies before testing starts opens no session bundle; it writes an
# error bundle to TMPDIR and prints that instead. That row has no tally, but it
# is still a run that happened, and this is the bundle proving it.
actual=$(bundle_for <<'LOG'
2026-08-10 15:01:22.081 xcodebuild[40175:56199170] Writing error result bundle to /var/folders/1w/z1sqb95x619fwwb1n8bz49x80000gn/T/ResultBundle_2026-08-10_15-01-0022.xcresult
xcodebuild: error: The workspace named "Kiteloop" does not contain a scheme named "Kiteloop".
LOG
)
check 'a run that died early — its error bundle, which is still evidence' \
  'ResultBundle_2026-08-10_15-01-0022.xcresult' "$actual"

# Two bundles named in one log: the run's own is the one it opened last.
actual=$(bundle_for <<'LOG'
Writing error result bundle to /var/folders/1w/T/ResultBundle_2026-08-10_15-01-0022.xcresult
Test session results, code coverage, and logs:
	/Users/someone/Library/Developer/Xcode/DerivedData/Kiteloop-abc/Logs/Test/Test-Kiteloop-2026.08.10_13-13-24--1000.xcresult
LOG
)
check 'two bundles named — the last one belongs to this run' \
  'Test-Kiteloop-2026.08.10_13-13-24--1000.xcresult' "$actual"

# No bundle anywhere in the output: the caller records that in so many words,
# rather than an empty cell that could be read as a name nobody typed.
actual=$(bundle_for <<'LOG'
** BUILD FAILED **
LOG
)
check 'no bundle named — empty, so the caller says so' '' "$actual"

# --- Which tests failed ------------------------------------------------------
#
# The cell that turns "2 failures" into something you can act on. It is read
# from the same log as the tally, at the moment the log still exists.

# A red run of both frameworks. The names come out in the order the run reported
# them, not grouped by framework, and the XCTest selector is rewritten to the
# dotted spelling -only-testing: takes.
actual=$(failing_for <<'LOG'
Test Case '-[KiteloopTests.ControlRouterTests testEveryEndpointMatchesItsRoute]' started.
Test Case '-[KiteloopTests.ControlRouterTests testEveryEndpointMatchesItsRoute]' failed (0.004 seconds).
✘ Test backlogGateWithholdsUnmetNeeds() recorded an issue at DefinitionOfReadyTests.swift:41:5
✘ Test backlogGateWithholdsUnmetNeeds() failed after 0.001 seconds with 1 issue.
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
	 Executed 3040 tests, with 2 failures (0 unexpected) in 214.123 (215.038) seconds
✘ Test run with 18 tests in 2 suites failed after 0.005 seconds with 1 issue.
LOG
)
check 'a red run — every failing test, in the order the run reported it' \
  'KiteloopTests.ControlRouterTests.testEveryEndpointMatchesItsRoute, backlogGateWithholdsUnmetNeeds(), KiteloopTests.SkillTests.testProfileLoads' \
  "$actual"

# swift-testing on its own. Reading only XCTest's failure lines would record a
# dash for this run and send someone back to the suite to find out why it was
# red.
actual=$(failing_for <<'LOG'
✘ Test needsCycleReadsUnmet() failed after 0.002 seconds with 1 issue.
✘ Test run with 18 tests in 2 suites failed after 0.005 seconds with 1 issue.
LOG
)
check 'swift-testing alone — its failures are read too' \
  'needsCycleReadsUnmet()' "$actual"

# swift-testing's run summary has the shape of a failing test and is not one.
# Recorded, it would fill the cell with "run with 18 tests in 2 suites".
actual=$(failing_for <<'LOG'
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
✘ Test run with 18 tests in 2 suites failed after 0.005 seconds with 1 issue.
LOG
)
check 'the run summary is not a test name' '—' "$actual"

# XCTest reports a failing case once per suite it is nested under, so the same
# name arrives several times; it is worth saying once.
actual=$(failing_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
Test Case '-[KiteloopTests.SkillTests testKnowledgeLoads]' failed (0.001 seconds).
LOG
)
check 'a name repeated in the log is recorded once' \
  'KiteloopTests.SkillTests.testProfileLoads, KiteloopTests.SkillTests.testKnowledgeLoads' \
  "$actual"

# A green run has nothing to name, and the cell says so with a dash rather than
# an empty field that reads as a column somebody forgot to fill in.
actual=$(failing_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' passed (0.002 seconds).
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'a green run — a dash, not an empty cell' '—' "$actual"

# A red run that printed no per-case line at all. Both readers above come up
# empty on it and it recorded a dash — the run of 2026-08-13, whose three failing
# tests were named in xcodebuild's own trailing block and nowhere else. The
# names are read from there instead, in the order printed, without the `()` that
# spelling carries. The count is taken from the same reader, so the tally and the
# cell beside it cannot say different things about one run — asserted together.
cat >"$tmp/block" <<'LOG'
	 Executed 3038 tests, with 3 failures (0 unexpected) in 248.100 (250.000) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
Failing tests:
	KiteloopControlServerStartRunTests.testARetryAfterASlowStartDoesNotBeginTheItemTwice()
	KiteloopControlServerStrandedWorkTests.testReportingAnItemChangesNeitherItsStatusNorItsBranch()
	NotificationStoreTests.testActionablePendingCountIgnoresAmbientTypes()

** TEST FAILED **
LOG
actual="$(failing_tests_from_log "$tmp/block")
$(failing_test_count_from_log "$tmp/block")"
check 'no per-case line — xcodebuild'"'"'s own block names them, and the count agrees' \
  'KiteloopControlServerStartRunTests.testARetryAfterASlowStartDoesNotBeginTheItemTwice, KiteloopControlServerStrandedWorkTests.testReportingAnItemChangesNeitherItsStatusNorItsBranch, NotificationStoreTests.testActionablePendingCountIgnoresAmbientTypes
3' \
  "$actual"

# A fallback, never a union. A real red run prints both, and the block spells a
# name without the `KiteloopTests.` prefix the per-case reader produces — merging
# the two would record one test twice under two spellings.
actual=$(failing_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
	 Executed 3038 tests, with 1 failure (0 unexpected) in 248.100 (250.000) seconds
Failing tests:
	SkillTests.testProfileLoads()

** TEST FAILED **
LOG
)
check 'both spellings present — the per-case one, each name once' \
  'KiteloopTests.SkillTests.testProfileLoads' "$actual"

# --last reads the cell back out of a row that carries it.
actual=$(failing_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✘ 3058 tests, 2 failures | 65 | Test-Kiteloop-2026.08.12_09-00-00--1000.xcresult | KiteloopTests.SkillTests.testProfileLoads, needsCycleReadsUnmet() |
RECORD
)
check '--last prints the failing tests a row carries' \
  'KiteloopTests.SkillTests.testProfileLoads, needsCycleReadsUnmet()' "$actual"

# And says nothing at all about a row written before the column existed, rather
# than printing an empty field or the cell next door.
actual=$(failing_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle |
| --- | --- | --- | --- | --- | --- |
| 2026-08-10T23:13:22Z | 2984093 | clean | ✔ 3058 tests passed — 3040 XCTest, 18 swift-testing | 0 | not recorded |
RECORD
)
check 'a row predating the column — no line, not an empty one' '' "$actual"

# The provenance cell read back out. It is printed verbatim: a row can name a
# bundle, say `none named in the output`, or — from before the column existed —
# `not recorded`, and choosing between those is the reader's job, not this
# readout's.
actual=$(bundle_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop-2026.08.12_09-00-00--1000.xcresult | — |
RECORD
)
check '--last prints the result bundle a row carries' \
  'Test-Kiteloop-2026.08.12_09-00-00--1000.xcresult' "$actual"

# Where the line sits and how it is labelled, asserted rather than assumed: the
# readout is in row order, so bundle comes between exit and failing, and every
# label pads its value to the same column.
actual=$(readout_for <<'RECORD' | sed -n '/^  exit /,/^  failing /p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✘ 3058 tests, 1 failure | 65 | Test-Kiteloop-2026.08.12_09-00-00--1000.xcresult | KiteloopTests.SkillTests.testProfileLoads |
RECORD
)
check 'the bundle line sits between exit and failing, label aligned' \
  '  exit    65
  bundle  Test-Kiteloop-2026.08.12_09-00-00--1000.xcresult
  failing KiteloopTests.SkillTests.testProfileLoads' "$actual"

# An empty provenance cell prints nothing — not a blank line, and not the cell
# beside it, which is what reading past an empty field would produce.
actual=$(bundle_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✘ 3058 tests, 1 failure | 65 |  | KiteloopTests.SkillTests.testProfileLoads |
RECORD
)
check 'an empty bundle cell — no line, not the cell next door' '' "$actual"

# --- Which tests skipped -----------------------------------------------------
#
# The cell that turns `(1 skipped)` into something you can look at. 47 XCTSkip
# sites live in KiteloopTests — most conditional on a free loopback port for the
# control server, two on an installed `claude` binary — so a skip is either an
# expected opt-out on a busy machine or an endpoint whose coverage went missing,
# and the count alone reads identically for both.

# The names come out in the order the run reported them, with XCTest's selector
# rewritten to the dotted spelling -only-testing: takes, so one can be pasted
# into a narrowed re-run to find out why it opted out.
actual=$(skipped_for <<'LOG'
Test Case '-[KiteloopTests.HTTPServerTests testBindsToLoopback]' started.
Test Case '-[KiteloopTests.HTTPServerTests testBindsToLoopback]' skipped (0.001 seconds).
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' passed (0.002 seconds).
Test Case '-[KiteloopTests.ClaudeCodeCLIRuntimeTests testSpawns]' skipped (0.001 seconds).
	 Executed 3040 tests, with 2 tests skipped and 0 failures (0 unexpected) in 214.123 (215.038) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'a run with skips — every skipped test, in the order the run reported it' \
  'KiteloopTests.HTTPServerTests.testBindsToLoopback, KiteloopTests.ClaudeCodeCLIRuntimeTests.testSpawns' \
  "$actual"

# XCTest reports a skipped case once per suite it is nested under, exactly as it
# does a failing one; the same name twice says nothing the first one did not.
actual=$(skipped_for <<'LOG'
Test Case '-[KiteloopTests.HTTPServerTests testBindsToLoopback]' skipped (0.001 seconds).
Test Case '-[KiteloopTests.HTTPServerTests testBindsToLoopback]' skipped (0.001 seconds).
Test Case '-[KiteloopTests.HTTPServerTests testAcceptsRequest]' skipped (0.001 seconds).
LOG
)
check 'a skipped name repeated in the log is recorded once' \
  'KiteloopTests.HTTPServerTests.testBindsToLoopback, KiteloopTests.HTTPServerTests.testAcceptsRequest' \
  "$actual"

# Nothing skipped: a dash, matching the failing cell beside it rather than an
# empty field that reads as a column somebody forgot to fill in. The tally cell
# for this same log carries no parenthesis, which is the pair the row must keep.
actual=$(skipped_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' passed (0.002 seconds).
	 Executed 3038 tests, with 0 failures (0 unexpected) in 248.100 (250.000) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
)
check 'nothing skipped — a dash, not an empty cell' '—' "$actual"

# A failing case is not a skipped one, and a red run's names must not leak into
# the cell that says what never ran.
actual=$(skipped_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
✘ Test run with 18 tests in 2 suites failed after 0.005 seconds with 1 issue.
LOG
)
check 'a failing test is not a skipped one' '—' "$actual"

# The count and the names come from one log and have to agree: a cell saying
# `(2 skipped)` beside a cell naming three tests would be two readings of one
# run. Asserted through both readers over the same lines.
cat >"$tmp/both" <<'LOG'
Test Case '-[KiteloopTests.HTTPServerTests testBindsToLoopback]' skipped (0.001 seconds).
Test Case '-[KiteloopTests.ClaudeCodeCLIRuntimeTests testSpawns]' skipped (0.001 seconds).
	 Executed 3040 tests, with 2 tests skipped and 0 failures (0 unexpected) in 214.123 (215.038) seconds
✔ Test run with 18 tests in 2 suites passed after 0.005 seconds.
LOG
actual="$(tally_from_log "$tmp/both")
$(skipped_tests_from_log "$tmp/both")"
check 'the tally count and the names describe the same run' \
  '✔ 3058 tests passed (2 skipped) — 3040 XCTest, 18 swift-testing
KiteloopTests.HTTPServerTests.testBindsToLoopback, KiteloopTests.ClaudeCodeCLIRuntimeTests.testSpawns' \
  "$actual"

# --last reads the cell back out of a row that carries it.
actual=$(skipped_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed (2 skipped) | 0 | Test-Kiteloop.xcresult | — | KiteloopTests.HTTPServerTests.testBindsToLoopback, KiteloopTests.ClaudeCodeCLIRuntimeTests.testSpawns |
RECORD
)
check '--last prints the skipped tests a row carries' \
  'KiteloopTests.HTTPServerTests.testBindsToLoopback, KiteloopTests.ClaudeCodeCLIRuntimeTests.testSpawns' \
  "$actual"

# A run that skipped nothing has already said so by carrying no parenthesis in
# its tally, so the readout stays quiet rather than adding a line that says
# nothing on nearly every row.
actual=$(skipped_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — | — |
RECORD
)
check 'a dash in the skipped cell — no line, not a dash on its own line' '' "$actual"

actual=$(skipped_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — |  |
RECORD
)
check 'an empty skipped cell — no line either' '' "$actual"

# The rows already in docs/suite-status.md were written before this column, and
# every one of them still has to read out exactly as it did: no line here, and
# not the failing cell borrowed from next door.
actual=$(skipped_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | clean | ✘ 3362 tests, 2 failures (1 skipped) | 65 | Test-Kiteloop.xcresult | KiteloopTests.Phase2BIntegrationTests.testFullLifecycleWithCheckpoints |
RECORD
)
check 'a row predating the skipped column — no line, not the cell next door' '' "$actual"

# And the oldest row of all, which predates the two columns before it as well.
actual=$(skipped_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle |
| --- | --- | --- | --- | --- | --- |
| 2026-08-10T23:13:22Z | 2984093 | clean | ✔ 3058 tests passed — 3040 XCTest, 18 swift-testing | 0 | not recorded |
RECORD
)
check 'a row predating three columns — still no line' '' "$actual"

# Where the line sits and how it is labelled: in row order, so after failing and
# before the drift line, with its label padded to the same column as the rest.
actual=$(readout_for <<'RECORD' | sed -n '/^  failing /,/^  drift /p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | deadbee | clean | ✔ 3058 tests passed (1 skipped) | 0 | Test-Kiteloop.xcresult | — | KiteloopTests.HTTPServerTests.testBindsToLoopback |
RECORD
)
check 'the skipped line sits between failing and drift, label aligned' \
  '  failing —
  skipped KiteloopTests.HTTPServerTests.testBindsToLoopback
  drift   unknown — git cannot resolve deadbee in this checkout.' "$actual"

# The row a run actually writes, driven through append_record: the names land in
# the last cell, after the failing one, rather than anywhere the readers above
# would still have looked right from.
fresh=$tmp/fresh-record.md
rm -f "$fresh"
append_record "$fresh" 2026-08-12T09:00:00Z abc1234 clean \
  '✔ 3058 tests passed (1 skipped)' 0 Test-Kiteloop.xcresult \
  '—' 'KiteloopTests.HTTPServerTests.testBindsToLoopback' 254s \
  'Executed 42 tests, with 0 failures (0 unexpected) in 1.234 (1.240) seconds'
actual=$(grep -E '^\|' "$fresh")
check 'a fresh record — the header, its separator, and the row under them' \
  '| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration | package tally |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed (1 skipped) | 0 | Test-Kiteloop.xcresult | — | KiteloopTests.HTTPServerTests.testBindsToLoopback | 254s | Executed 42 tests, with 0 failures (0 unexpected) in 1.234 (1.240) seconds |' \
  "$actual"

# The header this script writes for a fresh file and the header the record in the
# repository already carries are the same table, and a column added to one has to
# reach the other: a row appended under a narrower header would put its last cell
# in a column with no name.
check 'the header a fresh record gets matches the one in docs/suite-status.md' \
  "$(grep -m 2 -E '^\|' "$root/docs/suite-status.md")" \
  "$(grep -m 2 -E '^\|' "$fresh")"

# --- Which test hung ----------------------------------------------------------
#
# What a run ended at SUITE_TIMEOUT_SECONDS was sitting on. Nothing fails in such
# a run and no framework totals itself up, so both readers above come back with
# nothing and the row records a dash in each cell: the row at 3eaccf6a says the
# run was ended at its 1800s limit and names nothing, and which test it hung on
# lives only in the kept output and in a commit message somebody typed. That is
# the one failure mode the ceiling exists to catch, described by the record as
# "the run stopped" and not as what it stopped on.
#
# XCTest prints no line announcing a hang — there is nothing to announce, the
# process simply stops — so a hung case is read by subtraction: opened with a
# `started` line and never closed by a `passed`, `failed` or `skipped` one.

actual=$(hung_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' started.
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' passed (0.002 seconds).
Test Case '-[KiteloopTests.HookEngineTests testATimedOutHookIsStopped]' started.
LOG
)
check 'the case that started and never closed is the one named' \
  'KiteloopTests.HookEngineTests.testATimedOutHookIsStopped' "$actual"

# The other half of that reading, on its own: a case that came back is not what
# the run hung on, however close to the end of the log it sits.
actual=$(hung_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' started.
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' passed (0.002 seconds).
LOG
)
check 'a case that started and came back is not hung' '—' "$actual"

# All three closing lines close. A reader that knew only about `passed` would
# name the last failing or skipped test of every timed-out run as the hung one.
actual=$(hung_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' started.
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
Test Case '-[KiteloopTests.HTTPServerTests testBindsToLoopback]' started.
Test Case '-[KiteloopTests.HTTPServerTests testBindsToLoopback]' skipped (0.001 seconds).
LOG
)
check 'a failed or a skipped case closes too — neither is hung' '—' "$actual"

# A build killed mid-flight can leave more than one case open, and all of them
# are what it was doing. In the order the run opened them, which is the order the
# failing and skipped cells beside this one are written in.
actual=$(hung_for <<'LOG'
Test Case '-[KiteloopTests.AlphaTests testOne]' started.
Test Case '-[KiteloopTests.BetaTests testTwo]' started.
Test Case '-[KiteloopTests.GammaTests testThree]' started.
Test Case '-[KiteloopTests.BetaTests testTwo]' passed (0.002 seconds).
LOG
)
check 'several cases left open — all named, in the order the run opened them' \
  'KiteloopTests.AlphaTests.testOne, KiteloopTests.GammaTests.testThree' "$actual"

# XCTest announces a case once per suite it is nested under, exactly as it
# reports a failing or a skipped one; the same name twice says nothing the first
# one did not.
actual=$(hung_for <<'LOG'
Test Case '-[KiteloopTests.HookEngineTests testATimedOutHookIsStopped]' started.
Test Case '-[KiteloopTests.HookEngineTests testATimedOutHookIsStopped]' started.
LOG
)
check 'a hung name repeated per enclosing suite is recorded once' \
  'KiteloopTests.HookEngineTests.testATimedOutHookIsStopped' "$actual"

# And the same nesting on a case that did come back: every open is closed, so
# there is nothing left over to name.
actual=$(hung_for <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' started.
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' started.
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' passed (0.002 seconds).
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' passed (0.002 seconds).
LOG
)
check 'a repeated name with all its closes is not hung either' '—' "$actual"

# The ceiling's other shape: a build wedged before testing ever started, which is
# the row at 3eaccf6a — no case had opened, so there is no test to name and the
# cell says so the way its neighbours do.
actual=$(hung_for <<'LOG'
Build settings from command line:
    ONLY_ACTIVE_ARCH = YES

CompileSwift normal arm64 /Users/someone/kiteloop/Kiteloop/Orchestrator.swift
LOG
)
check 'a build wedged before any test started — a dash, not an empty cell' \
  '—' "$actual"

# The two readers are separate answers to separate questions, over one log: a run
# that failed a test and then died mid-case reads red in the failing cell exactly
# as it always has, and nothing from this reader reaches a row whose tally is not
# the ceiling's.
cat >"$tmp/mixed" <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
Test Case '-[KiteloopTests.HookEngineTests testATimedOutHookIsStopped]' started.
LOG
actual="$(failing_tests_from_log "$tmp/mixed")
$(hung_tests_from_log "$tmp/mixed")"
check 'the failing cell and the hung one answer separately over one log' \
  'KiteloopTests.SkillTests.testProfileLoads
KiteloopTests.HookEngineTests.testATimedOutHookIsStopped' "$actual"

# --last labels that cell by what the tally beside it says the row is. A ceiling
# row's names are cases that never came back, and `failing` for them invites the
# reading that the test failed and the run then stopped — when nothing failed at
# all. Read through the whole readout, so the label, its alignment and its place
# in row order are asserted together.
actual=$(readout_for <<'RECORD' | sed -n '/^  bundle /,/^  elapsed /p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-21T07:17:17Z | 3eaccf6a | clean | no tally — xcodebuild ran past its 1800s time limit and was ended | 143 | none named in the output | KiteloopTests.HookEngineTests.testATimedOutHookIsStopped | — | 1801s |
RECORD
)
check 'a ceiling row reads out as hung, in the failing cell'"'"'s place' \
  '  bundle  none named in the output
  hung    KiteloopTests.HookEngineTests.testATimedOutHookIsStopped
  elapsed 1801s' "$actual"

# And a red row is untouched: the same label it has always had, and no hung line
# beside it.
red_row=$(cat <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✘ 3058 tests, 1 failing test (1 failure) | 65 | Test-Kiteloop.xcresult | KiteloopTests.SkillTests.testProfileLoads | — | 254s |
RECORD
)
check 'a red row still reads out under failing' \
  'KiteloopTests.SkillTests.testProfileLoads' \
  "$(printf '%s\n' "$red_row" | failing_readout_for)"
check 'and prints no hung line at all' \
  '' "$(printf '%s\n' "$red_row" | hung_readout_for)"

# A green row keeps its `failing —` line, which is what nearly every row in the
# record carries: the dash is passed over only under the hung label, where it
# would be a second way of saying the run had not got that far.
green_row=$(cat <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — | — | 254s |
RECORD
)
check 'a green row still prints its failing dash' \
  '—' "$(printf '%s\n' "$green_row" | failing_readout_for)"

# A ceiling row that named no test — the wedged-in-compilation shape — prints no
# line under either label, rather than a dash on a line of its own.
actual=$(readout_for <<'RECORD' | sed -n '/^  bundle /,/^  elapsed /p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-21T07:17:17Z | 3eaccf6a | clean | no tally — xcodebuild ran past its 1800s time limit and was ended | 143 | none named in the output | — | — | 1801s |
RECORD
)
check 'a ceiling row that named no test — no line under either label' \
  '  bundle  none named in the output
  elapsed 1801s' "$actual"

# And a ceiling row from before the failing column existed: an empty cell is not
# a name, and the line is omitted rather than printed blank or filled from the
# cell next door.
actual=$(hung_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle |
| --- | --- | --- | --- | --- | --- |
| 2026-08-21T07:17:17Z | 3eaccf6a | clean | no tally — xcodebuild ran past its 1800s time limit and was ended | 143 | none named in the output |
RECORD
)
check 'a ceiling row predating the column — no line, not an empty one' '' "$actual"

# --- A row appended onto a record that lost its final newline -----------------
#
# The record is a file like any other, and a file can end mid-line: a hand edit,
# a partial write, a copy that dropped the last byte. A row appended there used
# to be glued onto the truncated line rather than following it, and the two
# become one line that table_rows matches once — so show_last reads the *older*
# row's cells out of it and reports the run before this one as the last one
# taken. The measurement is in the file and invisible. These cases drive
# append_record against throwaway records, which is the only way this is
# exercised: docs/suite-status.md is written by runs, not by tests.

# The three lines of a record whose last one never got its terminator — printf
# with no trailing \n on the row, so the file really does end mid-line.
truncated=$tmp/truncated-record.md
printf '%s\n%s\n%s' \
  '| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |' \
  '| --- | --- | --- | --- | --- | --- | --- | --- | --- |' \
  '| 2026-08-12T08:00:00Z | 0ld7ow5 | clean | ✔ 3057 tests passed | 0 | Older.xcresult | — | — | 250s |' \
  >"$truncated"
append_record "$truncated" 2026-08-12T09:00:00Z abc1234 clean \
  '✔ 3058 tests passed' 0 Test-Kiteloop.xcresult '—' '—' 254s '—'

check 'a row onto a truncated last line — two rows, not one merged line' \
  '| 2026-08-12T08:00:00Z | 0ld7ow5 | clean | ✔ 3057 tests passed | 0 | Older.xcresult | — | — | 250s |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — | — | 254s | — |' \
  "$(table_rows "$truncated")"

check 'and the newest record is the row just written, not the one it fell onto' \
  '| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — | — | 254s | — |' \
  "$(newest_record "$truncated")"

# What a person reading --last is actually asking for: the cells of the run that
# just finished. Read off the repaired record, through show_last, because the
# glued line is well-formed enough that every one of these came back from the
# older row instead.
check '--last over a repaired record reads the newest run, not the one before it' \
  'run-unit-suite: last recorded run
  when    2026-08-12T09:00:00Z
  commit  abc1234 (clean tree)
  tally   ✔ 3058 tests passed
  package —
  exit    0' \
  "$(show_last "$truncated" | sed -n '/^run-unit-suite: last recorded run$/,/^  exit /p')"

# And the ordinary case, which is every run: a record already ending in a
# newline gains the row and nothing else. A guard that prepended unconditionally
# would leave a blank line between every pair of rows.
terminated=$tmp/terminated-record.md
printf '%s\n%s\n%s\n' \
  '| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |' \
  '| --- | --- | --- | --- | --- | --- | --- | --- | --- |' \
  '| 2026-08-12T08:00:00Z | 0ld7ow5 | clean | ✔ 3057 tests passed | 0 | Older.xcresult | — | — | 250s |' \
  >"$terminated"
cp "$terminated" "$tmp/terminated-before.md"
size_before=$(wc -c <"$terminated" | tr -d ' ')
append_record "$terminated" 2026-08-12T09:00:00Z abc1234 clean \
  '✔ 3058 tests passed' 0 Test-Kiteloop.xcresult '—' '—' 254s '—'

check 'a terminated record grows by exactly one line' \
  4 "$(wc -l <"$terminated" | tr -d ' ')"

check 'and the row lands under the last one, with no blank line between them' \
  '| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T08:00:00Z | 0ld7ow5 | clean | ✔ 3057 tests passed | 0 | Older.xcresult | — | — | 250s |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — | — | 254s | — |' \
  "$(cat "$terminated")"

# Byte-for-byte rather than line-for-line: a row already in the record is a
# measurement somebody took, so the bytes it was written with have to still be
# the record's first bytes after this one is appended.
if head -c "$size_before" "$terminated" | cmp -s - "$tmp/terminated-before.md"; then
  untouched=unchanged
else
  untouched=changed
fi
check 'the bytes the record already carried are byte-for-byte its first bytes' \
  unchanged "$untouched"

# --- How long it took ---------------------------------------------------------
#
# The cell no other one implies: every column beside it says what the run found,
# and none of them says what it cost, so "is the suite getting slower?" came down
# to somebody's memory of the last time they watched it scroll. These cases are
# the two stamps becoming a cell, and the cell being read back out.

check 'a four-minute run — the seconds between the two stamps' \
  '254s' "$(duration_cell 1786000000 1786000254)"

# A run measured inside one second is 0s, not an empty cell: it took a length of
# time, and the row saying so is what distinguishes it from a row written before
# the column existed.
check 'a run inside a second — 0s, which is still a reading' \
  '0s' "$(duration_cell 1786000000 1786000000)"

check 'a one-second run — no plural to get wrong, the unit is the unit' \
  '1s' "$(duration_cell 1786000000 1786000001)"

# The clock can step backwards mid-run — ntpd, or a laptop back from sleep with a
# corrected time. `-3s` is not a reading of anything, and a row carrying one
# would be worse than a row carrying 0s, because it would be believed.
check 'a clock that stepped backwards — 0s, not a negative duration' \
  '0s' "$(duration_cell 1786000254 1786000000)"

# The line --last prints about how long the run took, or empty when it prints
# none.
duration_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  elapsed //p'
}

actual=$(duration_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — | — | 254s |
RECORD
)
check '--last prints how long the run a row records took' '254s' "$actual"

# Every row in docs/suite-status.md was written before this column, and each of
# them still has to read out exactly as it did: no line here, and not the skipped
# cell borrowed from next door.
actual=$(duration_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T10:24:03Z | bf9dd36 | clean | ✔ 3364 tests passed (1 skipped) | 0 | Test-Kiteloop.xcresult | — | KiteloopTests.CopilotBridgeSocketTests.testCopilotBridgeSocketResponds |
RECORD
)
check 'a row predating the duration column — no line, not the cell next door' '' "$actual"

# And the oldest row of all, which predates every column after the exit one.
actual=$(duration_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle |
| --- | --- | --- | --- | --- | --- |
| 2026-08-10T23:13:22Z | 2984093 | clean | ✔ 3058 tests passed — 3040 XCTest, 18 swift-testing | 0 | not recorded |
RECORD
)
check 'a row predating four columns — still no line' '' "$actual"

# A cell that is present and empty prints nothing either, the way an empty bundle
# cell does — a blank line where a duration belongs reads as a duration of
# nothing.
actual=$(duration_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — | — |  |
RECORD
)
check 'an empty duration cell — no line, not a blank one' '' "$actual"

# A column arriving to the right of the skipped names must not be read as one of
# them, which is the mistake a reader counting from the end would make.
actual=$(skipped_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed (1 skipped) | 0 | Test-K.xcresult | — | KiteloopTests.HTTPServerTests.testBindsToLoopback | 254s |
RECORD
)
check 'a duration cell is not a skipped test' \
  'KiteloopTests.HTTPServerTests.testBindsToLoopback' "$actual"

# Where the line sits and how it is labelled: in row order, so after skipped and
# before the drift line, with its label padded to the same column as the rest —
# which is why the label is `elapsed` and the column is `duration`, exactly as
# the label is `bundle` for a column headed `result bundle`.
actual=$(readout_for <<'RECORD' | sed -n '/^  skipped /,/^  drift /p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | deadbee | clean | ✔ 3058 tests passed (1 skipped) | 0 | Test-K.xcresult | — | KiteloopTests.HTTPServerTests.testBindsToLoopback | 254s |
RECORD
)
check 'the elapsed line sits between skipped and drift, label aligned' \
  '  skipped KiteloopTests.HTTPServerTests.testBindsToLoopback
  elapsed 254s
  drift   unknown — git cannot resolve deadbee in this checkout.' "$actual"

# --- The package's own tally ---------------------------------------------------
#
# scripts/run-core-tests.sh closes a clean run of Kiteloop/KiteloopCore with one
# line of its own, `OK: KiteloopCore — …`, and the preflight loop captures that
# entry's whole output rather than letting it stream straight to the terminal —
# these cases are the reader that pulls the tally back out of it.

actual=$(core_tally_from_output 'Building for debugging...
Build complete!
OK: KiteloopCore — Executed 214 tests, with 0 failures (0 unexpected) in 3.402 (3.501) seconds')
check 'the tally on the OK line, read past the build noise ahead of it' \
  'Executed 214 tests, with 0 failures (0 unexpected) in 3.402 (3.501) seconds' \
  "$actual"

# A dash — the way an unreadable tally is recorded everywhere else in this
# record — for a run that never closed an OK line at all: a red run prints
# `FAIL: …` instead, with nothing after it to read as a tally.
actual=$(core_tally_from_output 'Compiling KiteloopCoreTests SomeTest.swift
error: fatalError
FAIL: swift test exited 1 in Kiteloop/KiteloopCore')
check 'no OK line in the captured output — a dash, not an empty cell' '—' "$actual"

# And the other shape of "nothing to read": swift test itself closed with no
# XCTest tally to print — an outermost suite that never closed — which
# scripts/run-core-tests.sh already spells out in the OK line rather than
# leaving it blank.
actual=$(core_tally_from_output 'OK: KiteloopCore — no XCTest tally printed')
check 'the OK line names no tally of its own — a dash' '—' "$actual"

# The captured output is empty outright when the preflight loop never reached
# this entry — the same reading as the two cases above, from nothing at all
# rather than from a line naming nothing.
actual=$(core_tally_from_output '')
check 'no captured output at all — a dash' '—' "$actual"

# The line --last prints about the package's own tally, beside the app-hosted
# one, or empty when it prints none.
package_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  package //p'
}

actual=$(package_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration | package tally |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — | — | 254s | Executed 214 tests, with 0 failures (0 unexpected) in 3.402 (3.501) seconds |
RECORD
)
check '--last prints the package tally a row records' \
  'Executed 214 tests, with 0 failures (0 unexpected) in 3.402 (3.501) seconds' "$actual"

# A run whose own core tally could not be read still carries a dash rather than
# an empty cell, and --last prints that dash exactly as it prints any other.
actual=$(package_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration | package tally |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — | — | 254s | — |
RECORD
)
check 'a row whose core tally could not be read — the dash, printed' '—' "$actual"

# Every row in docs/suite-status.md was written before this column, and each of
# them still has to read out exactly as it did: no line here, not the duration
# cell borrowed from next door.
actual=$(package_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — | — | 254s |
RECORD
)
check 'a row predating the package tally column — no line, not the cell next door' '' "$actual"

# Where the line sits and how it is labelled: right beside the app-hosted
# tally, ahead of the exit cell, with its label padded to the same column as
# the rest.
actual=$(readout_for <<'RECORD' | sed -n '/^  tally /,/^  exit /p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration | package tally |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — | — | 254s | Executed 214 tests, with 0 failures (0 unexpected) in 3.402 (3.501) seconds |
RECORD
)
check 'the package line sits right after the app-hosted tally, label aligned' \
  '  tally   ✔ 3058 tests passed
  package Executed 214 tests, with 0 failures (0 unexpected) in 3.402 (3.501) seconds
  exit    0' "$actual"

# --- The output of a run that did not come back clean -------------------------
#
# A red row names what failed and cannot say why: the output went to a mktemp
# file the script removes on its way out, and the .xcresult bundle the row names
# is swept out of DerivedData within a day. The row at 349e40d names
# Test-Kiteloop-2026.08.10_23-23-02--1000.xcresult, which `find` no longer turns
# up, so the assertion that failed in testFullLifecycleWithCheckpoints is
# unrecoverable. These cases are the keeping of that output: where it goes, which
# runs get one, how many are kept, and what --last says about it.

log_root=$tmp/log-root
mkdir -p "$log_root"
checkout_root=$root
root=$log_root

# The path itself, called directly. The writer and --last agree about where a
# run's output lives only because they ask this one function, so what it returns
# for a `when` value is the whole of that agreement and is asserted here rather
# than inferred from the two ends matching.
check 'the path is derived from the when cell, with its colons made typeable' \
  "$log_root/.kiteloop/suite-logs/2026-08-12T09-00-00Z.log" \
  "$(suite_log_path 2026-08-12T09:00:00Z)"

# `kept` or `discarded` for a run that came back with this status, tally and
# failing cell.
keeps() {
  if run_output_is_worth_keeping "$1" "$2" "$3"; then
    printf 'kept'
  else
    printf 'discarded'
  fi
}

check 'a non-zero status — kept' \
  'kept' "$(keeps 65 '✘ 3058 tests, 1 failure' 'KiteloopTests.SkillTests.testProfileLoads')"

# A run that measured nothing exited 0 and is not a green run: no framework
# reported, so the output is the only account of what it did instead.
check 'no tally, whatever the status says — kept' \
  'kept' "$(keeps 0 '' '—')"

# The exit status can be 0 while tests failed under it — a tally reader that
# reads the names is exactly the thing that catches that — so the failing cell
# is asked as well rather than trusted to follow the status.
check 'tests named in the failing cell — kept' \
  'kept' "$(keeps 0 '✔ 3058 tests passed' 'KiteloopTests.SkillTests.testProfileLoads')"

# The ordinary run, which is nearly every run: nothing anyone will read, and
# keeping it would bury the handful that matter.
check 'a clean run — discarded' \
  'discarded' "$(keeps 0 '✔ 3058 tests passed (1 skipped)' '—')"

# The line --last prints about the kept output for a record with this content,
# or empty when it prints none.
log_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  log     //p'
}

# A row whose log is on disk. The file is put at the path suite_log_path gives,
# which is the same call the readout makes — a case that hard-coded the name
# would pass while the two ends disagreed.
kept_at=$(suite_log_path 2026-08-12T09:00:00Z)
mkdir -p "${kept_at%/*}"
printf 'the whole four minutes of it\n' >"$kept_at"
actual=$(log_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✘ 3058 tests, 1 failure | 65 | Test-K.xcresult | KiteloopTests.SkillTests.testProfileLoads | — |
RECORD
)
check '--last names the output the row it is reading left behind' "$kept_at" "$actual"

# Where the line sits and how it is labelled: after the row's own cells, which
# are the record, and before the drift line, which is about the tree. Its label
# is padded to the same column as the rest.
actual=$(readout_for <<'RECORD' | sed -n '/^  skipped /,/^  drift /p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | deadbee | clean | ✘ 3058 tests, 1 failure (1 skipped) | 65 | Test-K.xcresult | KiteloopTests.SkillTests.testProfileLoads | KiteloopTests.HTTPServerTests.testBindsToLoopback |
RECORD
)
check 'the log line sits between skipped and drift, label aligned' \
  "  skipped KiteloopTests.HTTPServerTests.testBindsToLoopback
  log     $kept_at
  drift   unknown — git cannot resolve deadbee in this checkout." "$actual"

# A green run kept no output, and a red one old enough to have been pruned has
# none left. Either way there is nothing to name, and the readout says nothing —
# not a blank line, and not the cell next door, which is what reading past a
# missing file would produce.
rm -f "$kept_at"
actual=$(log_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed | 0 | Test-K.xcresult | — | — |
RECORD
)
check 'no output on disk for this row — no line, not a blank one' '' "$actual"

# The rows already in docs/suite-status.md predate all of this and have no log
# either; the readout for them must read exactly as it did.
actual=$(log_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle |
| --- | --- | --- | --- | --- | --- |
| 2026-08-10T23:13:22Z | 2984093 | clean | ✔ 3058 tests passed — 3040 XCTest, 18 swift-testing | 0 | not recorded |
RECORD
)
check 'a row predating the kept output — still no line' '' "$actual"

# The bound. Twenty-one runs go in, oldest first; the twenty-first has to remove
# the first, not simply stop keeping. The names are UTC timestamps, so oldest
# and lexicographically first are the same row.
prune_root=$tmp/prune-root
mkdir -p "$prune_root"
root=$prune_root
printf 'one run of output\n' >"$tmp/prune-src"
for prune_index in $(seq -w 1 21); do
  keep_suite_log "$tmp/prune-src" "2026-08-12T09:00:${prune_index}Z"
done
prune_dir=$prune_root/.kiteloop/suite-logs
check 'the twenty-first run keeps twenty, not twenty-one' \
  '20' "$(ls -1 "$prune_dir" | grep -c '\.log$')"
check 'the one it removed is the oldest' \
  'absent' "$([ -e "$prune_dir/2026-08-12T09-00-01Z.log" ] && printf present || printf absent)"
check 'the second-oldest is still there — one was removed, not a batch' \
  'present' "$([ -e "$prune_dir/2026-08-12T09-00-02Z.log" ] && printf present || printf absent)"
check 'the newest is there, which is the whole point of keeping any' \
  'present' "$([ -e "$prune_dir/2026-08-12T09-00-21Z.log" ] && printf present || printf absent)"

root=$checkout_root

# --- A run that measured nothing ---------------------------------------------
#
# A run that matched no tests exits 0, because that is what xcodebuild returns
# for it, so its row carries `exit 0` beside a tally cell that says no framework
# reported anything. Read out cell by cell that was the readout of a green
# suite, line for line, with nothing anywhere saying the suite had not run —
# while `suite_record` in scripts/kiteloop-verify.py fails the same row outright.
# These cases are the line that closes that, and the row that must not get one.

# The line --last prints about a run that measured nothing, or empty when it
# prints none.
nothing_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  nothing //p'
}

actual=$(nothing_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | no tally — xcodebuild exited before running tests | 0 | ResultBundle.xcresult | — | — | 12s |
RECORD
)
check 'a row that states no tally — the readout says the run measured nothing' \
  "that run matched no tests, so nothing was measured — the exit above is xcodebuild's own status and not a passing suite." \
  "$actual"

# The ordinary row, which is nearly every row: the readout is what it always was,
# and a line saying nothing was measured over a row saying 3,058 tests were would
# be worse than no line at all.
actual=$(nothing_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✔ 3058 tests passed — 3040 XCTest, 18 swift-testing | 0 | ResultBundle.xcresult | — | — | 254s |
RECORD
)
check 'a row carrying a real tally — no line, not a blank one' '' "$actual"

# A red row states a measurement too — the tests that failed are in it — so it is
# not this line's business either, however little its verdict is worth.
actual=$(nothing_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean | ✘ 3058 tests, 1 failure | 65 | ResultBundle.xcresult | KiteloopTests.SkillTests.testProfileLoads | — | 254s |
RECORD
)
check 'a red row — a measurement, so no line about measuring nothing' '' "$actual"

# An empty cell states no tally either, and is read the same way here as it is by
# `suite_record` in scripts/kiteloop-verify.py: a row with no tally in it has no
# measurement in it, whichever way it came to say so.
actual=$(nothing_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | abc1234 | clean |  | 0 | ResultBundle.xcresult | — | — | 12s |
RECORD
)
check 'an empty tally cell — read as the no measurement it is' \
  "that run matched no tests, so nothing was measured — the exit above is xcodebuild's own status and not a passing suite." \
  "$actual"

# A row this script ended at its ceiling is read the same way, whatever
# non-zero exit status the killed process left behind.
actual=$(nothing_readout_for <<RECORD
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | abc1234 | clean | $(timeout_tally_cell 1800) | 143 | none named in the output | — | — | 1805s |
RECORD
)
check 'a row ended at its ceiling — the readout says the run measured nothing' \
  "that run matched no tests, so nothing was measured — the exit above is xcodebuild's own status and not a passing suite." \
  "$actual"

# Where the line sits and how it is labelled: after the row's own cells, which it
# qualifies, and before the drift line, which is about the tree rather than the
# record. A commit this checkout cannot resolve, so the last line is the fixed one
# rather than a count that moves with the repository.
actual=$(readout_for <<'RECORD' | sed -n '/^  failing /,/^  drift /p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | deadbee | clean | no tally — xcodebuild exited before running tests | 0 | none named in the output | — | — |
RECORD
)
check 'the nothing line sits between the cells and drift, label aligned' \
  "  failing —
  nothing that run matched no tests, so nothing was measured — the exit above is xcodebuild's own status and not a passing suite.
  drift   unknown — git cannot resolve deadbee in this checkout." "$actual"

# --- A run that disagreed with itself ----------------------------------------
#
# The newest row is the last measurement, not the only one, and a test that fails
# and then passes at one commit leaves two rows that say opposite things. Read
# from the newest alone the tree is green there; it is green on the second try,
# and the readout has to be able to tell the two apart.

# The line --last prints about earlier measurements at the same commit that
# disagreed, or empty when it prints none.
earlier_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  earlier //p'
}

# The pair docs/suite-status.md actually holds at 349e40d, six minutes apart. The
# names come from the red row, which is the row the newest one buries.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | clean | ✘ 3362 tests, 2 failures (1 skipped) — 3344 XCTest (2 failures), 18 swift-testing (0 failures) | 65 | Test-Kiteloop-2026.08.10_23-23-02--1000.xcresult | KiteloopTests.Phase2BIntegrationTests.testFullLifecycleWithCheckpoints |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed (1 skipped) — 3344 XCTest, 18 swift-testing | 0 | Test-Kiteloop-2026.08.10_23-29-36--1000.xcresult | — |
RECORD
)
check 'red then green at one commit — the red row is named, not buried' \
  '1 of 2 measurements at 349e40d recorded ✘ — KiteloopTests.Phase2BIntegrationTests.testFullLifecycleWithCheckpoints' \
  "$actual"

# The same pair with a skipped-tests cell after it. The failing names are read
# from their position in the row, so a column arriving to their right must not
# move what this line says — or let the new cell be read as a failure.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | clean | ✘ 3362 tests, 2 failures (1 skipped) | 65 | Test-A.xcresult | KiteloopTests.Phase2BIntegrationTests.testFullLifecycleWithCheckpoints | KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed (1 skipped) | 0 | Test-B.xcresult | — | KiteloopTests.HTTPServerTests.testBindsToLoopback |
RECORD
)
check 'a row carrying a skipped cell — the failing names still read from theirs' \
  '1 of 2 measurements at 349e40d recorded ✘ — KiteloopTests.Phase2BIntegrationTests.testFullLifecycleWithCheckpoints' \
  "$actual"

# The other direction is the same fact about the suite: something at this commit
# does not decide the same way twice. The green row has no failing cell to name,
# so the line is the count alone rather than a dangling separator.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | clean | ✔ 3362 tests passed | 0 | Test-A.xcresult | — |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✘ 3362 tests, 1 failure | 65 | Test-B.xcresult | KiteloopTests.SkillTests.testProfileLoads |
RECORD
)
check 'green then red at one commit — reported just the same' \
  '1 of 2 measurements at 349e40d recorded ✔' "$actual"

# A flaky test failing in each of several red rows is one name, said once: three
# copies of it would read as three different tests.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:00:00Z | 349e40d | clean | ✘ 3362 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-11T09:10:00Z | 349e40d | clean | ✘ 3362 tests, 2 failures | 65 | Test-B.xcresult | KiteloopTests.SkillTests.testProfileLoads, needsCycleReadsUnmet() |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed | 0 | Test-C.xcresult | — |
RECORD
)
check 'the same test red in two rows — counted twice, named once' \
  '2 of 3 measurements at 349e40d recorded ✘ — KiteloopTests.SkillTests.testProfileLoads, needsCycleReadsUnmet()' \
  "$actual"

# Two runs at one commit that agreed say nothing new, and the ordinary record —
# one row per commit — must stay exactly as it read before any of this.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | clean | ✔ 3362 tests passed | 0 | Test-A.xcresult | — |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'two rows at one commit that agree — no line, not a blank one' '' "$actual"

actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'a record holding a single row — nothing to disagree with' '' "$actual"

# The comparison is between measurements of the same tree. A red row at an
# earlier commit is not this commit disagreeing with itself; it is the ordinary
# history of a repository, and reporting it would fire on nearly every record.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 2e6d3d1 | clean | ✘ 3102 tests, 2 failures | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'a red row at a different commit — not a disagreement' '' "$actual"

# A row from before the result-bundle and failing-tests columns existed carries
# no names. It still counts as a measurement that disagreed; what it cannot do is
# contribute an empty field, a stray separator, or the cell next door.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit |
| --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | clean | ✘ 3362 tests, 2 failures | 65 |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed | 0 |
RECORD
)
check 'a row predating the columns — counted, with nothing to name' \
  '1 of 2 measurements at 349e40d recorded ✘' "$actual"

# A row stating a verdict in neither cell — no glyph on the tally, and nothing an
# integer can be read out of where the status goes — can neither disagree nor be
# disagreed with, and is passed over rather than guessed at.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | clean | no tally — xcodebuild exited before running tests |  | ResultBundle.xcresult | — |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'a row stating no verdict — not counted against one' '' "$actual"

# The row the readers used to disagree about. A tally spelled as one framework's
# line passed through verbatim carries no glyph, so reading the glyph left this
# row stating no verdict at all — invisible to the comparison — while
# `row_verdict` in scripts/kiteloop-verify.py read `exit 65` off the same row and
# called it red. Both read the exit cell now, so the red row is named here too.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | clean | 3344 XCTest (2 failures) | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-11T09:29:35Z | 349e40d | clean | 3362 XCTest (0 failures) | 0 | Test-B.xcresult | — |
RECORD
)
check 'a glyphless pair at one commit — read from the exit cells, and named' \
  '1 of 2 measurements at 349e40d recorded ✘ — KiteloopTests.SkillTests.testProfileLoads' \
  "$actual"

# The newest row's own verdict comes from the same cell. A glyphless green row
# buries a glyphless red one exactly as a green ✔ row buries a red ✘ one, so the
# `earlier` line has to fire from the newest row's status as well as from the
# earlier rows' — reading only theirs would leave this record silent.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | clean | ✔ 3362 tests passed | 0 | Test-A.xcresult | — |
| 2026-08-11T09:29:35Z | 349e40d | clean | 3362 XCTest (1 failure) | 65 | Test-B.xcresult | KiteloopTests.SkillTests.testProfileLoads |
RECORD
)
check 'a glyphless newest row — its own verdict read from its exit cell too' \
  '1 of 2 measurements at 349e40d recorded ✔' "$actual"

# A record laid out before the `exit` column existed. The cell in that position
# holds a bundle name rather than a status, and no integer can be read out of it,
# so both rows fall back to their tally glyphs and the pair reads as it always
# did.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | result bundle |
| --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | clean | ✘ 3362 tests, 1 failure | Test-A.xcresult |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed | Test-B.xcresult |
RECORD
)
check 'no integer where the status goes — the tally glyph still read' \
  '1 of 2 measurements at 349e40d recorded ✘' "$actual"

# A row whose tree cell says dirty measured content the record cannot recover,
# so it is no reading of the commit it names — the same rule show_flakes
# applies. The only row that disagrees with the newest verdict is that dirty
# row, so there is nothing left to report.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | dirty | ✘ 3362 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'the only disagreeing row is dirty — no reading, so no line' '' "$actual"

# The same pair, the red row clean instead — the line still fires and still
# names it, so the dirty case above is the tree cell doing the work, not some
# other difference between the two records.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | 349e40d | clean | ✘ 3362 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'the same pair, clean — still reported and named' \
  '1 of 2 measurements at 349e40d recorded ✘ — KiteloopTests.SkillTests.testProfileLoads' \
  "$actual"

# A dirty row is left out of the count as well as the names: three rows at one
# commit, one of them dirty and disagreeing. Read correctly this is "1 of 2" —
# the dirty row counted in neither the total nor the tally against it.
actual=$(earlier_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:00:00Z | 349e40d | dirty | ✘ 3362 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-11T09:15:00Z | 349e40d | clean | ✘ 3362 tests, 1 failure | 65 | Test-B.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-11T09:29:35Z | 349e40d | clean | ✔ 3362 tests passed | 0 | Test-C.xcresult | — |
RECORD
)
check 'a dirty row among three at one commit — left out of the count, not just the name' \
  '1 of 2 measurements at 349e40d recorded ✘ — KiteloopTests.SkillTests.testProfileLoads' \
  "$actual"

# Where the line sits and how it is labelled: after the newest row's own cells,
# which it qualifies, and before the drift line, which is about the tree rather
# than the record. A commit this checkout cannot resolve, so the last line is the
# fixed one rather than a count that moves with the repository.
actual=$(readout_for <<'RECORD' | sed -n '/^  failing /,/^  drift /p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | deadbee | clean | ✘ 3362 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-11T09:29:35Z | deadbee | clean | ✔ 3362 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'the earlier line sits between failing and drift, label aligned' \
  '  failing —
  earlier 1 of 2 measurements at deadbee recorded ✘ — KiteloopTests.SkillTests.testProfileLoads
  drift   unknown — git cannot resolve deadbee in this checkout.' "$actual"

# --- A test that did not decide the same way at two commits -------------------
#
# The line above compares rows at one commit. A test that fails at one commit and
# passes at the next leaves rows no comparison of that shape can see, and the
# readout answered green off the newest row and remembered nothing —
# docs/suite-status.md holds that pair twice, and both cost somebody a chase.

# The line --last prints about tests a recent row recorded red and a later row
# recorded green, or empty when it prints none.
flaky_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  flaky   //p'
}

# The pair the record actually holds at fdcf4add, with the green row that buries
# it sitting at the next commit rather than at the same one — which is exactly
# why the earlier line cannot see it.
actual=$(flaky_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T22:57:33Z | fdcf4add | clean | ✘ 4242 tests, 1 failing test (1 failure) | 65 | Test-A.xcresult | KiteloopTests.SessionTitleGeneratorTests.testEmptyAnswerIsNoTitle | — | 462s |
| 2026-08-20T23:41:02Z | 84ca7ca5 | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — | — | 458s |
RECORD
)
check 'red at one commit, green at the next — named, where the earlier line is silent' \
  '1 test recorded ✘ at an earlier commit and ✔ since — KiteloopTests.SessionTitleGeneratorTests.testEmptyAnswerIsNoTitle' \
  "$actual"

# The claim is that the test has passed since, so a test the newest row still
# has red is not one of them — however many green rows sit between its two red
# readings. The readout has just printed that name on its own `failing` line.
actual=$(flaky_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T22:57:33Z | fdcf4add | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-20T23:41:02Z | 84ca7ca5 | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
| 2026-08-21T09:23:01Z | f4405428 | clean | ✘ 4242 tests, 1 failure | 65 | Test-C.xcresult | KiteloopTests.SkillTests.testProfileLoads |
RECORD
)
check 'still red in the newest row — not reported as having passed since' '' "$actual"

# And the same record, with a second test that is not red in the newest row: the
# newest row's own failure is passed over, the other name is not.
actual=$(flaky_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T22:57:33Z | fdcf4add | clean | ✘ 4242 tests, 2 failures | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads, needsCycleReadsUnmet() |
| 2026-08-20T23:41:02Z | 84ca7ca5 | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
| 2026-08-21T09:23:01Z | f4405428 | clean | ✘ 4242 tests, 1 failure | 65 | Test-C.xcresult | KiteloopTests.SkillTests.testProfileLoads |
RECORD
)
check 'the one that is still red is dropped, the one that is not is named' \
  '1 test recorded ✘ at an earlier commit and ✔ since — needsCycleReadsUnmet()' \
  "$actual"

# A test red in each of several rows is one name, said once — three copies of it
# would read as three different tests — and the count says tests, not readings.
actual=$(flaky_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | 0bf5dabe | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-20T10:00:00Z | 345c3eb1 | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
| 2026-08-20T22:57:33Z | fdcf4add | clean | ✘ 4242 tests, 2 failures | 65 | Test-C.xcresult | KiteloopTests.SkillTests.testProfileLoads, KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-20T23:41:02Z | 84ca7ca5 | clean | ✔ 4242 tests passed | 0 | Test-D.xcresult | — |
RECORD
)
check 'the same test red in two rows — one name, said once' \
  '2 tests recorded ✘ at an earlier commit and ✔ since — KiteloopTests.SkillTests.testProfileLoads, KiteloopTests.HTTPServerTests.testBindsToLoopback' \
  "$actual"

# The ordinary record — green run after green run — must read exactly as it did
# before any of this.
actual=$(flaky_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | 0bf5dabe | clean | ✔ 4242 tests passed | 0 | Test-A.xcresult | — |
| 2026-08-20T10:00:00Z | 345c3eb1 | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'no red row in the window — no line, not a blank one' '' "$actual"

# A red row and a green one at the newest commit is the shape the earlier line
# already reports, and reporting it here too would print one pair of rows twice
# under two labels. Asserted through the whole readout, so the case says which
# line does report it rather than only that this one does not.
actual=$(readout_for <<'RECORD' | sed -n '/^  failing /,/^  drift /p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-11T09:23:01Z | deadbee | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-11T09:29:35Z | deadbee | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'red rows only at the newest commit — the earlier line alone reports them' \
  '  failing —
  earlier 1 of 2 measurements at deadbee recorded ✘ — KiteloopTests.SkillTests.testProfileLoads
  drift   unknown — git cannot resolve deadbee in this checkout.' "$actual"

# The window is bounded, so the readout keeps saying something about the runs
# around it rather than about every red row the file has ever held. A record of
# twenty-one rows whose oldest is the only red one: it is still in the file, and
# it is one row past what this line reads.
{
  printf '| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |\n'
  printf '| --- | --- | --- | --- | --- | --- | --- |\n'
  printf '| 2026-08-20T00:00:00Z | 0bf5dabe | clean | ✘ 4242 tests, 1 failure | 65 | Test-old.xcresult | KiteloopTests.SkillTests.testProfileLoads |\n'
  for i in $(seq 1 20); do
    printf '| 2026-08-20T%02d:00:00Z | 345c3eb%d | clean | ✔ 4242 tests passed | 0 | Test-%d.xcresult | — |\n' \
      "$i" "$i" "$i"
  done
} >"$tmp/window"
actual=$(flaky_readout_for <"$tmp/window")
check 'a red row one past the window — still in the file, not in the line' '' "$actual"

# And the same record with one green row taken out, so that red row is the
# twentieth: the boundary is where it is said to be, not one row either side.
{
  head -n 3 "$tmp/window"
  tail -n 19 "$tmp/window"
} >"$tmp/window-edge"
actual=$(flaky_readout_for <"$tmp/window-edge")
check 'the same red row inside the window — named' \
  '1 test recorded ✘ at an earlier commit and ✔ since — KiteloopTests.SkillTests.testProfileLoads' \
  "$actual"

# A row that states no verdict — a run this script ended at its ceiling, whose
# names are cases that never came back rather than reported failures — is neither
# a red reading to report nor a green one to report an earlier row against.
actual=$(flaky_readout_for <<RECORD
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | 0bf5dabe | clean | $(timeout_tally_cell 1800) | 143 | Test-A.xcresult | KiteloopTests.HookEngineTests.testTimeout |
| 2026-08-20T10:00:00Z | 345c3eb1 | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'a run ended at its ceiling — hung is not red, and is not reported' '' "$actual"

# A red row from before the failing-tests column existed has no name to offer.
# What it must not do is contribute an empty field or a stray separator.
actual=$(flaky_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit |
| --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | 0bf5dabe | clean | ✘ 4242 tests, 1 failure | 65 |
| 2026-08-20T10:00:00Z | 345c3eb1 | clean | ✔ 4242 tests passed | 0 |
RECORD
)
check 'a red row predating the names column — nothing to name, so no line' '' "$actual"

# A dirty row is no reading of the commit it names, the same rule show_flakes
# and the earlier line apply. The only red row is dirty, so there is nothing
# this line can call a test that passed since.
actual=$(flaky_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T22:57:33Z | fdcf4add | dirty | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SessionTitleGeneratorTests.testEmptyAnswerIsNoTitle |
| 2026-08-20T23:41:02Z | 84ca7ca5 | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'the only red row is dirty — no reading, so no line' '' "$actual"

# A dirty green row must not grant a red row its "✔ since" either: the skip has
# to apply to the row that would set seen_green, not only to a red row naming a
# test. Here the newest row is the only green one and it is dirty, so there is
# no green reading anywhere in the window for the older red row to be flaky
# against.
actual=$(flaky_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | 0bf5dabe | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-20T10:00:00Z | 345c3eb1 | dirty | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'the only green row is dirty — no reading, so no line' '' "$actual"

# The dirty skip has to apply to the newest row that fills newest_failing too,
# not only to the rows that contribute names. Read newest first: a dirty red
# row at the newest commit, a clean green row behind it, and an older clean red
# row naming the same test as the dirty one. Trusting the dirty row's name
# would mark that test "still red" and hide the fact that a clean row shows it
# passing since; skipping the dirty row correctly leaves the newest reading to
# the clean green row instead, and the older red row is reported.
actual=$(flaky_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | aaaaaaa | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-20T10:00:00Z | bbbbbbb | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
| 2026-08-20T11:00:00Z | ccccccc | dirty | ✘ 4242 tests, 1 failure | 65 | Test-C.xcresult | KiteloopTests.SkillTests.testProfileLoads |
RECORD
)
check 'the newest row is dirty — its red name does not mark the test still red' \
  '1 test recorded ✘ at an earlier commit and ✔ since — KiteloopTests.SkillTests.testProfileLoads' \
  "$actual"

# --last is the readout you reach for while Kiteloop is up, and a new reader in
# it is a new chance to start something. Driven with a record this line does have
# something to say about, so the reading is asserted over the path that does the
# work rather than over the one that returns early.
flaky_shims=$tmp/flaky-shims
mkdir -p "$flaky_shims"
for shim in xcodebuild pgrep; do
  printf '#!/bin/sh\nprintf %%s "$0" >>"%s/flaky-called"\n' "$tmp" >"$flaky_shims/$shim"
  chmod +x "$flaky_shims/$shim"
done
rm -f "$tmp/flaky-called"
saved_path=$PATH
PATH="$flaky_shims:$PATH"
actual=$(flaky_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | 0bf5dabe | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-20T10:00:00Z | 345c3eb1 | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
PATH=$saved_path
check 'the line reads the record and nothing else — no build, no process list' \
  '' "$(cat "$tmp/flaky-called" 2>/dev/null)"
check 'and still says what it read' \
  '1 test recorded ✘ at an earlier commit and ✔ since — KiteloopTests.SkillTests.testProfileLoads' \
  "$actual"

# Where the line sits and how it is labelled: under the earlier line it stands
# beside, and above the drift line, which is about the tree rather than the
# record. Both fire here — the red row at the newest commit for the one, the
# older red row for the other — which is also the case that says the two lines
# report different rows rather than the same one twice.
actual=$(readout_for <<'RECORD' | sed -n '/^  failing /,/^  drift /p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | 0bf5dabe | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-20T10:00:00Z | deadbee | clean | ✘ 4242 tests, 1 failure | 65 | Test-B.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-20T11:00:00Z | deadbee | clean | ✔ 4242 tests passed | 0 | Test-C.xcresult | — |
RECORD
)
check 'the flaky line sits between earlier and drift, label aligned' \
  '  failing —
  earlier 1 of 2 measurements at deadbee recorded ✘ — KiteloopTests.SkillTests.testProfileLoads
  flaky   1 test recorded ✘ at an earlier commit and ✔ since — KiteloopTests.HTTPServerTests.testBindsToLoopback
  drift   unknown — git cannot resolve deadbee in this checkout.' "$actual"

# --- --flakes: the same question, over the whole record ----------------------
#
# flaky_line above, and the line it feeds into --last, read the newest
# FLAKY_WINDOW_ROWS rows and cannot decide a flake from a fix — it names both
# shapes and says so. --flakes reads every row the file holds and narrows to the
# one shape a record can call a flake without guessing: red and green recorded
# at the same commit.

flakes_readout_for() {
  cat >"$tmp/record"
  show_flakes "$tmp/record"
}

# An empty record answers cleanly rather than failing over nothing to read.
actual=$(flakes_readout_for </dev/null)
check 'an empty record — no run to read, and it says so rather than failing' \
  'run-unit-suite: no suite run has been recorded yet in docs/suite-status.md.' \
  "$(printf '%s\n' "$actual" | head -n 1)"

# A record with rows but nothing that ever flipped — the ordinary green-after-
# green history — states plainly that it found nothing, rather than printing a
# heading over a blank list.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | 0bf5dabe | clean | ✔ 4242 tests passed | 0 | Test-A.xcresult | — |
| 2026-08-20T10:00:00Z | 345c3eb1 | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'no test ever flipped — one line saying so, not a bare heading' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 2 rows in docs/suite-status.md.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"

# The genuine shape: red, then green, at the same commit, both rows clean — a
# rerun of identical code deciding two ways. Listed, with the one commit and
# the span of rows it took.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-23T12:30:56Z | ecc81079 | clean | ✘ 4455 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.KnowledgeIndexSearchTests.testOwnScopeReturnsOnlyThatAgentsChunks |
| 2026-08-23T12:35:17Z | ecc81079 | clean | ✔ 4455 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'a same-commit flip over two clean rows — listed, with the one commit involved' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 2 rows in docs/suite-status.md.
  KiteloopTests.KnowledgeIndexSearchTests.testOwnScopeReturnsOnlyThatAgentsChunks
    1 flip at ecc81079 — 2026-08-23T12:30:56Z .. 2026-08-23T12:35:17Z' \
  "$actual"

# The same shape, but one or both rows are dirty — the uncommitted content
# each measured is unknown and unrecoverable, so neither is a reading of
# ecc81079 and the pair must not read as a flip. This is the real shape found
# in this repo's own docs/suite-status.md: four rows at ecc81079 all dirty.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-23T12:30:56Z | ecc81079 | dirty | ✘ 4455 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.KnowledgeIndexSearchTests.testOwnScopeReturnsOnlyThatAgentsChunks |
| 2026-08-23T12:35:17Z | ecc81079 | dirty | ✔ 4455 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'a same-commit flip over two dirty rows — no reading, so no flip' \
  'run-unit-suite: flake ledger
run-unit-suite: read 0 of 2 rows in docs/suite-status.md — skipped 2 with a dirty tree.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"

# Only one of the pair dirty is still no reading for the flip: the dirty row's
# tree is unknown, so the commit has only one usable row and nothing to
# compare it against.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-23T12:30:56Z | ecc81079 | dirty | ✘ 4455 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.KnowledgeIndexSearchTests.testOwnScopeReturnsOnlyThatAgentsChunks |
| 2026-08-23T12:35:17Z | ecc81079 | clean | ✔ 4455 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'one row dirty, the other clean, at one commit — still no flip' \
  'run-unit-suite: flake ledger
run-unit-suite: read 1 of 2 rows in docs/suite-status.md — skipped 1 with a dirty tree.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"

# The shape flaky_line calls a fix rather than a flake: red at one commit, green
# only from a later one — no row ever disagrees with another at the same
# commit. Not listed, the way the acceptance criteria for this command ask.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-21T09:23:01Z | f4405428 | clean | ✘ 4409 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.CoordinatorQueueRefillTests.testEachStalledPassIsCountedOnceHoweverItWasEnded |
| 2026-08-21T09:37:29Z | b7c6214c | clean | ✔ 4409 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'a fix at a later commit — not a flip, so not listed' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 2 rows in docs/suite-status.md.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"

# A test that flips at one commit and is later fixed for good at a different
# one: one flip is real, the fix beside it is not, and the ledger counts only
# the one the record can call a flake without guessing.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | aaaaaaa | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-20T10:00:00Z | aaaaaaa | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
| 2026-08-20T11:00:00Z | bbbbbbb | clean | ✘ 4242 tests, 1 failure | 65 | Test-C.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-20T12:00:00Z | ccccccc | clean | ✔ 4242 tests passed | 0 | Test-D.xcresult | — |
RECORD
)
check 'one same-commit flip and one later fix — the flip counted once, the fix left out' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 4 rows in docs/suite-status.md.
  KiteloopTests.SkillTests.testProfileLoads
    1 flip at aaaaaaa — 2026-08-20T09:00:00Z .. 2026-08-20T10:00:00Z' \
  "$actual"

# A test named failing in every row recorded at a commit — never green there,
# however many rows it took — is not a flip: there is no row at that commit to
# read it as green against. Two red rows, one name, and neither ever green.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | aaaaaaa | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-08-20T10:00:00Z | aaaaaaa | clean | ✘ 4242 tests, 1 failure | 65 | Test-B.xcresult | KiteloopTests.SkillTests.testProfileLoads |
RECORD
)
check 'red in every row at the commit, never green there — not a flip, and not named' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 2 rows in docs/suite-status.md.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"

# Two tests at the same commit, only one of which is ever named beside a green
# row — the other's unrelated red name must not leak a flip verdict onto it.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | aaaaaaa | clean | ✘ 4242 tests, 2 failures | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads, KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-20T10:00:00Z | aaaaaaa | clean | ✘ 4242 tests, 1 failure | 65 | Test-B.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-20T11:00:00Z | aaaaaaa | clean | ✔ 4242 tests passed | 0 | Test-C.xcresult | — |
RECORD
)
check 'both named failing at one commit that later went green — both are flips' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 3 rows in docs/suite-status.md.
  KiteloopTests.SkillTests.testProfileLoads
    1 flip at aaaaaaa — 2026-08-20T09:00:00Z .. 2026-08-20T11:00:00Z
  KiteloopTests.HTTPServerTests.testBindsToLoopback
    1 flip at aaaaaaa — 2026-08-20T09:00:00Z .. 2026-08-20T11:00:00Z' \
  "$actual"

# A red row naming no test — the exit cell and the tally text disagreeing about
# one run, rather than an ordinary failure — has no name to call red or green.
# It must contribute nothing, not a guess either way.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-23T13:10:33Z | ddddddd | dirty | ✔ 4374 tests passed | 65 | Test-A.xcresult | — |
| 2026-08-23T13:18:39Z | ddddddd | dirty | ✔ 4374 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'an exit/tally mismatch naming no test — contributes nothing, not a guess' \
  'run-unit-suite: flake ledger
run-unit-suite: read 0 of 2 rows in docs/suite-status.md — skipped 2 with a dirty tree.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"

# A row stating no verdict at all — this script's own ceiling row — is neither a
# red reading nor a green one, the same way flaky_line passes it over.
actual=$(flakes_readout_for <<RECORD
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-20T09:00:00Z | aaaaaaa | clean | $(timeout_tally_cell 1800) | 143 | Test-A.xcresult | KiteloopTests.HookEngineTests.testTimeout |
| 2026-08-20T10:00:00Z | aaaaaaa | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'a run ended at its ceiling — no verdict, so no reading either way' \
  'run-unit-suite: flake ledger
run-unit-suite: read 1 of 2 rows in docs/suite-status.md — skipped 1 with no verdict to read.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"

# A test named skipped in one row and failing in another row at the same
# commit — two readings of identical code, except one of them never ran the
# test. The skipped row is no reading for it, so it must not read as a flip.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration | package tally |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-23T13:00:00Z | aaaaaaa | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback | — | 500s | — |
| 2026-08-23T14:00:00Z | aaaaaaa | clean | ✔ 4241 tests passed | 0 | Test-B.xcresult | — | KiteloopTests.HTTPServerTests.testBindsToLoopback | 500s | — |
RECORD
)
check 'skipped at a commit in one row, failing at the same commit in another — not a flip' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 2 rows in docs/suite-status.md.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"

# The same shape, but the second row genuinely passed the test rather than
# skipping it — a real flip, and it must still be reported with the skipped
# cell present and empty.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests | skipped tests | duration | package tally |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-08-23T13:00:00Z | aaaaaaa | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback | — | 500s | — |
| 2026-08-23T14:00:00Z | aaaaaaa | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — | — | 500s | — |
RECORD
)
check 'a genuine same-commit flip with the skipped column present — still listed' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 2 rows in docs/suite-status.md.
  KiteloopTests.HTTPServerTests.testBindsToLoopback
    1 flip at aaaaaaa — 2026-08-23T13:00:00Z .. 2026-08-23T14:00:00Z' \
  "$actual"

# A narrow, old-shape row with no skipped-tests column at all — read leaves
# skipped empty, exactly as it does for a row with a dash there.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-23T13:00:00Z | aaaaaaa | clean | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-23T14:00:00Z | aaaaaaa | clean | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'an old-shape row with no skipped-tests column — reads exactly as before' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 2 rows in docs/suite-status.md.
  KiteloopTests.HTTPServerTests.testBindsToLoopback
    1 flip at aaaaaaa — 2026-08-23T13:00:00Z .. 2026-08-23T14:00:00Z' \
  "$actual"

# --- How much of the record was read at all -----------------------------------
#
# Every skip above is silent, and "none" then says two different things in one
# sentence: no test flipped, and no row was readable. The record in this repo on
# 2026-09-10 is the second — every row of it dirty — and the ledger read like the
# first. One line after the header says which, by counting the rows the loop
# skipped as it skipped them.

# The blind record: every row dirty, so the reading has nothing to compare and
# says so, still prints its "none —" line, and still exits 0.
all_dirty_record='| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-09-10T09:00:00Z | aaaaaaa | dirty | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-09-10T10:00:00Z | aaaaaaa | dirty | ✔ 4242 tests passed | 0 | Test-B.xcresult | — |
| 2026-09-10T11:00:00Z | bbbbbbb | dirty | ✔ 4242 tests passed | 0 | Test-C.xcresult | — |'

actual=$(flakes_readout_for <<RECORD
$all_dirty_record
RECORD
)
flakes_status=$?
check 'every row dirty — the ledger says it read none of them, and why' \
  'run-unit-suite: flake ledger
run-unit-suite: read 0 of 3 rows in docs/suite-status.md — skipped 3 with a dirty tree.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"
check 'a blind record is still not a failure' '0' "$flakes_status"

# A clean red row naming no test — the exit cell and the tally text disagreeing
# about one run. Counted under its own reason rather than folded into the dirty
# count, since the two are different silences.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-09-10T09:00:00Z | aaaaaaa | clean | ✔ 4374 tests passed | 65 | Test-A.xcresult | — |
| 2026-09-10T10:00:00Z | aaaaaaa | clean | ✔ 4374 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'a clean red row naming no test — counted under its own reason' \
  'run-unit-suite: flake ledger
run-unit-suite: read 1 of 2 rows in docs/suite-status.md — skipped 1 red naming no test.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"

# All three reasons at once, over a record that also holds a real flip: the
# ledger body is what it would print without the skipped rows, and the line above
# it names each reason with the count that reason skipped.
actual=$(flakes_readout_for <<RECORD
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-09-10T09:00:00Z | aaaaaaa | dirty | ✘ 4242 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.SkillTests.testProfileLoads |
| 2026-09-10T10:00:00Z | aaaaaaa | clean | $(timeout_tally_cell 1800) | 143 | Test-B.xcresult | KiteloopTests.HookEngineTests.testTimeout |
| 2026-09-10T11:00:00Z | aaaaaaa | clean | ✔ 4374 tests passed | 65 | Test-C.xcresult | — |
| 2026-09-10T12:00:00Z | aaaaaaa | clean | ✘ 4242 tests, 1 failure | 65 | Test-D.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-09-10T13:00:00Z | aaaaaaa | clean | ✔ 4242 tests passed | 0 | Test-E.xcresult | — |
RECORD
)
check 'three reasons at once — each named with its own count, the flip still listed' \
  'run-unit-suite: flake ledger
run-unit-suite: read 2 of 5 rows in docs/suite-status.md — skipped 1 with a dirty tree, 1 with no verdict to read, 1 red naming no test.
  KiteloopTests.HTTPServerTests.testBindsToLoopback
    1 flip at aaaaaaa — 2026-09-10T12:00:00Z .. 2026-09-10T13:00:00Z' \
  "$actual"

# The line sits at the header's own indent. Two spaces is a test name to
# FlakeLedgerReader.read and four is that test's flip line, so a line at either
# would reach the coordinator as a finding about a test nobody wrote.
check 'the new line carries no leading space, so no reader takes it for a test' \
  '' "$(printf '%s\n' "$actual" | awk '/^[[:space:]].*rows in docs\/suite-status.md/')"

# A record with no rows at all is answered before any of this: there is no
# reading to report the coverage of, and the message is the one it has always
# printed.
actual=$(flakes_readout_for </dev/null)
check 'an empty record says nothing about skipped rows — there are none to skip' \
  'run-unit-suite: no suite run has been recorded yet in docs/suite-status.md.
Run the suite once — every finished run appends its own record.' \
  "$actual"

# --flakes reads the whole record and nothing else — no build, no process list —
# the same way --last stays usable while Kiteloop is up.
flakes_shims=$tmp/flakes-shims
mkdir -p "$flakes_shims"
for shim in xcodebuild pgrep; do
  printf '#!/bin/sh\nprintf %%s "$0" >>"%s/flakes-called"\n' "$tmp" >"$flakes_shims/$shim"
  chmod +x "$flakes_shims/$shim"
done
rm -f "$tmp/flakes-called"
saved_path=$PATH
PATH="$flakes_shims:$PATH"
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-23T12:30:56Z | ecc81079 | clean | ✘ 4455 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.KnowledgeIndexSearchTests.testOwnScopeReturnsOnlyThatAgentsChunks |
| 2026-08-23T12:35:17Z | ecc81079 | clean | ✔ 4455 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
PATH=$saved_path
check '--flakes reads the record and nothing else — no build, no process list' \
  '' "$(cat "$tmp/flakes-called" 2>/dev/null)"
check 'and still says what it read' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 2 rows in docs/suite-status.md.
  KiteloopTests.KnowledgeIndexSearchTests.testOwnScopeReturnsOnlyThatAgentsChunks
    1 flip at ecc81079 — 2026-08-23T12:30:56Z .. 2026-08-23T12:35:17Z' \
  "$actual"

# --- One commit, spelled at two widths ---------------------------------------
#
# The commit cell is a git abbreviation, and git's automatic width grows with
# the object store: docs/suite-status.md holds 92 cells eight characters wide
# and four seven. Read as plain strings, two clean measurements of one commit
# written at two widths are two commits, and each of the three readings that
# group rows by commit loses one of them — the pair below is invisible to
# --flakes, half-counted by the earlier line, and called a fix by the flaky
# line. Same commit, one row red and one green, spelled `2e6d3d1` and
# `2e6d3d1a`.
two_widths_record='| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-24T09:00:00Z | 2e6d3d1 | clean | ✘ 4455 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-24T09:31:00Z | 2e6d3d1a | clean | ✔ 4455 tests passed | 0 | Test-B.xcresult | — |'

actual=$(flakes_readout_for <<RECORD
$two_widths_record
RECORD
)
check 'one commit at two widths — one flip, named once, at the one commit' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 2 rows in docs/suite-status.md.
  KiteloopTests.HTTPServerTests.testBindsToLoopback
    1 flip at 2e6d3d1 — 2026-08-24T09:00:00Z .. 2026-08-24T09:31:00Z' \
  "$actual"

# The same pair through --last's earlier line, which counts the measurements at
# the newest row's commit: both rows are at it, and they disagreed. Counted as
# one of one — the newest row alone — before the widths were reconciled.
actual=$(earlier_readout_for <<RECORD
$two_widths_record
RECORD
)
check 'one commit at two widths — the earlier line counts both rows, not one' \
  '1 of 2 measurements at 2e6d3d1a recorded ✘ — KiteloopTests.HTTPServerTests.testBindsToLoopback' \
  "$actual"

# And through the flaky line, whose whole subject is a red row at a commit
# *other* than the newest one. This red row is at the newest commit, spelled
# narrower, so the line has nothing to say — the earlier line above has just
# said it — rather than reporting the test as one somebody fixed.
actual=$(flaky_readout_for <<RECORD
$two_widths_record
RECORD
)
check 'one commit at two widths — the flaky line does not call the flip a fix' '' "$actual"

# Two cells where neither is a prefix of the other are two commits, and no
# reading may bring them together. Same widths as the pair above, differing in
# the seventh character, so the difference is in the part both cells state
# rather than in the part only one of them does.
other_commits_record='| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-24T09:00:00Z | 2e6d3d1 | clean | ✘ 4455 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-24T09:31:00Z | 2e6d3d2a | clean | ✔ 4455 tests passed | 0 | Test-B.xcresult | — |'

actual=$(flakes_readout_for <<RECORD
$other_commits_record
RECORD
)
check 'neither cell a prefix of the other — two commits, so no flip' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 2 rows in docs/suite-status.md.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"

actual=$(earlier_readout_for <<RECORD
$other_commits_record
RECORD
)
check 'neither cell a prefix of the other — the earlier line sees one row, so no line' \
  '' "$actual"

actual=$(flaky_readout_for <<RECORD
$other_commits_record
RECORD
)
check 'neither cell a prefix of the other — red at an earlier commit, and said so' \
  '1 test recorded ✘ at an earlier commit and ✔ since — KiteloopTests.HTTPServerTests.testBindsToLoopback' \
  "$actual"

# Two cells of one width that differ are two commits by the same rule, with no
# longer cell involved at all.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-24T09:00:00Z | aaaaaaa | clean | ✘ 4455 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-24T09:31:00Z | aaaaaab | clean | ✔ 4455 tests passed | 0 | Test-B.xcresult | — |
RECORD
)
check 'two cells of one width that differ — two commits, so no flip' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 2 rows in docs/suite-status.md.
  none — no test in docs/suite-status.md has recorded both a red row and a green row at the same commit.' \
  "$actual"

# A third width joining the two is one commit still: every cell canonicalises to
# the shortest of them, so the three rows are one group rather than two.
actual=$(flakes_readout_for <<'RECORD'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-24T09:00:00Z | 2e6d3d1ab | clean | ✘ 4455 tests, 1 failure | 65 | Test-A.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback |
| 2026-08-24T09:31:00Z | 2e6d3d1a | clean | ✔ 4455 tests passed | 0 | Test-B.xcresult | — |
| 2026-08-24T10:02:00Z | 2e6d3d1 | clean | ✘ 4455 tests, 1 failure | 65 | Test-C.xcresult | KiteloopTests.HTTPServerTests.testBindsToLoopback |
RECORD
)
check 'three widths of one commit — one group, one flip, named at the shortest' \
  'run-unit-suite: flake ledger
run-unit-suite: read all 3 rows in docs/suite-status.md.
  KiteloopTests.HTTPServerTests.testBindsToLoopback
    1 flip at 2e6d3d1 — 2026-08-24T09:00:00Z .. 2026-08-24T10:02:00Z' \
  "$actual"

# The rule itself, at the two edges the readings above cannot reach: a cell is
# the same commit as itself, and an empty cell abbreviates nothing — a row from
# a record layout with no commit to read must not read as the same commit as
# every other such row.
same_commit_cell 2e6d3d1a 2e6d3d1a && actual=same || actual=different
check 'a cell against itself — the same commit' 'same' "$actual"
same_commit_cell '' '' && actual=same || actual=different
check 'two empty cells — no commit, so not the same one' 'different' "$actual"
same_commit_cell '' 2e6d3d1a && actual=same || actual=different
check 'an empty cell against a real one — not the same commit' 'different' "$actual"

# And the width a run records. git's automatic abbreviation is what left the
# record holding two widths, so the cell is asked for at a fixed width instead:
# in a repository this small git would choose seven on its own, and the row
# still carries eight.
width_repo=$tmp/width-repo
git init -q -b main "$width_repo" >/dev/null 2>&1
git -C "$width_repo" config user.email test@example.invalid
git -C "$width_repo" config user.name 'Suite Test'
git -C "$width_repo" config commit.gpgsign false
printf 'x\n' >"$width_repo/file.txt"
git -C "$width_repo" add -A >/dev/null 2>&1
git -C "$width_repo" commit -q -m 'first' >/dev/null 2>&1

saved_root=$root
root=$width_repo
recorded_cell=$(head_commit_cell)
chosen_cell=$(git -C "$width_repo" rev-parse --short HEAD)
root=$saved_root

check "git's own choice in this repository is narrower than the cell" \
  '7' "${#chosen_cell}"
check 'the cell a row records is the width the script asked for' \
  '8' "${#recorded_cell}"
check 'and it is the same commit git named, one character wider' \
  "$chosen_cell" "${recorded_cell:0:7}"

# A directory git cannot answer about records `unknown`, exactly as the cell did
# before it had a width — and the readers already treat that as a commit they
# cannot resolve.
saved_root=$root
root=$tmp/not-a-repo
mkdir -p "$root"
actual=$(GIT_CEILING_DIRECTORIES=$tmp head_commit_cell)
root=$saved_root
check 'no commit for git to abbreviate — the cell says unknown' 'unknown' "$actual"

# --- Drift -------------------------------------------------------------------
#
# The line that answers "does the last measurement still describe this tree?".
# The raw commit count overstates it: this backlog lands docs and backlog files
# constantly, and none of them can change what a test reports — from the row at
# 2e6d3d1 the tree was 63 commits ahead, of which 31 had touched code. So the
# line names both, and these cases are run against a repository built here with
# known commits rather than against this checkout's history, which moves.
fixture=$tmp/drift-repo
git init -q -b main "$fixture" >/dev/null 2>&1
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" config user.name 'Suite Test'
git -C "$fixture" config commit.gpgsign false

# One commit touching $1, whose short hash is printed.
fixture_commit() {
  local path=$1
  mkdir -p "$fixture/$(dirname -- "$path")"
  printf 'x\n' >>"$fixture/$path"
  git -C "$fixture" add -A >/dev/null 2>&1
  git -C "$fixture" commit -q -m "touch $path" >/dev/null 2>&1
  git -C "$fixture" rev-parse --short HEAD
}

# Four commits, in this order: code, docs, code, backlog. From the first, three
# commits have landed and one of them touched code — so a reader that counted
# every commit would say three times as much has changed as actually could have.
first=$(fixture_commit Kiteloop/App.swift)
fixture_commit docs/architecture.md >/dev/null
second_code=$(fixture_commit scripts/run-unit-suite.sh)
head_commit=$(fixture_commit backlog/backlog.md)

# A record naming $1 and nothing else of interest — the drift line is read from
# the commit cell, so the rest is only there to make the row a row.
record_at() {
  printf '| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |\n'
  printf '| --- | --- | --- | --- | --- | --- | --- |\n'
  printf '| 2026-08-12T09:00:00Z | %s | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — |\n' "$1"
}

# The drift line --last prints for a record with this content, without its label.
drift_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  drift   //p'
}

# show_last resolves drift against $root; point it at the fixture for these
# cases, and put it back afterwards so nothing later reads the wrong graph.
checkout_root=$root
root=$fixture

actual=$(record_at "$first" | drift_readout_for)
check 'a resolvable commit — the total, and how much of it could have mattered' \
  '3 commits on HEAD since that measurement, 1 of them touching Kiteloop/ or quality/ or quality.json or scripts/.' \
  "$actual"

# Drift that is entirely backlog and docs is the common case here, and the one
# the raw count answers worst: the tree has moved, the measurement still stands.
actual=$(record_at "$second_code" | drift_readout_for)
check 'a commit that could not have mattered — counted in the total, not beside it' \
  '1 commit on HEAD since that measurement, 0 of them touching Kiteloop/ or quality/ or quality.json or scripts/.' \
  "$actual"

actual=$(record_at "$head_commit" | drift_readout_for)
check 'a record at HEAD — nothing has moved, in either count' \
  '0 commits on HEAD since that measurement, 0 of them touching Kiteloop/ or quality/ or quality.json or scripts/.' \
  "$actual"

# The second number counts a subset of the first, so it can never be the larger.
# Asserted from every commit in the fixture rather than from one, because the
# pair is only meaningful if the relation holds wherever the row was written.
overruns=""
for fixture_commit_hash in $(git -C "$fixture" rev-list --all); do
  line=$(record_at "$fixture_commit_hash" | drift_readout_for)
  total=$(printf '%s' "$line" | sed -n -E 's/^([0-9]+) commits?.*/\1/p')
  code=$(printf '%s' "$line" | sed -n -E 's/.*measurement, ([0-9]+) of them.*/\1/p')
  if [ -z "$total" ] || [ -z "$code" ] || [ "$code" -gt "$total" ]; then
    overruns="$overruns $fixture_commit_hash($code of $total)"
  fi
done
check 'the code-touching count is a subset — never larger, from any base' '' "$overruns"

# A commit git cannot resolve keeps the branch it always had: one line saying so,
# with no count beside it. Read to the end of the readout so a second drift line
# — or a half-written one carrying an empty count — would show up here.
actual=$(readout_for <<'RECORD' | sed -n '/^  drift/,$p'
| when (UTC) | commit | tree | tally | exit | result bundle | failing tests |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-08-12T09:00:00Z | deadbee | clean | ✔ 3058 tests passed | 0 | Test-Kiteloop.xcresult | — |
RECORD
)
check 'an unresolvable commit — the unknown line, and nothing after it' \
  '  drift   unknown — git cannot resolve deadbee in this checkout.' "$actual"

# --- The tree the graph cannot see -------------------------------------------
#
# Both drift counts are commit counts, so an edit that has not been committed
# moves neither: a record at HEAD with a modified source file beside it printed
# `0 commits … 0 of them touching Kiteloop/ or quality/ or quality.json or
# scripts/` — byte for byte what it prints for a tree nobody has touched. These
# cases are the three states that line has to tell apart, run against the same
# fixture as the drift ones and with the tree put back afterwards, so nothing
# later reads a dirty repository.

# The uncommitted line --last prints for a record with this content, or empty
# when it prints none.
dirty_readout_for() {
  cat >"$tmp/record"
  show_last "$tmp/record" | sed -n 's/^  dirty   //p'
}

# A record at HEAD, so the drift counts stay at zero and the only thing that can
# distinguish this readout from a clean tree's is the new line.
printf 'y\n' >>"$fixture/Kiteloop/App.swift"
actual=$(record_at "$head_commit" | readout_for | sed -n '/^  drift /,$p')
check 'an uncommitted change under the code paths — said, under the drift it qualifies' \
  '  drift   0 commits on HEAD since that measurement, 0 of them touching Kiteloop/ or quality/ or quality.json or scripts/.
  dirty   1 file uncommitted under Kiteloop/ or quality/ or quality.json or scripts/ — the last measurement does not describe this tree.' \
  "$actual"

# A second path in CODE_PATHS, and the plural — the count is files, not paths.
printf 'y\n' >>"$fixture/scripts/run-unit-suite.sh"
actual=$(record_at "$head_commit" | dirty_readout_for)
check 'two files, one under each code path — counted together, in the plural' \
  '2 files uncommitted under Kiteloop/ or quality/ or quality.json or scripts/ — the last measurement does not describe this tree.' \
  "$actual"

# A file git has never seen counts too: an unregistered test file is exactly the
# state that goes unnoticed, and it is uncommitted work under the code paths
# whatever its git status letter says.
git -C "$fixture" checkout -- . >/dev/null 2>&1
printf 'x\n' >"$fixture/Kiteloop/Untracked.swift"
actual=$(record_at "$head_commit" | dirty_readout_for)
check 'an untracked file under the code paths — counted like a modified one' \
  '1 file uncommitted under Kiteloop/ or quality/ or quality.json or scripts/ — the last measurement does not describe this tree.' \
  "$actual"
rm -f "$fixture/Kiteloop/Untracked.swift"

# The state every finished run leaves behind: its own appended row, sitting
# uncommitted until someone commits it. It is under none of the code paths, so the
# count never sees it — without which the line would fire on almost every
# readout and stop meaning anything.
fixture_commit docs/suite-status.md >/dev/null
printf '| 2026-08-12T10:00:00Z | %s | clean | ✔ 3058 tests passed | 0 | Test-K.xcresult | — | — |\n' \
  "$head_commit" >>"$fixture/docs/suite-status.md"
actual=$(record_at "$head_commit" | dirty_readout_for)
check 'only the record modified — the run its own row came from is not dirt' '' "$actual"

# And the clean tree, which is the readout everyone sees: no line at all, not a
# line saying zero. Read to the end so a blank one would show up here.
git -C "$fixture" checkout -- . >/dev/null 2>&1
actual=$(record_at "$head_commit" | readout_for | sed -n '/^  drift /,$p')
check 'a clean tree — the drift line, and nothing after it' \
  '  drift   1 commit on HEAD since that measurement, 0 of them touching Kiteloop/ or quality/ or quality.json or scripts/.' \
  "$actual"

# --- The tree cell a run records ---------------------------------------------
#
# The row's tree cell and the readout's dirty line ask one question — is anything
# uncommitted that could change what the suite reports? — and they answered it
# over two different trees. The run path looked at the whole checkout minus the
# record file, so an uncommitted backlog or docs edit recorded the measurement as
# taken against a `dirty` tree while --last printed no dirty line at all for that
# same tree, and this backlog lands a great many of those. These cases are the
# scope, over the same fixture as the dirty ones and with the tree put back after
# each, so nothing later reads a dirty repository.
#
# The two spellings are asserted literally: rows already in the record read
# `clean` or `dirty`, and a cell that started saying anything else would make
# them unreadable next to the new ones.

printf 'y\n' >>"$fixture/Kiteloop/App.swift"
check 'a modified file under Kiteloop/ — dirty' 'dirty' "$(code_worktree_state)"
git -C "$fixture" checkout -- . >/dev/null 2>&1

printf 'y\n' >>"$fixture/scripts/run-unit-suite.sh"
check 'a modified file under scripts/ — dirty' 'dirty' "$(code_worktree_state)"
git -C "$fixture" checkout -- . >/dev/null 2>&1

# A file git has never seen is uncommitted work under the code paths whatever its
# status letter says — counted here exactly as the readout counts it.
printf 'x\n' >"$fixture/Kiteloop/Untracked.swift"
check 'an untracked file under the code paths — dirty, as it is for --last' \
  'dirty' "$(code_worktree_state)"
rm -f "$fixture/Kiteloop/Untracked.swift"

# The edits that cannot change what a test reports, which is the whole reason for
# the scope: each of these used to record the run as measured against a dirty
# tree while the readout called that same tree clean.
printf 'y\n' >>"$fixture/backlog/backlog.md"
check 'an uncommitted backlog edit — clean, the tree --last also calls clean' \
  'clean' "$(code_worktree_state)"
git -C "$fixture" checkout -- . >/dev/null 2>&1

printf 'y\n' >>"$fixture/docs/architecture.md"
check 'an uncommitted docs edit — clean' 'clean' "$(code_worktree_state)"
git -C "$fixture" checkout -- . >/dev/null 2>&1

# The state every finished run leaves behind: its own appended row, sitting
# uncommitted until someone commits it. The run path used to name the record file
# in an explicit exclude to keep it out; the scope keeps it out on its own, and
# this is the case that says so.
printf '| 2026-08-12T10:00:00Z | %s | clean | ✔ 3058 tests passed | 0 | Test-K.xcresult | — | — |\n' \
  "$head_commit" >>"$fixture/docs/suite-status.md"
check 'only the record modified — still clean, as it always was' \
  'clean' "$(code_worktree_state)"
git -C "$fixture" checkout -- . >/dev/null 2>&1

check 'a clean tree — clean' 'clean' "$(code_worktree_state)"

# --- The quality gates count as code -----------------------------------------
#
# quality.json and everything under quality/bin and quality/tests are ten of the
# twenty-three preflight steps plus the layering exemptions, hygiene ceilings and
# doc-size ceilings the run enforces — CODE_PATHS carries them for that reason,
# not because they happen to sit near the app. These commits land after every
# drift assertion above so HEAD moving forward cannot change what those already
# read; both readers are asked exactly as they were asked of Kiteloop/ and
# scripts/.
check 'the phrase names every scoped path, quality.json spelled as a file' \
  'Kiteloop/ or quality/ or quality.json or scripts/' "$(code_paths_phrase)"

fixture_commit quality/bin/check-example.py >/dev/null
fixture_commit quality.json >/dev/null

printf 'y\n' >>"$fixture/quality/bin/check-example.py"
check 'a modified file under quality/bin/ — dirty' 'dirty' "$(code_worktree_state)"
actual=$(record_at "$head_commit" | dirty_readout_for)
check 'and --last prints its dirty line for the same edit' \
  '1 file uncommitted under Kiteloop/ or quality/ or quality.json or scripts/ — the last measurement does not describe this tree.' \
  "$actual"
git -C "$fixture" checkout -- . >/dev/null 2>&1

printf 'y\n' >>"$fixture/quality.json"
check 'a modified quality.json — dirty' 'dirty' "$(code_worktree_state)"
actual=$(record_at "$head_commit" | dirty_readout_for)
check 'and --last prints its dirty line for the same edit' \
  '1 file uncommitted under Kiteloop/ or quality/ or quality.json or scripts/ — the last measurement does not describe this tree.' \
  "$actual"
git -C "$fixture" checkout -- . >/dev/null 2>&1

# A file outside every code path — the case the scope exists to exclude — still
# reads clean even now that quality/ and quality.json are tracked in the fixture.
printf 'y\n' >>"$fixture/docs/architecture.md"
check 'an uncommitted docs edit is still clean beside the quality paths' \
  'clean' "$(code_worktree_state)"
actual=$(record_at "$head_commit" | dirty_readout_for)
check 'and --last still prints no dirty line for it' '' "$actual"
git -C "$fixture" checkout -- . >/dev/null 2>&1

# --last is the readout you reach for while Kiteloop is up, which is when running
# the suite would kill it. It must therefore start no build and read no process
# list — asserted by putting a shim ahead of both on PATH and checking neither
# was called, rather than by reading the function and believing it.
shims=$tmp/shims
mkdir -p "$shims"
for shim in xcodebuild pgrep; do
  printf '#!/bin/sh\nprintf %%s "$0" >>"%s/called"\n' "$tmp" >"$shims/$shim"
  chmod +x "$shims/$shim"
done
rm -f "$tmp/called"
saved_path=$PATH
PATH="$shims:$PATH"
record_at "$first" | drift_readout_for >/dev/null
PATH=$saved_path
check '--last starts no build and reads no process list' '' "$(cat "$tmp/called" 2>/dev/null)"

root=$checkout_root

# --- What the script exits with ----------------------------------------------
#
# The tally and the exit status can say opposite things, and the combination that
# lies is a green xcodebuild over an empty tally: nothing reported a summary, so
# nothing was measured, and the script used to hand that back as success. These
# four cases are the whole decision.

# `0` or `non-zero`, which is the requirement here; which particular code stands
# for "nothing was measured" is the script's own to choose, and asserting the
# number would only be asserting the constant back to itself. The pass-through
# cases below do check the exact status, because passing it through unchanged is
# what they are about.
zeroness() {
  if [ "$1" -eq 0 ]; then printf '0'; else printf 'non-zero'; fi
}

actual=$(exit_status_for 0 '')
check 'xcodebuild exited 0 having measured nothing — the script does not' \
  'non-zero' "$(zeroness "$actual")"

actual=$(exit_status_for 0 '✔ 3056 tests passed — 3038 XCTest, 18 swift-testing')
check 'a green run that measured something still exits 0' '0' "$actual"

# A run that died before testing has no tally either, and it already reports
# itself. Replacing its status would lose which failure it was.
actual=$(exit_status_for 65 '')
check 'a non-zero status with no tally is passed through, not replaced' \
  '65' "$actual"

actual=$(exit_status_for 65 '✘ 3056 tests, 3 failures — 3038 XCTest (3 failures), 18 swift-testing (0 failures)')
check 'a non-zero status with a failing tally is passed through' '65' "$actual"

# --- Could the guard tell whether Kiteloop is running? -----------------------
#
# The refusal that keeps the XCTest host from terminating a running Kiteloop read
# pgrep as a yes/no, and pgrep answers three things: it matched, it matched
# nothing, or it could not look. Written as `if pgrep … >/dev/null 2>&1` the
# third joined the second, so a pgrep that failed for any reason read as "the app
# is down" and the suite started — which is what a full run recorded at 00:24 on
# 2026-08-11, while the app had been up since 23:33, appears to have been.
#
# The verdict is pure, so the three answers are asserted directly. What the
# script then does with each is asserted end to end, against a copy of it in a
# throwaway repository whose preflight is stubs, with pgrep and xcodebuild
# shimmed: each records that it was called, so "refused and started nothing" and
# "answered without reading the process list" are read off the calls rather than
# inferred from the output. No real build can start here — xcodebuild is the
# shim — which is why these cases are safe while Kiteloop is up, like the rest of
# this file.
#
# The preflight is read off the same call list, and for the same reason. Its
# stubs used to exit 0 and record nothing, so every case below passed whether or
# not the preflight had run at all: the loop that runs it could have been deleted
# and this file would still have said the guard was sound. Now each stub names
# itself as it runs, so the order is read rather than assumed, and a case can
# make one of them fail — which is the thing the preflight exists to do, and the
# thing nothing asserted: that a check finding something wrong stops the run
# before a build starts, hands back that check's own status, and leaves no record
# behind, because nothing was measured.

check_contains() {
  local name=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) printf '  ok    %s\n' "$name" ;;
    *) printf '  FAIL  %s\n          expected to contain: %s\n          actual:   %s\n' \
        "$name" "$needle" "$haystack"
      failed=$((failed + 1)) ;;
  esac
}

check_lacks() {
  local name=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) printf '  FAIL  %s\n          expected not to contain: %s\n          actual:   %s\n' \
        "$name" "$needle" "$haystack"
      failed=$((failed + 1)) ;;
    *) printf '  ok    %s\n' "$name" ;;
  esac
}

check 'pgrep matched — running' 'running' "$(guard_verdict 0)"
check 'pgrep matched nothing — not running' 'not-running' "$(guard_verdict 1)"
check 'a usage error is unknown, not "not running"' 'unknown' "$(guard_verdict 2)"
check 'a fatal error is unknown too' 'unknown' "$(guard_verdict 3)"
check 'no pgrep on PATH — the shell 127 is unknown' 'unknown' "$(guard_verdict 127)"

guard_repo=$tmp/guard-repo
mkdir -p "$guard_repo/scripts" "$guard_repo/Kiteloop" "$guard_repo/docs"
git init -q -b main "$guard_repo" >/dev/null 2>&1
cp "$here/run-unit-suite.sh" "$guard_repo/scripts/run-unit-suite.sh"

# The command a PREFLIGHT entry runs, without its arguments — split the way the
# loop under test splits it, so a stub is written for exactly the file that will
# be executed.
preflight_name() {
  local -a argv
  argv=($1)
  printf '%s' "${argv[0]}"
}

# Which preflight entry, if any, the stubs should fail with, and with what
# status. They reach the stubs through the environment, so a case chooses a
# failure the way run_guard chooses a pgrep answer — and leaves nothing rewritten
# on disk for the next case to inherit.
guard_fail_preflight=""
guard_fail_status=0

# The preflight of the copy is stubs, one per PREFLIGHT entry — which is also
# what keeps this file from running itself: the real preflight would re-enter it
# once per case. Each records that it ran, under the name PREFLIGHT gives it, so
# that the preflight ran at all and ran before the build are read off the calls
# rather than taken on trust; and each exits with GUARD_FAIL_STATUS when
# GUARD_FAIL_PREFLIGHT names it, which is how a case fails exactly one of them.
for preflight_entry in "${PREFLIGHT[@]}" "${POSTFLIGHT[@]}"; do
  guard_stub=$(preflight_name "$preflight_entry")
  # an entry may live under quality/bin or quality/tests, not only scripts/
  mkdir -p "$(dirname "$guard_repo/$guard_stub")"
  {
    printf '#!/bin/sh\n'
    printf 'printf %s >>"$GUARD_CALLS"\n' "'$guard_stub\\n'"
    # The CRAP gate alone, and only when a case gave somewhere to put it: what
    # it was actually handed, so a case can assert whether --bundle arrived
    # rather than trust that it did.
    if [ "$guard_stub" = "quality/bin/check-crap.py" ]; then
      printf '[ -n "${GUARD_POSTFLIGHT_ARGS:-}" ] && printf %%s "$*" >"$GUARD_POSTFLIGHT_ARGS"\n'
    fi
    printf '[ "${GUARD_FAIL_PREFLIGHT:-}" = %s ] && exit "${GUARD_FAIL_STATUS:-1}"\n' \
      "'$guard_stub'"
    printf 'exit 0\n'
  } >"$guard_repo/$guard_stub"
  chmod +x "$guard_repo/$guard_stub"
done

guard_shims=$tmp/guard-shims
mkdir -p "$guard_shims"
# The build itself. A case that wants a particular run — red, or one that
# measured nothing — says so through the environment, the way it chooses a pgrep
# answer, rather than rewriting the shim and leaving it for the next case. With
# nothing set it is the small green run every case here has always got.
cat >"$guard_shims/xcodebuild" <<'SHIM'
#!/bin/sh
printf 'xcodebuild\n' >>"$GUARD_CALLS"
# What the build was asked for, for the case that reads the flags rather than
# the order. Only when a case gave somewhere to put it.
[ -n "${GUARD_XCODEBUILD_ARGS:-}" ] && printf '%s\n' "$*" >"$GUARD_XCODEBUILD_ARGS"
# The pid the script has to be holding as $build_pid. Written by the build
# itself rather than guessed at from the outside, so a case comparing it with
# the pid the power assertion was taken out over is comparing two readings of
# one process. `exec sleep` below keeps this pid, and so does the unexec'd
# child, so it stays xcodebuild's own pid in every shape a case can ask for.
printf '%s\n' "$$" >"$GUARD_BUILD_PID"
if [ -n "${GUARD_XCODEBUILD_SLEEP:-}" ]; then
  # Whatever this build managed to print before it stopped — a real wedge is a
  # run that got somewhere and then sat there, and what is in the log at that
  # moment is the whole of what the record can say about it. Nothing when a case
  # asked for no output, which is every case that only wants the wedge itself.
  [ -n "${GUARD_XCODEBUILD_OUTPUT:-}" ] && printf '%s\n' "$GUARD_XCODEBUILD_OUTPUT"
  # exec rather than a plain `sleep` call: the wedged-build cases send SIGTERM
  # to this process's own pid, and a `sleep` run as an ordinary child would be
  # orphaned by that signal rather than killed by it, since the parent shell
  # here would die without ever having waited for it. exec replaces this
  # process with sleep under the same pid, so there is nothing left behind to
  # orphan.
  exec sleep "$GUARD_XCODEBUILD_SLEEP"
fi
if [ -n "${GUARD_XCODEBUILD_CHILD_SLEEP:-}" ]; then
  # The opposite shape from GUARD_XCODEBUILD_SLEEP above: a plain (unexec'd)
  # child, so this shim is still a live process sitting on top of it rather
  # than having become it. Signalling only this shim's own pid — the bug the
  # item exists for — leaves the child an orphan the signal never reached;
  # signalling its process group reaches both.
  sleep "$GUARD_XCODEBUILD_CHILD_SLEEP" &
  wait
fi
if [ -n "${GUARD_XCODEBUILD_OUTPUT:-}" ]; then
  printf '%s\n' "$GUARD_XCODEBUILD_OUTPUT"
else
  printf '\t Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds\n'
fi
exit "${GUARD_XCODEBUILD_STATUS:-0}"
SHIM
chmod +x "$guard_shims/xcodebuild"

# The power assertion. It records the whole invocation — the flags, and the pid
# it was told to hold the assertion over — and then does what `caffeinate -w`
# does, which is the part a case cares about: the assertion lasts exactly as long
# as that process and is released when it goes away. Recording the release too
# means "gone once the build has been reaped" is read off the shim rather than
# inferred from the assertion never having been seen again.
#
# It records into GUARD_CAFFEINATE rather than GUARD_CALLS: it is started in the
# background, so its line would land at a moment no case can predict and the
# ordered call list every case above asserts would stop being an order.
cat >"$guard_shims/caffeinate" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >>"$GUARD_CAFFEINATE"
pid=""
while [ $# -gt 0 ]; do
  [ "$1" = "-w" ] && pid=${2:-}
  shift
done
[ -n "$pid" ] || exit 0
while kill -0 "$pid" 2>/dev/null; do
  sleep 0.2
done
printf 'released %s\n' "$pid" >>"$GUARD_CAFFEINATE"
SHIM
chmod +x "$guard_shims/caffeinate"
# What a wedge's sampler was handed, and a stack to keep in its place — so a
# case reads which hosts were sampled, and for how long, off the call itself.
cat >"$guard_shims/sample" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >>"$GUARD_SAMPLES"
printf 'stub stack of %s\n' "$1"
SHIM
chmod +x "$guard_shims/sample"

# And the machine that has none. caffeinate lives in /usr/bin, and only there, so
# a PATH without it is that directory mirrored as symlinks with the one entry
# left out — everything else the script reaches for is still exactly where it
# was. Shadowing it with a shim of some other kind would not do: `command -v` is
# a question about PATH, and the answer this case needs is the one a machine
# without the binary gives.
guard_bare_bin=$tmp/guard-bare-bin
mkdir -p "$guard_bare_bin"
ln -s /usr/bin/* "$guard_bare_bin/" 2>/dev/null
rm -f "$guard_bare_bin/caffeinate"

# The shims that machine still needs, beside the mirror rather than inside the
# directory the caffeinate shim sits in. Symlinks, so the pgrep shim run_guard
# rewrites for every case is the same one here.
guard_shims_bare=$tmp/guard-shims-bare
mkdir -p "$guard_shims_bare"
ln -s "$guard_shims/pgrep" "$guard_shims_bare/pgrep"
ln -s "$guard_shims/xcodebuild" "$guard_shims_bare/xcodebuild"

# What the build shim prints and exits with. Reset by every case that sets them,
# so a run reaches the shim's own green default unless it asked for otherwise.
guard_xcodebuild_output=""
guard_xcodebuild_status=0
guard_xcodebuild_sleep=""
guard_xcodebuild_child_sleep=""
guard_suite_idle_seconds=""
guard_suite_timeout_seconds=""
# The test-host pids the pgrep shim names, for the case that has a wedge sampled.
guard_pgrep_pids=""
# Whether the run sees a machine with no caffeinate on PATH. Chosen through the
# same reset-after-use variables as the rest, so a case that wants it says so and
# leaves nothing behind for the next one.
guard_no_caffeinate=""

# Wait, briefly, for a caffeinate the last run started to notice its build is
# gone and release. It is `caffeinate -w`, so it does that on its own; bounding
# how long that takes is what keeps one case's assertion from still being held
# while the next case is asserting nothing holds one. Returns whatever is still
# running, so a case can check that nothing is.
settle_caffeinate() {
  local waited=0 left
  while [ "$waited" -lt 40 ]; do
    left=$(pgrep -f "$guard_shims/caffeinate" 2>/dev/null)
    [ -n "$left" ] || break
    sleep 0.25
    waited=$((waited + 1))
  done
  printf '%s' "$left"
}

# Run the copy with a pgrep that exits $1 and says $2 for itself, plus any
# options after those. Leaves the script's output in guard_out, its status in
# guard_exit, and the shims it reached, in order, in guard_calls — and the power
# assertion it took out, if any, in guard_caffeinate, beside the build pid that
# assertion should have been over.
run_guard() {
  local status=$1 message=$2 path
  shift 2
  {
    printf '#!/bin/sh\n'
    printf 'printf %s >>"$GUARD_CALLS"\n' "'pgrep\\n'"
    printf 'printf %s "$*" >>"$GUARD_CALLS.args"\n' "'%s\\n'"
    if [ -n "$message" ]; then
      printf 'cat >&2 <<%s\n%s\n%s\n' "'MESSAGE'" "$message" MESSAGE
    fi
    # The test hosts a case says are up, on stdout whatever the status: the
    # refusal reads only the status, the wedge sampler only the pids.
    printf '[ -n "${GUARD_PGREP_PIDS:-}" ] && printf %s $GUARD_PGREP_PIDS\n' "'%s\\n'"
    printf 'exit %s\n' "$status"
  } >"$guard_shims/pgrep"
  chmod +x "$guard_shims/pgrep"
  : >"$tmp/guard-calls"
  : >"$tmp/guard-calls.args"
  : >"$tmp/guard-caffeinate"
  : >"$tmp/guard-samples"
  rm -f "$tmp/guard-build-pid"
  rm -f "$tmp/guard-xcodebuild-args"
  rm -f "$tmp/guard-postflight-args"
  rm -f "$guard_repo/$RECORD_RELPATH"
  # And whatever output the last case's run kept, so what is here afterwards is
  # this run's doing rather than the one before it.
  rm -rf "$guard_repo/.kiteloop"
  # A machine with no caffeinate is a PATH, so it is chosen here: the mirror of
  # /usr/bin without it, the two shims that machine still needs beside it, and
  # the directory the caffeinate shim lives in left out entirely. /bin and the
  # sbins are appended as themselves — neither holds a caffeinate, and the
  # script reaches for date, cp and their neighbours there.
  path="$guard_shims:$PATH"
  [ -n "$guard_no_caffeinate" ] &&
    path="$guard_shims_bare:$guard_bare_bin:/bin:/usr/sbin:/sbin"
  guard_out=$(GUARD_CALLS=$tmp/guard-calls \
    GUARD_CAFFEINATE=$tmp/guard-caffeinate \
    GUARD_SAMPLES=$tmp/guard-samples \
    GUARD_PGREP_PIDS="$guard_pgrep_pids" \
    GUARD_BUILD_PID=$tmp/guard-build-pid \
    GUARD_XCODEBUILD_ARGS=$tmp/guard-xcodebuild-args \
    GUARD_POSTFLIGHT_ARGS=$tmp/guard-postflight-args \
    GUARD_FAIL_PREFLIGHT="$guard_fail_preflight" \
    GUARD_FAIL_STATUS="$guard_fail_status" \
    GUARD_XCODEBUILD_OUTPUT="$guard_xcodebuild_output" \
    GUARD_XCODEBUILD_STATUS="$guard_xcodebuild_status" \
    GUARD_XCODEBUILD_SLEEP="$guard_xcodebuild_sleep" \
    GUARD_XCODEBUILD_CHILD_SLEEP="$guard_xcodebuild_child_sleep" \
    SUITE_TIMEOUT_SECONDS="$guard_suite_timeout_seconds" \
    SUITE_IDLE_SECONDS="$guard_suite_idle_seconds" \
    PATH="$path" \
    "$guard_repo/scripts/run-unit-suite.sh" "$@" 2>&1)
  guard_exit=$?
  guard_calls=$(cat "$tmp/guard-calls")
  # Read after the assertion has been released rather than while it is still
  # held, so guard_caffeinate carries the whole of what this run did with it.
  guard_caffeinate_leftover=$(settle_caffeinate)
  guard_build_pid=$(cat "$tmp/guard-build-pid" 2>/dev/null)
}

# The power assertion the last run took out, and the release beside it. The shim
# is a background child of the script, so it can be scheduled after the script
# itself has finished; this waits for its first line rather than reading an empty
# file the moment run_guard returns. A case asserting that *no* assertion was
# taken reads the file directly instead — there is nothing there to wait for.
guard_caffeinate_log() {
  local waited=0
  while [ "$waited" -lt 40 ] && [ ! -s "$tmp/guard-caffeinate" ]; do
    sleep 0.25
    waited=$((waited + 1))
  done
  cat "$tmp/guard-caffeinate"
}

# Whether the last case left a record behind — `present` or `absent`, so a failed
# assertion says which rather than printing a path. run_guard removes it before
# every case, so what is here afterwards is what that run wrote.
guard_record_state() {
  if [ -e "$guard_repo/$RECORD_RELPATH" ]; then
    printf 'present'
  else
    printf 'absent'
  fi
}

# The `when` cell of the row the last case appended, which is the timestamp that
# run took for itself — a real one, so the path its output went to is not
# something a case can spell in advance and has to be read back out of the
# record, exactly as --last reads it.
guard_recorded_when() {
  local row when_cell
  row=$(newest_record "$guard_repo/$RECORD_RELPATH")
  IFS='|' read -r _ when_cell _ <<ROW
$row
ROW
  trim "$when_cell"
}

# Whether the row the last case appended carries a duration — `a whole number of
# seconds`, or what it does carry, so a failure prints the cell rather than a
# boolean. Like the `when` cell this cannot be spelled in advance: a case knows
# the run took *some* length of time and wrote it down, not which one.
guard_recorded_duration() {
  local row cell
  row=$(newest_record "$guard_repo/$RECORD_RELPATH")
  IFS='|' read -r _ _ _ _ _ _ _ _ _ cell _ <<ROW
$row
ROW
  cell=$(trim "$cell")
  if printf '%s\n' "$cell" | grep -qE '^[0-9]+s$'; then
    printf 'a whole number of seconds'
  else
    printf 'not a duration: %s' "$cell"
  fi
}

# The package tally cell of the row the last case appended — what the
# scripts/run-core-tests.sh stub printed for itself, read the way the run
# itself read it rather than assumed from what the stub was told to print.
guard_recorded_core_tally() {
  local row cell
  row=$(newest_record "$guard_repo/$RECORD_RELPATH")
  IFS='|' read -r _ _ _ _ _ _ _ _ _ _ cell _ <<ROW
$row
ROW
  trim "$cell"
}

# The tally and exit cells of the row the last case appended, trimmed the same
# way. Read the same way the two above are, rather than parsed a second time
# out of the raw row text, so a case asking for one of these is asking the
# same question --last would answer.
guard_recorded_tally() {
  local row cell
  row=$(newest_record "$guard_repo/$RECORD_RELPATH")
  IFS='|' read -r _ _ _ _ cell _ <<ROW
$row
ROW
  trim "$cell"
}

guard_recorded_exit() {
  local row cell
  row=$(newest_record "$guard_repo/$RECORD_RELPATH")
  IFS='|' read -r _ _ _ _ _ cell _ <<ROW
$row
ROW
  trim "$cell"
}

# And the failing-tests cell, which on a run ended at its ceiling carries the
# tests that never came back. Read the same way as the cells above it.
guard_recorded_failing() {
  local row cell
  row=$(newest_record "$guard_repo/$RECORD_RELPATH")
  IFS='|' read -r _ _ _ _ _ _ _ cell _ <<ROW
$row
ROW
  trim "$cell"
}

# What the last case left as that run's output — its contents, or `no log` when
# there is none. Derived through suite_log_path against the guard repo, so this
# reads the file the writer was supposed to write rather than a second guess at
# where it should have gone.
guard_kept_log() {
  local saved=$root path
  root=$guard_repo
  path=$(suite_log_path "$(guard_recorded_when)")
  root=$saved
  if [ -f "$path" ]; then
    cat "$path"
  else
    printf 'no log'
  fi
}

# The calls a run stopping at preflight entry $1 should leave: the guard, then
# every entry up to and including that one. Spelled from PREFLIGHT so a case
# asserts the order the script is given rather than a copy of it that can drift.
guard_calls_through() {
  local stop=$1 entry name
  printf 'pgrep\n'
  for entry in "${PREFLIGHT[@]}"; do
    name=$(preflight_name "$entry")
    printf '%s\n' "$name"
    [ "$name" = "$stop" ] && return 0
  done
}

# A clean "nothing matched" is the only one of the three that starts a build, and
# it still does: the point of the change is that the other two do not. The whole
# call list is asserted, so this is also where the preflight is shown to run —
# all of it, in the order PREFLIGHT names it, ahead of xcodebuild rather than
# beside or after it.
run_guard 1 ''
check 'pgrep matched nothing — the preflight runs, in order, then the suite' \
  'pgrep
scripts/test-check-target-membership.py
scripts/test-run-unit-suite.sh
scripts/test-kiteloop-verify.py
scripts/test-export-coverage-lcov.py
quality/tests/run.sh
quality/bin/gate.py
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
xcodebuild
scripts/export-coverage-lcov.py
quality/bin/check-crap.py
quality/bin/gate.py' "$guard_calls"
check 'a finished run leaves a record' 'present' "$(guard_record_state)"
# The postflight runs after the row, only after a green one, and its failure
# makes the exit red without touching the row.
check 'a green run exits 0 with the postflight green' 0 "$guard_exit"
guard_fail_preflight='quality/bin/check-crap.py' guard_fail_status=1 run_guard 1 ''
check 'a failing postflight makes a green run exit red' 1 "$guard_exit"
check 'and the row still stands' 'present' "$(guard_record_state)"
check_contains 'and it says which gate failed, after the row' 'postflight failed (quality/bin/check-crap.py)' "$guard_out"
guard_fail_preflight='' guard_fail_status=''

# The CRAP gate's own glob over DerivedData matches every checkout on the
# machine, newest wins — so the postflight is handed this run's own bundle
# path, read out of the log the same way the row's own bundle cell is, rather
# than left to guess among them. A log naming a bundle gets it appended as
# --bundle, as its own argv element rather than pasted into the entry's text.
guard_xcodebuild_output='Writing result bundle at path:
/private/tmp/guard-derived-data/Test-Kiteloop.xcresult
	 Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds'
run_guard 1 ''
check 'a run whose log names a bundle still exits 0 with the postflight green' 0 "$guard_exit"
check_contains 'and the postflight is handed that bundle with --bundle' \
  '--bundle /private/tmp/guard-derived-data/Test-Kiteloop.xcresult' \
  "$(cat "$tmp/guard-postflight-args" 2>/dev/null)"
guard_xcodebuild_output=''

# And a run whose log names no bundle at all — the ordinary shim output above
# — leaves the postflight entry exactly as PREFLIGHT/POSTFLIGHT wrote it.
run_guard 1 ''
check 'a run whose log names no bundle runs the postflight entry unchanged' \
  '--quiet' "$(cat "$tmp/guard-postflight-args" 2>/dev/null)"

# The flag that spreads the suite over host clones — 657s to 93s — read off
# what the build was actually handed, not off the array that is meant to hold it.
check_contains 'the build is asked to run the suite in parallel' \
  '-parallel-testing-enabled YES' "$(cat "$tmp/guard-xcodebuild-args")"

run_guard 0 ''
check 'the app is running — refused, and nothing was started' 'pgrep' "$guard_calls"
# BSD pgrep leaves its own ancestors out unless told otherwise, and a worker the
# app spawned descends from Kiteloop — so a probe without `-a` says "not
# running" from exactly the shell this guard exists for.
check_contains 'the probe includes its own ancestors (-a) — the app that spawned the shell counts' \
  ' -a ' " $(tr '\n' ' ' <"$tmp/guard-calls.args") "
check_contains 'the running refusal says which app to quit' \
  'run-unit-suite: Kiteloop is running — quit it first.' "$guard_out"
check 'the running refusal exits non-zero' 'non-zero' "$(zeroness "$guard_exit")"

# The case this item exists for: pgrep could not look, which used to run the
# suite.
run_guard 2 'pgrep: illegal option -- z'
check 'pgrep could not answer — refused, and nothing was started' 'pgrep' "$guard_calls"
check_contains 'the unknown refusal says it could not tell' \
  'run-unit-suite: cannot tell whether Kiteloop is running' "$guard_out"
check_contains 'the unknown refusal names the status it got' 'pgrep exited 2' "$guard_out"
check_contains 'the unknown refusal prints what pgrep said, rather than discarding it' \
  'pgrep: illegal option -- z' "$guard_out"
check 'the unknown refusal exits non-zero' 'non-zero' "$(zeroness "$guard_exit")"

# A pgrep that is not on PATH arrives as the shell's own 127 and its own message.
# It is the "verify pgrep is usable" case, and it needs no separate check: being
# unable to run it is one of the answers.
run_guard 127 'sh: pgrep: command not found'
check 'no pgrep to run — refused, and nothing was started' 'pgrep' "$guard_calls"
check_contains 'a missing pgrep refuses loudly, naming the cause' \
  'command not found' "$guard_out"

# A pgrep that failed and explained nothing: the refusal says that in so many
# words rather than leaving a blank where the reason belongs.
run_guard 3 ''
check 'a silent failure — refused, and nothing was started' 'pgrep' "$guard_calls"
check_contains 'a pgrep that explained nothing is reported as such' \
  'pgrep printed nothing to say why.' "$guard_out"

# --- A preflight that found something -----------------------------------------
#
# One case per entry, because they run one after another and a single case would
# only show the entry it happened to pick: a loop that checked the status of the
# first entry alone passes a case about the first entry. Each fails with its own
# status — 2, 3, 4 by position, neither the 1 a blanket failure would return nor
# the 65 xcodebuild returns for a red suite — so a script that flattened the
# status into a constant satisfies none of them.
#
# What each case asserts is the whole of what the preflight is for: the run stops
# at the check that failed, with the later checks and the build unreached; the
# caller is handed that check's own status; the refusal names the check, which is
# the actionable part, since the three fail for entirely different reasons; and
# docs/suite-status.md is not written, because a preflight failure means no suite
# ran and a row says one did.
for guard_index in "${!PREFLIGHT[@]}"; do
  guard_stub=$(preflight_name "${PREFLIGHT[$guard_index]}")
  guard_expected_status=$((guard_index + 2))

  guard_fail_preflight=$guard_stub
  guard_fail_status=$guard_expected_status
  run_guard 1 ''
  guard_fail_preflight=""
  guard_fail_status=0

  check "$guard_stub failed — the run stops there, and no build starts" \
    "$(guard_calls_through "$guard_stub")" "$guard_calls"
  check "$guard_stub failed — the caller gets its status, not one of its own" \
    "$guard_expected_status" "$guard_exit"
  check_contains "$guard_stub failed — the refusal names which check it was" \
    "run-unit-suite: preflight failed ($guard_stub)" "$guard_out"
  check "$guard_stub failed — nothing was measured, so nothing is recorded" \
    'absent' "$(guard_record_state)"
done

# --- The package's own tally, captured end to end ------------------------------
#
# The generic stub above says nothing beyond its own name — every case up to
# here has the row's package tally cell reading a dash for exactly that reason.
# These two rewrite it once, for themselves alone, to print what the real
# scripts/run-core-tests.sh prints for itself, so the preflight loop's capture
# is exercised end to end rather than only through append_record directly.
guard_core_tests_stub="$guard_repo/scripts/run-core-tests.sh"
guard_core_tests_stub_backup=$(cat "$guard_core_tests_stub")

cat >"$guard_core_tests_stub" <<'STUB'
#!/bin/sh
printf 'scripts/run-core-tests.sh\n' >>"$GUARD_CALLS"
printf 'Building for debugging...\n'
printf 'Build complete!\n'
printf 'OK: KiteloopCore — Executed 42 tests, with 0 failures (0 unexpected) in 1.234 (1.240) seconds\n'
exit 0
STUB
chmod +x "$guard_core_tests_stub"
run_guard 1 ''
check 'the package tally a real run prints lands in the row it appends' \
  'Executed 42 tests, with 0 failures (0 unexpected) in 1.234 (1.240) seconds' \
  "$(guard_recorded_core_tally)"
check_contains 'and the terminal still sees that line, unchanged' \
  'OK: KiteloopCore — Executed 42 tests, with 0 failures (0 unexpected) in 1.234 (1.240) seconds' \
  "$guard_out"

cat >"$guard_core_tests_stub" <<'STUB'
#!/bin/sh
printf 'scripts/run-core-tests.sh\n' >>"$GUARD_CALLS"
printf 'OK: KiteloopCore — no XCTest tally printed\n'
exit 0
STUB
chmod +x "$guard_core_tests_stub"
run_guard 1 ''
check 'a package run that named no tally of its own records a dash' \
  '—' "$(guard_recorded_core_tally)"

# A closing line naming a skip count is taken verbatim, the same as any other
# tally text — core_tally_from_output reads everything after `OK: KiteloopCore
# — ` with no parsing of its own, so this asserts the skip count reaches the
# row's package tally cell rather than being dropped or reparsed on the way.
cat >"$guard_core_tests_stub" <<'STUB'
#!/bin/sh
printf 'scripts/run-core-tests.sh\n' >>"$GUARD_CALLS"
printf 'OK: KiteloopCore — 42 tests total (41 XCTest, 1 swift-testing, 2 skipped)\n'
exit 0
STUB
chmod +x "$guard_core_tests_stub"
run_guard 1 ''
check 'a package run that named a skip count carries it into the row' \
  '42 tests total (41 XCTest, 1 swift-testing, 2 skipped)' \
  "$(guard_recorded_core_tally)"

printf '%s\n' "$guard_core_tests_stub_backup" >"$guard_core_tests_stub"
chmod +x "$guard_core_tests_stub"

# --- Keeping the output, end to end -------------------------------------------
#
# The decision and the path are asserted above on their own; these are the whole
# run doing it — the copy of the script, its own timestamp, its own record — so
# that a writer wired to the wrong variable, or writing after the EXIT trap had
# already removed the log, is caught here rather than passing a unit case about
# a function nothing calls.

guard_red_output=$(cat <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' failed (0.002 seconds).
    Symbol.swift:41: error: -[SkillTests testProfileLoads] : XCTAssertEqual failed: ("2") is not equal to ("3")
     Executed 3 tests, with 1 failure (0 unexpected) in 0.100 (0.101) seconds
LOG
)

guard_xcodebuild_output=$guard_red_output
guard_xcodebuild_status=65
run_guard 1 ''
guard_xcodebuild_output=""
guard_xcodebuild_status=0
check 'a red run leaves its whole output at the derived path, verbatim' \
  "$guard_red_output" "$(guard_kept_log)"
check_contains 'a red run says where it put it' 'Full output kept at ' "$guard_out"
check 'a red run still records its row' 'present' "$(guard_record_state)"

# A run that measured nothing exited 0, so nothing about its status says to keep
# the output — and the output is the only account of what it did instead.
guard_no_tally_output=$(cat <<'LOG'
2026-08-12 09:00:00.000 xcodebuild[1:2] Writing error result bundle to /tmp/ResultBundle.xcresult
xcodebuild: error: Scheme Kiteloop is not currently configured for the test action.
LOG
)
guard_xcodebuild_output=$guard_no_tally_output
run_guard 1 ''
guard_xcodebuild_output=""
check 'a run that measured nothing leaves its output too, though it exited 0' \
  "$guard_no_tally_output" "$(guard_kept_log)"

# And the two ends of that sentence, tied: the row this run appended is the row
# the readout has to recognise, so what the writer put in the tally cell is read
# back through show_last rather than spelled twice and hoped about. A record
# whose sentence had drifted from the reader's would pass every case above and
# report this run, the one that measured nothing, exactly like a green one.
guard_saved_root=$root
root=$guard_repo
actual=$(show_last "$guard_repo/$RECORD_RELPATH" | sed -n 's/^  nothing //p')
root=$guard_saved_root
check 'the row that run wrote is the row the readout calls unmeasured' \
  "that run matched no tests, so nothing was measured — the exit above is xcodebuild's own status and not a passing suite." \
  "$actual"

# The ordinary green run, which is nearly every run: nothing kept, so the
# directory holds the handful of runs someone will actually want to read.
run_guard 1 ''
check 'a clean run leaves nothing behind' 'no log' "$(guard_kept_log)"
check_contains 'a clean run still records its row' 'Recorded in' "$guard_out"

# The two stamps, wired end to end: the copy of the script takes them around its
# own build and writes the difference into its own record. The cases above assert
# what duration_cell returns for a pair of epochs; this is the pair actually being
# taken, which a function nothing called would still have passed.
check 'a finished run records how long it took' \
  'a whole number of seconds' "$(guard_recorded_duration)"

# --- A wedged build outliving its ceiling -------------------------------------
#
# The failure this item exists for: the row at 0b618076 in docs/suite-status.md
# sat 7h45m (27929s) before a person noticed a hung xcodebuild and killed it by
# hand, next to green runs either side of it that took about 520s each. Nothing
# in the file bounded that run, so nothing could have ended it sooner or told
# the next reader what had happened. These cases drive the real watchdog end to
# end against a shim that sleeps well past a ceiling small enough for a test —
# set through SUITE_TIMEOUT_SECONDS, which the script reads from the
# environment for exactly this.

guard_xcodebuild_sleep=30
guard_suite_timeout_seconds=2
before=$(date -u +%s)
run_guard 1 ''
after=$(date -u +%s)
guard_xcodebuild_sleep=""
guard_suite_timeout_seconds=""

check 'a wedged build is ended near its ceiling, not waited out for 30s' \
  'yes' "$([ $((after - before)) -lt 20 ] && printf 'yes' || printf 'no, took %ss' "$((after - before))")"
check 'a wedged build — the script still exits non-zero' \
  'non-zero' "$(zeroness "$guard_exit")"
check 'the appended row names the ceiling in its tally cell' \
  "$(timeout_tally_cell 2)" "$(guard_recorded_tally)"
check "the row's exit cell is not zero — a killed process, not a pass" \
  'non-zero' "$(zeroness "$(guard_recorded_exit)")"
check 'the row still carries a whole-number duration, the shape every row has' \
  'a whole number of seconds' "$(guard_recorded_duration)"
check_contains 'the run says it ended the build at its ceiling' \
  'ran past its 2s time limit' "$guard_out"
# This shim printed nothing before it wedged, so no case had started and there is
# nothing for the row to name — the compilation-wedge shape, recorded as its
# neighbours record having nothing to say.
check 'a wedge with no test in flight names none' '—' "$(guard_recorded_failing)"

# --last reads that row without calling it a passing suite — the same
# qualification an empty tally already gets.
guard_saved_root=$root
root=$guard_repo
actual=$(show_last "$guard_repo/$RECORD_RELPATH" | sed -n 's/^  nothing //p')
root=$guard_saved_root
check '--last does not read a ceiling row as a passing suite' \
  "that run matched no tests, so nothing was measured — the exit above is xcodebuild's own status and not a passing suite." \
  "$actual"

# The other ceiling: a host that stops printing mid-suite. The shim sleeps 30s in
# silence; with the idle ceiling at 2s and the outer one far off, the idle arm
# ends it, and the row says so in its own words — not the time limit's.
guard_xcodebuild_sleep=30
guard_suite_timeout_seconds=60
guard_suite_idle_seconds=2
guard_pgrep_pids='4242 4343'
before=$(date -u +%s)
run_guard 1 ''
after=$(date -u +%s)
guard_xcodebuild_sleep=""
guard_suite_timeout_seconds=""
guard_suite_idle_seconds=""
guard_pgrep_pids=""
# Before it is ended, each test host is sampled, and the stacks are kept beside
# the run's log: the wedge otherwise leaves only its last output line.
check 'an idle wedge samples every test host before ending it' \
  '4242 2
4343 2' "$(cat "$tmp/guard-samples")"
check 'the samples are kept beside the log, one section per host' \
  '2' "$(cat "$guard_repo"/.kiteloop/suite-logs/*.samples.txt 2>/dev/null | grep -c 'stub stack of')"
check_contains 'and the run says where they are' \
  'sampled the test hosts before ending the wedge' "$guard_out"
check 'a silent build is ended near the idle ceiling, well before the time limit' \
  'yes' "$([ $((after - before)) -lt 20 ] && printf 'yes' || printf 'no, took %ss' "$((after - before))")"
check_contains 'the run says the build printed nothing' \
  'printed nothing for 2s' "$guard_out"
check 'the appended row names the idle ceiling in its tally cell' \
  'no tally — xcodebuild printed nothing for 2s and was ended' "$(guard_recorded_tally)"
check 'an idle wedge — the script still exits non-zero' \
  'non-zero' "$(zeroness "$guard_exit")"
actual=$(show_last "$guard_repo/$RECORD_RELPATH" | sed -n 's/^  nothing //p')
check '--last does not read an idle row as a passing suite' \
  "that run matched no tests, so nothing was measured — the exit above is xcodebuild's own status and not a passing suite." \
  "$actual"

# The same wedge over a build that had got as far as running tests, which is the
# shape the row at 3eaccf6a took: the record names what it was sitting on. The
# reader is asserted above against synthetic logs; this is the copy of the script
# choosing it over the failing reader for a run it ended itself, and writing the
# answer into its own row — the wiring a unit case about a function nothing calls
# would still have passed.
guard_xcodebuild_output=$(cat <<'LOG'
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' started.
Test Case '-[KiteloopTests.SkillTests testProfileLoads]' passed (0.002 seconds).
Test Case '-[KiteloopTests.PipeTests testPipeReadFromGCD]' started.
LOG
)
guard_xcodebuild_sleep=30
guard_suite_timeout_seconds=2
run_guard 1 ''
guard_xcodebuild_output=""
guard_xcodebuild_sleep=""
guard_suite_timeout_seconds=""

check 'a run ended by the time limit, not the idle ceiling, samples nothing' \
  '' "$(cat "$tmp/guard-samples")"
check 'the row a wedged run appends names the test that was in flight' \
  'KiteloopTests.PipeTests.testPipeReadFromGCD' "$(guard_recorded_failing)"
check 'and its tally still says the run was ended at its ceiling' \
  "$(timeout_tally_cell 2)" "$(guard_recorded_tally)"

guard_saved_root=$root
root=$guard_repo
actual=$(show_last "$guard_repo/$RECORD_RELPATH" | sed -n 's/^  hung    //p')
root=$guard_saved_root
check 'and --last reads that row as hung rather than failed' \
  'KiteloopTests.PipeTests.testPipeReadFromGCD' "$actual"

# A wedged build that has itself started a child — the shape a real
# xcodebuild run takes, unlike the exec'd shim above, which has no children to
# leave behind. Signalling only $build_pid, the bug this item exists for,
# would end the shim and orphan the child; the process-group signal has to
# reach both.
guard_xcodebuild_child_sleep=8645
guard_suite_timeout_seconds=2
run_guard 1 ''
guard_xcodebuild_child_sleep=""
guard_suite_timeout_seconds=""
leftover=$(pgrep -f 'sleep 8645' 2>/dev/null)
check 'a wedged build whose child outlives it — neither the shim nor the child is left running' \
  '' "$leftover"
check 'a wedged build whose child outlives it — the script still exits non-zero' \
  'non-zero' "$(zeroness "$guard_exit")"

# A build that finishes well inside the ceiling is unaffected by any of this:
# the same green row every other case here already records, and — since the
# watchdog is ended the moment the build finishes — no leftover process still
# holding a slot open. The ceiling is picked to be distinctive: nothing else on
# a test machine is expected to be sleeping for exactly that many seconds, so a
# match after this run means this run's own watchdog, not some coincidence.
guard_suite_timeout_seconds=8643
run_guard 1 ''
guard_suite_timeout_seconds=""
check 'a build finishing inside the ceiling — the same tally it always got' \
  'Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds' \
  "$(guard_recorded_tally)"
check 'a build finishing inside the ceiling — the same exit cell too' \
  '0' "$(guard_recorded_exit)"
leftover=$(pgrep -f 'sleep 8643' 2>/dev/null)
check 'a build finishing inside the ceiling leaves no watchdog process behind' \
  '' "$leftover"

# And the same, over a run whose output is worth keeping, so the kept log can
# be checked byte for byte: nothing the watchdog does — a stray line, a kill
# message — belongs in a build's own output.
guard_xcodebuild_output=$guard_red_output
guard_xcodebuild_status=65
guard_suite_timeout_seconds=8644
run_guard 1 ''
guard_xcodebuild_output=""
guard_xcodebuild_status=0
guard_suite_timeout_seconds=""
check 'a red run inside the ceiling keeps a log with nothing added by the watchdog' \
  "$guard_red_output" "$(guard_kept_log)"
leftover=$(pgrep -f 'sleep 8644' 2>/dev/null)
check 'and leaves no watchdog process behind either' '' "$leftover"

# --- A Mac that goes to sleep under the run -----------------------------------
#
# The ceiling above measures wall clock, and a Mac left alone spends some of it
# asleep: nine unattended minutes of a suite run look exactly like an idle
# machine. The sleeping time is charged against SUITE_TIMEOUT_SECONDS all the
# same, so a run nothing was wrong with is ended at the limit and recorded as a
# build that outran its time limit — a red measurement of nothing, and in the
# record indistinguishable from the wedge the ceiling exists to catch.
#
# So a run holds a power assertion for as long as the build is up. These cases
# read it off a caffeinate shim that records the invocation and then does what
# `caffeinate -w` does, which is where the assertion's whole lifetime lives: it
# ends when the pid it was given does. The pid is compared against the one the
# build shim recorded for itself, because that is the other half of the
# arrangement — $build_pid has to stay xcodebuild's own pid for the ceiling to
# signal its process group and for the wait to report its status, which is why
# the assertion is taken out beside the build rather than wrapped around it.

run_guard 1 ''
check 'the build shim recorded a pid for the assertion to be compared against' \
  'a pid' \
  "$(printf '%s' "$guard_build_pid" | grep -qE '^[0-9]+$' &&
     printf 'a pid' || printf 'not a pid: %s' "$guard_build_pid")"
check 'a run holds an idle- and system-sleep assertion over the build itself' \
  "-i -s -w $guard_build_pid" "$(guard_caffeinate_log | sed -n 1p)"
check 'and the assertion is released once that build has been reaped' \
  "released $guard_build_pid" "$(guard_caffeinate_log | sed -n 2p)"
check 'so nothing is left holding one after the run' '' "$guard_caffeinate_leftover"
check 'a run under an assertion records the tally it always recorded' \
  'Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds' \
  "$(guard_recorded_tally)"
check "and xcodebuild's own exit status, which is what wait still returns" \
  '0' "$(guard_recorded_exit)"

# The same over a build the ceiling ends, which is the run the assertion exists
# to stop being manufactured: $build_pid is still xcodebuild's own pid — the
# assertion was over the very process the timeout arm signals — and the row is
# the one such a run has always written.
guard_xcodebuild_sleep=30
guard_suite_timeout_seconds=2
run_guard 1 ''
guard_xcodebuild_sleep=""
guard_suite_timeout_seconds=""
check 'a build ended at the ceiling had its assertion held over that same pid' \
  "-i -s -w $guard_build_pid" "$(guard_caffeinate_log | sed -n 1p)"
check 'and the assertion is released when the ceiling ends it' \
  "released $guard_build_pid" "$(guard_caffeinate_log | sed -n 2p)"
check 'a build ended at the ceiling leaves nothing holding an assertion' \
  '' "$guard_caffeinate_leftover"
check 'and still records the ceiling in its tally cell' \
  "$(timeout_tally_cell 2)" "$(guard_recorded_tally)"
check "and still records xcodebuild's own non-zero exit" \
  'non-zero' "$(zeroness "$(guard_recorded_exit)")"

# A machine with no caffeinate on PATH. The assertion is the only thing it
# loses: the preflight runs, the build runs, and the row is written, because a
# run that cannot be held awake is still a run worth measuring.
guard_no_caffeinate=1
run_guard 1 ''
check 'no caffeinate on PATH — the run still reaches the build' \
  'xcodebuild' "$(printf '%s\n' "$guard_calls" | grep -x xcodebuild)"
check 'no caffeinate on PATH — and still records its row' \
  'present' "$(guard_record_state)"
check 'no caffeinate on PATH — with the tally every green run records' \
  'Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds' \
  "$(guard_recorded_tally)"
check 'no caffeinate on PATH — the run exits 0, as that run always did' \
  '0' "$guard_exit"
check 'no caffeinate on PATH — and no assertion was taken out' \
  '' "$(cat "$tmp/guard-caffeinate")"
# Nor is anything said about it. This is what asking PATH first buys over
# reaching for caffeinate and letting it fail: a run whose output carries
# `caffeinate: command not found` is a run someone has to decide is fine, in the
# middle of the one output they read to find out whether the suite passed.
check_lacks 'no caffeinate on PATH — and the run does not complain about it' \
  'caffeinate' "$guard_out"

# And what --dry-run says on that machine: the line beside the ceiling states
# what will actually happen there rather than promising an assertion nothing can
# take out.
run_guard 1 '' --dry-run
guard_no_caffeinate=""
check_contains '--dry-run on a machine without caffeinate says nothing holds it awake' \
  'power:   no caffeinate on this machine' "$guard_out"

# --dry-run and --last are the two commands that stay usable while the app is up,
# and they answer before any of this — so a broken pgrep cannot stop them either.
# Asserted by the empty call list: neither shim was reached at all.
run_guard 2 'pgrep: cannot read the process list' --dry-run
check '--dry-run answers before the check' '0' "$guard_exit"
check_contains '--dry-run prints the command it would run' \
  'xcodebuild -project Kiteloop.xcodeproj' "$guard_out"
check_contains '--dry-run names the timeout ceiling' \
  "${SUITE_TIMEOUT_SECONDS}s" "$guard_out"
check_contains '--dry-run names the power assertion beside that ceiling' \
  'power:   caffeinate -i -s holds an idle- and system-sleep assertion' "$guard_out"
# Both guard suites are standing preflight steps, not entries a later edit to
# PREFLIGHT can drop unnoticed: each ran nowhere a suite run could see it until
# they were added here, so their continued presence in the listing is asserted
# directly rather than left to whoever next reads the array by eye.
check_contains "--dry-run lists cleat's suites through their runner" \
  'quality/tests/run.sh' "$guard_out"
check_contains '--dry-run lists the control-forwarder installer guard' \
  'scripts/test-install-control-forwarder.sh' "$guard_out"
check '--dry-run reads no process list and starts no build' '' "$guard_calls"
# Nor does it take out the assertion it names: asking PATH whether caffeinate is
# there runs nothing, which is the same reason --dry-run can answer while
# Kiteloop is up.
check '--dry-run takes out no assertion — it only says one would be held' \
  '' "$(cat "$tmp/guard-caffeinate")"

# --- The dry-run listing in docs/testing.md ------------------------------------
#
# docs/testing.md quotes, by hand, what `--dry-run` prints under "The suite and
# its preflight" — so it drifts the moment PREFLIGHT changes, and nothing else
# compares the two. Unlike the cases above, this runs --dry-run for real,
# against this repository, with the ceiling env vars unset so the printed
# defaults are the ones the doc quotes, and checks it line for line against the
# fenced block in the doc.

# The fenced block that follows the sentence "which is what `--dry-run`
# prints:" in the given file — found by that sentence rather than by position,
# since two other fenced examples sit under the same heading ahead of it.
dry_run_listing_in_doc() {
  awk '
    marker {
      if (/^```/) {
        if (started) { exit }
        started = 1
        next
      }
      if (started) { print }
      next
    }
    /which is what `--dry-run` prints:/ { marker = 1 }
  ' "$1"
}

doc_dry_run_listing=$(dry_run_listing_in_doc "$root/docs/testing.md")
real_dry_run_listing=$(cd "$root" && env -u SUITE_TIMEOUT_SECONDS -u SUITE_IDLE_SECONDS \
  ./scripts/run-unit-suite.sh --dry-run)

if [ "$doc_dry_run_listing" = "$real_dry_run_listing" ]; then
  printf '  ok    docs/testing.md quotes what --dry-run actually prints\n'
else
  printf '  FAIL  docs/testing.md quotes what --dry-run actually prints\n'
  diff <(printf '%s\n' "$doc_dry_run_listing") <(printf '%s\n' "$real_dry_run_listing") |
    sed 's/^/          /'
  failed=$((failed + 1))
fi

# A copy of the doc, in this case's own temporary directory, with one line of
# the listing dropped — so this case is known to report a real drift, not only
# to stay quiet when there is none. Asserted against the copy; the real
# document is never touched.
mutated_doc=$tmp/testing-dry-run-mutated.md
grep -v -x -F 'quality/bin/gate.py --skip-missing-tools' "$root/docs/testing.md" >"$mutated_doc"
mutated_listing=$(dry_run_listing_in_doc "$mutated_doc")
mutated_diff=$(diff <(printf '%s\n' "$mutated_listing") <(printf '%s\n' "$real_dry_run_listing"))
check 'a line dropped from a copy of the listing is caught' \
  'differs' "$([ "$mutated_listing" != "$real_dry_run_listing" ] && printf 'differs' || printf 'matches')"
check_contains 'and the diff names the dropped line' \
  'quality/bin/gate.py --skip-missing-tools' "$mutated_diff"

run_guard 2 'pgrep: cannot read the process list' --last
check '--last answers before the check' '0' "$guard_exit"
check_contains '--last reads the record' 'no suite run has been recorded yet' "$guard_out"
check '--last reads no process list and starts no build' '' "$guard_calls"

run_guard 2 'pgrep: cannot read the process list' --flakes
check '--flakes answers before the check' '0' "$guard_exit"
check_contains '--flakes reads the record' 'no suite run has been recorded yet' "$guard_out"
check '--flakes reads no process list and starts no build' '' "$guard_calls"

# --- What --help prints -------------------------------------------------------
#
# The header block is where the refusal, the preflight and the exit-status rules
# are stated to someone at a terminal, and usage printed it as a line range —
# `sed -n '2,53p'`. A range is right on the day it is written and says nothing
# afterwards: a paragraph added to the header falls off the end of --help, and one
# removed pushes `set -u` and the code under it into the output as though it were
# documentation. Neither shows up as an error, which is why these cases assert the
# boundary rather than the text — where the printed block stops, and that it stops
# before the code.
#
# They run against their own copy, which one of them then edits, so the guard
# repository above is left as its cases left it. Running the copy costs nothing
# and risks nothing: --help is answered while the options are parsed, before the
# process list is read or a build is started, which is also why it is one of the
# commands that stays usable while Kiteloop is up.

help_repo=$tmp/help-repo
mkdir -p "$help_repo"
cp "$here/run-unit-suite.sh" "$help_repo/run-unit-suite.sh"

# The last comment line of a file's header block, as --help would print it —
# read out of the file rather than spelled here, so these cases keep meaning
# "the whole block" after someone edits the block. Written as a read loop, not
# as the expression usage uses, so a reader that has stopped reading correctly
# is not compared against a copy of itself.
last_header_line() {
  local line n=0 last=''
  while IFS= read -r line; do
    n=$((n + 1))
    [ "$n" -eq 1 ] && continue
    case $line in
      '#'*) last=$line ;;
      *) break ;;
    esac
  done <"$1"
  last=${last#\#}
  printf '%s' "${last# }"
}

# The first line of shell code under that block — the line a help that ran past
# the end of the header would print first.
first_code_line() {
  local line n=0
  while IFS= read -r line; do
    n=$((n + 1))
    [ "$n" -eq 1 ] && continue
    case $line in
      '#'*|'') ;;
      *) printf '%s' "$line"; return ;;
    esac
  done <"$1"
}

help_out=$("$help_repo/run-unit-suite.sh" --help)
check '--help stops at the last line of the header block' \
  "$(last_header_line "$help_repo/run-unit-suite.sh")" \
  "$(printf '%s\n' "$help_out" | tail -n 1)"
check_lacks '--help prints no shell code as though it were documentation' \
  "$(first_code_line "$help_repo/run-unit-suite.sh")" "$help_out"

# A paragraph added to the header is the edit that used to truncate the help. It
# goes in at the end of the block — ahead of the first line that is not a comment
# — and usage is not touched.
help_added='# A line added to the header by test-run-unit-suite.'
awk -v added="$help_added" '
  NR > 1 && !inserted && !/^#/ { print added; inserted = 1 }
  { print }
' "$help_repo/run-unit-suite.sh" >"$tmp/help-grown" || exit 1
cat "$tmp/help-grown" >"$help_repo/run-unit-suite.sh"

grown_out=$("$help_repo/run-unit-suite.sh" --help)
check 'a line added to the header is a line added to --help, with usage untouched' \
  "$help_out
A line added to the header by test-run-unit-suite." "$grown_out"

# usage is the one reader that could not be asserted beside the others, because
# it read "$0" — under `source` that is this file, so a sourced copy printed
# test-run-unit-suite's header instead of its own. Sourced in a subshell, so the
# copy's functions do not stand in for the real ones in the cases above.
sourced_out=$(. "$help_repo/run-unit-suite.sh" && usage)
check 'a sourced copy prints the help of the copy, not of whatever sourced it' \
  "$grown_out" "$sourced_out"

# --- Every PREFLIGHT entry is named in --help ----------------------------------
#
# The header narrates PREFLIGHT by hand, so nothing but reading ties the prose
# to the array — a twenty-first entry, or a paragraph dropped for one already
# there, would not fail on its own. This asserts the tie directly: every
# PREFLIGHT command, without its arguments, must appear somewhere in --help's
# output. Checked against $help_out, the unmutated copy's help from above.

# The command each PREFLIGHT entry runs, without its arguments — the same split
# command_line uses to print one.
missing_preflight_commands() {
  local help_text=$1 entry cmd
  shift
  for entry in "$@"; do
    read -r cmd _ <<<"$entry"
    case $help_text in
      *"$cmd"*) ;;
      *) printf '%s\n' "$cmd" ;;
    esac
  done
}

check 'every PREFLIGHT command is named in --help' \
  '' "$(missing_preflight_commands "$help_out" "${PREFLIGHT[@]}")"

# A copy of the header with the paragraph naming one entry gone — the state
# this case exists to catch — reports exactly that entry rather than staying
# quiet or naming the wrong one.
dropped_repo=$tmp/help-repo-dropped
mkdir -p "$dropped_repo"
grep -v -F 'scripts/test-verify-map-replay.sh' "$here/run-unit-suite.sh" \
  >"$dropped_repo/run-unit-suite.sh"
chmod +x "$dropped_repo/run-unit-suite.sh"
dropped_out=$("$dropped_repo/run-unit-suite.sh" --help)
check 'a paragraph dropped from the header is caught, and the entry is named' \
  'scripts/test-verify-map-replay.sh' \
  "$(missing_preflight_commands "$dropped_out" "${PREFLIGHT[@]}")"

printf '\n'
if [ "$failed" -eq 0 ]; then
  printf 'test-run-unit-suite: all cases passed.\n'
  exit 0
fi
printf 'test-run-unit-suite: %s case(s) failed.\n' "$failed" >&2
exit 1
