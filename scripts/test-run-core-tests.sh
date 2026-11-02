#!/bin/bash
# test-run-core-tests — assert scripts/run-core-tests.sh runs `swift test` in the
# package and hands back swift's own verdict.
#
# The script is three lines of substance and one of them is the exit status, so
# the failure this guards against is the usual one: a `swift test` whose status
# is dropped on the way out, and a red package reading green in the preflight.
# A stub `swift` on PATH records what it was asked and exits as a case tells it
# to; each case runs a copy of the script from a throwaway root with a
# Package.swift in the right place. It starts no build (the stub is the build),
# reads no process list, and writes nothing outside a temporary directory.
#
#   ./scripts/test-run-core-tests.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
failed=0
check() {
  local name=$1 expected=$2 actual=$3
  if [ "$actual" = "$expected" ]; then printf '  ok    %s\n' "$name"
  else printf '  FAIL  %s\n          expected: %s\n          actual:   %s\n' "$name" "$expected" "$actual"; failed=$((failed + 1)); fi
}
check_contains() {
  local name=$1 needle=$2 haystack=$3
  case "$haystack" in *"$needle"*) printf '  ok    %s\n' "$name" ;; *) printf '  FAIL  %s\n          expected to contain: %s\n          got: %s\n' "$name" "$needle" "$haystack"; failed=$((failed + 1)) ;; esac
}
check_not_contains() {
  local name=$1 needle=$2 haystack=$3
  case "$haystack" in *"$needle"*) printf '  FAIL  %s\n          expected not to contain: %s\n          got: %s\n' "$name" "$needle" "$haystack"; failed=$((failed + 1)) ;; *) printf '  ok    %s\n' "$name" ;; esac
}

tmp=$(mktemp -d -t run-core-tests)
trap 'rm -rf "$tmp"' EXIT
fixture=$tmp/repo; mkdir -p "$fixture/scripts" "$fixture/Kiteloop/KiteloopCore" "$tmp/bin"
cp "$here/run-core-tests.sh" "$fixture/scripts/"
printf '// swift-tools-version: 6.0\n' >"$fixture/Kiteloop/KiteloopCore/Package.swift"
cat >"$tmp/bin/swift" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_CALLS"
pwd >>"$STUB_CALLS"
# Ignoring TERM (inherited by the sleep below, exec'd with the same
# disposition) is what lets a stub finish on its own, past the ceiling,
# rather than being cut short by it — the reaped-as-0 race the second new
# case below drives.
if [ -n "${STUB_IGNORE_TERM:-}" ]; then
  trap '' TERM
fi
if [ -n "${STUB_PRE_SLEEP_OUTPUT:-}" ]; then
  printf '%s\n' "$STUB_PRE_SLEEP_OUTPUT"
fi
if [ -n "${STUB_SLEEP:-}" ]; then
  sleep "$STUB_SLEEP" &
  child=$!
  echo "$child" >"$STUB_PID_FILE"
  wait "$child"
fi
printf '%s\n' "${STUB_OUTPUT:-}"
exit "${STUB_STATUS:-0}"
STUB
chmod +x "$tmp/bin/swift"
run() { STUB_CALLS=$tmp/calls STUB_STATUS=$1 STUB_OUTPUT=$2 PATH="$tmp/bin:$PATH" "$fixture/scripts/run-core-tests.sh" 2>&1; }

: >"$tmp/calls"
out=$(run 0 $'Test Suite \'All tests\' passed\n\t Executed 9 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds'); status=$?
check 'a green swift test — exit 0' 0 "$status"
check 'swift was asked to test, with coverage for the CRAP gate' 'test --enable-code-coverage' "$(sed -n 1p "$tmp/calls")"
check 'from inside the package' "$fixture/Kiteloop/KiteloopCore" "$(sed -n 2p "$tmp/calls")"
check_contains 'the success line carries the total' 'OK: KiteloopCore — 9 tests total' "$out"
check_contains 'and the XCTest breakdown' '9 XCTest' "$out"
check_not_contains 'no swift-testing breakdown when it printed nothing' 'swift-testing' "$out"
check 'and no "skipped" clause — the line unchanged from before skips were counted' \
  'OK: KiteloopCore — 9 tests total (9 XCTest)' "$out"

