#!/bin/bash
# run-core-tests — the host-less core's tests, under `swift test`.
#
# Kiteloop/KiteloopCore is a Swift package the app depends on, and its tests
# run in a plain xctest process: no Kiteloop.app is launched, so this is safe
# while the app is up, the PreToolUse hook does not deny it, and an autopilot
# item's `verify:` can run it. It sits in the suite's preflight so every suite
# run runs these tests too, and CI with them; a failure stops the run with
# swift's own status, before any build, like every other preflight. xcodebuild
# builds a package test target only from a scheme Xcode itself wrote, and a
# hand-written testable for one is ignored, so the row the suite appends never
# builds this package's own tally — it is read instead off the `OK: KiteloopCore
# — …` line below, captured by the preflight loop before that line reaches the
# terminal, and carried into the row's own package tally cell beside the
# app-hosted one. Read it off this output, or run it yourself:
#
#   ./scripts/run-core-tests.sh
#   cd Kiteloop/KiteloopCore && swift test
#
# The run logs into a scratch directory of its own. KiteloopFileLogger.shared is
# built pointing at ~/.kiteloop, and a test process opens no project, so every
# line the package logs from a fixture — a store reporting a write it could not
# make, a tokens file moved aside — used to be appended to the day's log in the
# human's own Kiteloop home, tens of thousands of lines per run, on top of what
# the running app writes there. KITELOOP_LOG_BASE_DIRECTORY sends them to a
# temporary directory this script throws away on exit. It is not the fix — a
# bare `swift test` sets the same variable for itself, from the load-time
# constructor in Tests/KiteloopTestLogRedirect — it is only what makes this
# script clean up after the run it started.
#
# Runs under a wall-clock ceiling, CORE_TEST_TIMEOUT_SECONDS (default 600s —
# the package's own tests run in seconds today, so that is headroom, not a
# limit; override it in seconds to drive it faster under test). This is the
# one PREFLIGHT entry of scripts/run-unit-suite.sh with no ceiling of its own,
# so a hang here held the whole suite before any build started, silently.
#
# `swift test` exiting 0 is not on its own "green": a run that matched no
# tests, or stopped before any ran, can still exit 0 with neither an XCTest
# `Executed N tests` line nor a swift-testing `Test run with N tests` line
# anywhere in its output — measuring nothing while reporting success. Read
# that as a failure rather than as this preflight's own `OK:` line, the same
# verdict scripts/run-unit-suite.sh reaches for the app-hosted half with its
# own NO_TALLY_STATUS.
NO_TALLY_STATUS=70
set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
package="$root/Kiteloop/KiteloopCore"
[ -f "$package/Package.swift" ] || { echo "FAIL: no package at Kiteloop/KiteloopCore" >&2; exit 2; }
command -v swift >/dev/null 2>&1 || { echo "FAIL: swift is not on PATH" >&2; exit 2; }

cd "$package" || exit 2

CORE_TEST_TIMEOUT_SECONDS=${CORE_TEST_TIMEOUT_SECONDS:-600}

log=$(mktemp -t run-core-tests) || exit 2
log_base=$(mktemp -d -t kiteloop-core-test-logs) || exit 2
trap 'rm -f "$log"; rm -rf "$log_base"' EXIT

# Read by KiteloopFileLogger.defaultBaseURL(environment:): the tests' own log
# lines land under "$log_base/.kiteloop/logs" instead of ~/.kiteloop/logs.
export KITELOOP_LOG_BASE_DIRECTORY="$log_base"

# --enable-code-coverage: the export at .build/*/debug/codecov/KiteloopCore.json is
# what quality/bin/check-crap.py reads for the package's half of the CRAP gate.
#
# Backgrounded under job control so swift test leads its own process group
# ($build_pid as its pid) — that is what lets a run that outlives the ceiling
# be ended as a group below, reaching the xctest process swift test spawns to
# actually run the cases, rather than signalling swift test alone and leaving
# xctest reparented and still running. `set +m` turns job control back off
# immediately after, so the watchdog sleep below is an ordinary child.
set -m
swift test --enable-code-coverage >"$log" 2>&1 &
build_pid=$!
set +m

sleep "$CORE_TEST_TIMEOUT_SECONDS" &
watchdog_pid=$!

# Poll until one of the two ends — there is no coreutils timeout(1) on macOS.
while kill -0 "$build_pid" 2>/dev/null && kill -0 "$watchdog_pid" 2>/dev/null; do
  sleep 1
done

timed_out=0
if kill -0 "$build_pid" 2>/dev/null; then
  # The ceiling won the race and the run is still going: end it. TERM first,
  # with up to two seconds to notice it before KILL for whatever did not —
  # sent to the process group ("-$build_pid"), not just the pid.
  timed_out=1
  kill -TERM -"$build_pid" 2>/dev/null
  for _ in 1 2; do
    kill -0 "$build_pid" 2>/dev/null || break
    sleep 1
  done
  kill -KILL -"$build_pid" 2>/dev/null
fi
kill "$watchdog_pid" 2>/dev/null
wait "$watchdog_pid" 2>/dev/null

wait "$build_pid"
status=$?
output=$(cat "$log")