out=$(run 0 'Test run with 20 tests in 2 suites passed after 0.005 seconds.'); status=$?
check 'swift-testing alone — exit 0, not NO_TALLY_STATUS' 0 "$status"
check_contains 'the success line carries the total' 'OK: KiteloopCore — 20 tests total' "$out"
check_contains 'and the swift-testing breakdown' '20 swift-testing' "$out"
check_not_contains 'no XCTest breakdown when it printed nothing' 'XCTest' "$out"

out=$(run 0 $'Test Case \'-[KiteloopCoreTests.VerifyDefaultCoverageTests testLiveVerifyRuns]\' skipped (0.001 seconds).\n\t Executed 9 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds'); status=$?
check 'a skipped case — still exit 0' 0 "$status"
check_contains 'the success line names the skip count' '9 XCTest, 1 skipped' "$out"

out=$(run 0 $'Test Case \'-[KiteloopCoreTests.Suite testA]\' skipped (0.001 seconds).\nTest Case \'-[KiteloopCoreTests.Suite testA]\' skipped (0.001 seconds).\nTest Case \'-[KiteloopCoreTests.Suite testB]\' skipped (0.001 seconds).\n\t Executed 9 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds'); status=$?
check_contains 'a case reported once per nesting suite is counted once, not per line' '9 XCTest, 2 skipped' "$out"

out=$(run 0 $'Test Suite \'All tests\' passed\n\t Executed 9 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds\nTest run with 20 tests in 2 suites passed after 0.005 seconds.'); status=$?
check 'both frameworks — exit 0' 0 "$status"
check_contains 'the total is the sum of both' 'OK: KiteloopCore — 29 tests total' "$out"
check_contains 'the XCTest count is named' '9 XCTest' "$out"
check_contains 'the swift-testing count is named' '20 swift-testing' "$out"

out=$(run 1 $'Test Case \'-[KiteloopCoreTests.LineBufferTests testSplitsCompleteLines]\' failed (0.001 seconds).\n\t Executed 9 tests, with 1 failure'); status=$?
check 'a red swift test — its own status, not a constant' 1 "$status"
check_contains 'the failing case is in the output' 'LineBufferTests testSplitsCompleteLines' "$out"
check_contains 'and the verdict names the package' 'FAIL: swift test exited 1 in Kiteloop/KiteloopCore' "$out"
check_contains 'and names the failing case on the FAIL line itself' \
  'FAIL: swift test exited 1 in Kiteloop/KiteloopCore — failed: KiteloopCoreTests.LineBufferTests.testSplitsCompleteLines' "$out"

out=$(run 1 $'Test Case \'-[KiteloopCoreTests.LineBufferTests testSplitsCompleteLines]\' failed (0.001 seconds).\nTest Case \'-[KiteloopCoreTests.HookEngineTests testTimeout]\' failed (0.002 seconds).\nTest Case \'-[KiteloopCoreTests.LineBufferTests testSplitsCompleteLines]\' failed (0.001 seconds).\n\t Executed 9 tests, with 2 failures'); status=$?
check 'several red cases — still the status swift left with' 1 "$status"
check_contains 'both are named, suite-qualified, first-appearance order, comma separated' \
  'FAIL: swift test exited 1 in Kiteloop/KiteloopCore — failed: KiteloopCoreTests.LineBufferTests.testSplitsCompleteLines, KiteloopCoreTests.HookEngineTests.testTimeout' "$out"

out=$(run 1 $'error: cannot find \'LineBuffer\' in scope\nerror: build failed'); status=$?
check 'a red run that closed no case — still the status swift left with' 1 "$status"
check_contains 'the FAIL line carries the status and says no test was named' \
  'FAIL: swift test exited 1 in Kiteloop/KiteloopCore — no test was named as failing' "$out"
check_not_contains 'and names none' 'failed:' "$out"

out=$(run 70 'error: something went wrong'); status=$?
check 'a swift that died — that status too' 70 "$status"

out=$(run 0 ''); status=$?
check 'a green swift test with no tally from either framework — exit NO_TALLY_STATUS' 70 "$status"
check_contains 'the verdict says no tally, not OK' 'FAIL: swift test exited 0 but printed no test tally' "$out"
check_not_contains 'no OK line for a run that measured nothing' 'OK: KiteloopCore' "$out"

# The ceiling firing and swift test finishing on its own (ignoring TERM) can
# race: swift exits 0 before the KILL that follows TERM ever lands, and
# `wait` reaps that 0 — a run this script already called FAIL by wall clock.
: >"$tmp/calls"
out=$(STUB_CALLS=$tmp/calls STUB_IGNORE_TERM=1 STUB_SLEEP=2.5 STUB_STATUS=0 \
  STUB_OUTPUT=$'Executed 3 tests, with 0 failures' CORE_TEST_TIMEOUT_SECONDS=1 \
  PATH="$tmp/bin:$PATH" "$fixture/scripts/run-core-tests.sh" 2>&1); status=$?
check 'ended at the ceiling but reaped 0 — still a non-zero exit' 'yes' \
  "$([ "$status" -ne 0 ] && echo yes || echo "no ($status)")"
check_contains 'the closing line still says it was ended at the ceiling' 'ran past its 1s time limit — ended (exited 0)' "$out"
check_not_contains 'no OK line for a run ended at the ceiling' 'OK: KiteloopCore' "$out"

: >"$tmp/calls"
pidfile=$tmp/stub.pid
start=$SECONDS
out=$(STUB_CALLS=$tmp/calls STUB_SLEEP=30 STUB_PID_FILE="$pidfile" CORE_TEST_TIMEOUT_SECONDS=1 \
  PATH="$tmp/bin:$PATH" "$fixture/scripts/run-core-tests.sh" 2>&1); status=$?
elapsed=$((SECONDS - start))
check 'a hung swift test — returns within a few seconds' 'yes' "$([ "$elapsed" -le 15 ] && echo yes || echo "no ($elapsed s)")"
check 'a hung swift test — a non-zero status' 'yes' "$([ "$status" -ne 0 ] && echo yes || echo "no ($status)")"
check_contains 'the closing line says it was ended at the ceiling' 'ran past its 1s time limit — ended' "$out"
check_contains 'no case had started — the closing line says so and names none' 'no test had started' "$out"
check_not_contains 'no OK line for a run ended at the ceiling' 'OK: KiteloopCore' "$out"
check 'the stub'"'"'s own child is gone once the script returns' 'gone' \
  "$(kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null && echo alive || echo gone)"

: >"$tmp/calls"
pidfile=$tmp/stub-open.pid
out=$(STUB_CALLS=$tmp/calls STUB_SLEEP=30 STUB_PID_FILE="$pidfile" CORE_TEST_TIMEOUT_SECONDS=1 \
  STUB_PRE_SLEEP_OUTPUT=$'Test Case \'-[KiteloopCoreTests.HookEngineTests testTimeout]\' started.' \
  PATH="$tmp/bin:$PATH" "$fixture/scripts/run-core-tests.sh" 2>&1); status=$?
check 'a case left open at the ceiling — a non-zero status' 'yes' "$([ "$status" -ne 0 ] && echo yes || echo "no ($status)")"
check_contains 'the closing line names the case still open when the ceiling fired' \
  'KiteloopCoreTests.HookEngineTests.testTimeout' "$out"
check_not_contains 'no OK line for a run ended at the ceiling' 'OK: KiteloopCore' "$out"

rm "$fixture/Kiteloop/KiteloopCore/Package.swift"
out=$(run 0 ''); status=$?
check 'no package — refused, exit 2' 2 "$status"

echo
if [ "$failed" -ne 0 ]; then echo "test-run-core-tests: $failed case(s) failed."; exit 1; fi
echo "test-run-core-tests: all cases passed."