# The tally, in each framework's own words — the same lines the serial suite
# reader in scripts/run-unit-suite.sh matches for the app-hosted half — or, when
# the run failed, the last forty lines of output and a FAIL line naming what was
# red, since forty lines need not reach back to the first failure. The package runs
# both XCTest and swift-testing cases, and each prints only its own summary, so
# reading XCTest's line alone undercounts by however many swift-testing cases
# ran: neither is the other's substitute, and NO_TALLY_STATUS should fire only
# when neither printed one.
if [ "$timed_out" -eq 1 ]; then
  printf '%s\n' "$output" | grep -vE '^(Building|Build complete|\[[0-9]+/[0-9]+\])' | tail -n 40
  # A hung test is not a reported one, so it is read by subtraction: XCTest
  # opens every case with `Test Case '-[Suite testName]' started.` and closes
  # it with a `passed`, `failed` or `skipped` line carrying the same name.
  # Whatever was still open when the ceiling fired never got its close, and
  # that is what the run was sitting on — several names allowed, first
  # appearance kept, a dash when nothing had started (a build wedged in
  # compilation). Only XCTest is read: swift-testing announces no per-case
  # start, so there is nothing to subtract from. Same reading as
  # hung_tests_from_log in scripts/run-unit-suite.sh.
  hung=$(printf '%s\n' "$output" | sed -n -E \
    -e "s/^.*Test Case '-\[([^][ ]+) ([^][]+)\]' (started|passed|failed|skipped).*/\3 \1.\2/p" |
    awk '
      { state = $1; name = substr($0, length(state) + 2) }
      state == "started" {
        if (!(name in open)) order[++n] = name
        open[name] = 1
        next
      }
      { open[name] = 0 }
      END { for (i = 1; i <= n; i++) if (open[order[i]]) print order[i] }
    ' | awk '{ printf "%s%s", sep, $0; sep = ", " }')
  if [ -z "$hung" ]; then
    echo "FAIL: swift test ran past its ${CORE_TEST_TIMEOUT_SECONDS}s time limit — ended (exited $status) in Kiteloop/KiteloopCore — no test had started"
  else
    echo "FAIL: swift test ran past its ${CORE_TEST_TIMEOUT_SECONDS}s time limit — ended (exited $status) in Kiteloop/KiteloopCore — hung on $hung"
  fi
  # swift test can finish with status 0 in the gap between the last poll and
  # the TERM that follows the ceiling firing — reaped as a clean exit even
  # though the run above already called it a timeout. A run this script just
  # named FAIL does not get to leave with 0.
  [ "$status" -eq 0 ] && status=1
elif [ "$status" -eq 0 ]; then
  xctest_tally=$(printf '%s\n' "$output" | grep -E 'Executed [0-9]+ tests?' | tail -n 1 | sed 's/^[[:space:]]*//')
  swift_testing_tally=$(printf '%s\n' "$output" | grep -E 'Test run with [0-9]+ test' | tail -n 1 | sed 's/^[[:space:]]*//')
  if [ -z "$xctest_tally" ] && [ -z "$swift_testing_tally" ]; then
    echo "FAIL: swift test exited 0 but printed no test tally in Kiteloop/KiteloopCore"
    status=$NO_TALLY_STATUS
  else
    xctest_count=0
    swift_testing_count=0
    [ -n "$xctest_tally" ] && xctest_count=$(printf '%s' "$xctest_tally" | sed -n -E 's/.*Executed ([0-9]+) tests?.*/\1/p')
    [ -n "$swift_testing_tally" ] && swift_testing_count=$(printf '%s' "$swift_testing_tally" | sed -n -E 's/.*Test run with ([0-9]+) tests?.*/\1/p')
    total=$((xctest_count + swift_testing_count))
    breakdown=""
    [ -n "$xctest_tally" ] && breakdown="${breakdown}${breakdown:+, }${xctest_count} XCTest"
    [ -n "$swift_testing_tally" ] && breakdown="${breakdown}${breakdown:+, }${swift_testing_count} swift-testing"
    # XCTest counts a skipped case inside `Executed N tests`, so its own tally
    # cannot tell a skip from a pass — only the per-case close line does, one
    # `skipped` line per suite a case is nested under, deduped on first
    # appearance the way scripts/run-unit-suite.sh reads its own skipped cell.
    # Named only when non-zero, so a run that skipped nothing prints exactly
    # the line it always has.
    skipped_count=$(printf '%s\n' "$output" | sed -n -E \
      "s/^.*Test Case '-\[([^][ ]+) ([^][]+)\]' skipped.*/\1.\2/p" |
      awk '!seen[$0]++' | wc -l | tr -d ' ')
    [ "$skipped_count" -gt 0 ] && breakdown="${breakdown}${breakdown:+, }${skipped_count} skipped"
    echo "OK: KiteloopCore — ${total} tests total (${breakdown})"
  fi
else
  printf '%s\n' "$output" | grep -vE '^(Building|Build complete|\[[0-9]+/[0-9]+\])' | tail -n 40
  # A red run says which tests were red, rather than leaving it to be read out
  # of forty tail lines that may not even reach back to the first failure.
  # XCTest closes a failing case with `Test Case '-[Suite testName]' failed`,
  # once per suite the case is nested under, so the same name arrives more than
  # once — first appearance kept, joined the way the hung reader above joins
  # its own. Only XCTest is read, for the reason that reader already gives:
  # swift-testing prints no matching per-case line. A red run that named
  # nothing — a compile error, a crash before any case closed — says so.
  failures=$(printf '%s\n' "$output" | sed -n -E \
    "s/^.*Test Case '-\[([^][ ]+) ([^][]+)\]' failed.*/\1.\2/p" |
    awk '!seen[$0]++' | awk '{ printf "%s%s", sep, $0; sep = ", " }')
  if [ -z "$failures" ]; then
    echo "FAIL: swift test exited $status in Kiteloop/KiteloopCore — no test was named as failing"
  else
    echo "FAIL: swift test exited $status in Kiteloop/KiteloopCore — failed: $failures"
  fi
fi
exit "$status"
