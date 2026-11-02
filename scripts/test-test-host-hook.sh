#!/bin/bash
# test-test-host-hook — run the PreToolUse backstop itself, end to end, and
# assert which commands it denies.
#
# `scripts/check-test-host-hook.sh` reads the hook's `grep -E` pattern and asks
# what it classifies. That is one half of the hook: the pattern decides *what a
# command says*, but the hook decides whether to deny, and between the two sits
# the step that hands the command to grep at all. A bug there is invisible to a
# pattern check, because the pattern is right and never sees the command.
#
# One was. `grep` matches a line at a time, and the hook fed it the command as
# written, so the ordinary way an agent lays out a long xcodebuild —
#
#   cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj \
#     -scheme Kiteloop -only-testing:KiteloopTests test
#
# — put `xcodebuild` on one line and `test` on the next and matched neither. The
# same command on one line was denied. That is the command CLAUDE.md records
# taking the app down and stranding two in-flight items, and whether the backstop
# caught it came down to where the author had pressed return.
#
# So this drives the hook command read *out of* `.claude/settings.json` — not a
# copy of it, which could agree with itself while disagreeing with the hook that
# actually runs — with a stub `pgrep` first on PATH standing in for the two
# answers that matter, and the tool_input JSON the harness sends it on stdin.
#
# One last case drops the stub and lets the hook ask the real process list, then
# holds its answer against `ps`. A stub cannot stand in for the pattern the hook
# hands to `pgrep`, and that pattern was an instance of what it searched for: see
# "The real process list" at the foot of this file.
#
# It starts no build and spawns no xcodebuild — it only reads the process list —
# so it is safe to run at any time, including while Kiteloop is running.
#
#   ./scripts/test-test-host-hook.sh

set -u

here=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
root=$(cd -- "$here/.." && pwd -P) || exit 1
settings="$root/.claude/settings.json"

if ! command -v jq >/dev/null 2>&1; then
  # The hook shells out to jq itself, so a checkout without it cannot run the
  # hook either — but say so rather than reporting on a hook that never ran.
  printf 'FAIL: jq is not on PATH, so the hook command cannot be read or run.\n' >&2
  exit 1
fi

hook=$(jq -r '
  [.hooks.PreToolUse[]?.hooks[]? | select(.type == "command") | .command]
  | map(select(test("xcodebuild")))
  | if length == 1 then .[0] else "" end
' "$settings" 2>/dev/null)

if [ -z "$hook" ]; then
  printf 'FAIL: %s has no single PreToolUse command hook mentioning xcodebuild.\n' \
    "$settings" >&2
  printf 'The backstop that denies an app-hosted test run is gone, or there are now\n' >&2
  printf 'several and this test can no longer tell which one to drive.\n' >&2
  exit 1
fi

tmp=$(mktemp -d -t test-test-host-hook) || exit 1
trap 'rm -rf "$tmp"' EXIT

# The hook calls `pgrep` unqualified, so a stub first on PATH is what answers it.
# One stub, its verdict chosen per case through the environment: 0 is "Kiteloop
# is running", 1 is the clean "nothing matched".
stubs="$tmp/bin"
mkdir -p "$stubs"
cat >"$stubs/pgrep" <<'STUB'
#!/bin/sh
[ -z "${HOOK_PGREP_ARGS:-}" ] || printf '%s\n' "$*" >>"$HOOK_PGREP_ARGS"
exit ${HOOK_PGREP_STATUS:-1}
STUB
chmod +x "$stubs/pgrep"

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

check_contains() {
  local name=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) printf '  ok    %s\n' "$name" ;;
    *)
      printf '  FAIL  %s\n          expected to contain: %s\n          actual:   %s\n' \
        "$name" "$needle" "$haystack"
      failed=$((failed + 1))
      ;;
  esac
}

# Run the hook the way the harness does: the tool_input object on stdin, the
# command inside it verbatim — `jq -Rs` slurps stdin as one raw string, so the
# newlines and backslashes of a continued command survive into the JSON exactly
# as an agent typed them. Leaves the hook's stdout in hook_out and its status in
# hook_exit.
run_hook() {
  local pgrep_status=$1 command=$2
  hook_out=$(printf '%s' "$command" \
    | jq -Rs '{tool_input: {command: .}}' \
    | env PATH="$stubs:$PATH" HOOK_PGREP_STATUS="$pgrep_status" HOOK_PGREP_ARGS="$tmp/pgrep-args" sh -c "$hook")
  hook_exit=$?
}

# What the harness reads off the hook: nothing at all is "allow", and anything
# else has to be the deny document, spelled the way a PreToolUse hook spells it.
verdict() {
  local pgrep_status=$1 command=$2
  run_hook "$pgrep_status" "$command"
  if [ -z "$hook_out" ]; then
    printf 'allow'
    return
  fi
  printf '%s' "$hook_out" \
    | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null \
    || printf 'malformed'
}

# The commands. Each pair is the same action, once on a line and once laid out
# across backslash continuations the way anybody writes a command this long —
# and the hook has to reach the same verdict for both, which is the whole of what
# this file is here to hold.
SINGLE_TEST='cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" -only-testing:KiteloopTests test'
CONTINUED_TEST='cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj \
  -scheme Kiteloop -destination "platform=macOS" \
  -only-testing:KiteloopTests test'
# A destination or result-bundle value with a space in it -- the ordinary
# spelling for a named Mac, or for a result bundle path under a directory
# whose name has a space -- is still a test action and must still be denied.
SPACED_VALUE_TEST='cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS,name=My Mac" test'
SINGLE_BUILD='cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build-for-testing'
CONTINUED_BUILD='cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj \
  -scheme Kiteloop -destination "platform=macOS" \
  build-for-testing'
# Two commands, not one continued command: nothing joins these lines, and the
# second is the shell's own `test`. Joining every newline rather than only the
# continuations would run them together into `xcodebuild -showBuildSettings
# -project Kiteloop.xcodeproj test -f …`, which the pattern matches — so a
# perfectly safe script would be denied. This is the case that says the join is
# the shell's join and not a flatten.
UNRELATED_TEST_LINE='xcodebuild -showBuildSettings -project Kiteloop.xcodeproj
test -f build/Release/Kiteloop.app'
# The companion's own test action: KiteloopMobile.xcodeproj's tests are hosted
# by the iOS simulator, not by Kiteloop.app, so this must never be denied even
# though the action word is `test` and the pgrep guard would otherwise fire.
SINGLE_MOBILE_TEST='xcodebuild -project KiteloopMobile/KiteloopMobile.xcodeproj -scheme KiteloopMobile -destination "platform=iOS Simulator,name=iPhone 15" test'
CONTINUED_MOBILE_TEST='xcodebuild -project KiteloopMobile/KiteloopMobile.xcodeproj \
  -scheme KiteloopMobile -destination "platform=iOS Simulator,name=iPhone 15" \
  test'

# --- Kiteloop is running ------------------------------------------------------

printf '\nKiteloop is running\n'

check 'a single-line `xcodebuild … test` is denied' \
  'deny' "$(verdict 0 "$SINGLE_TEST")"
check 'the same command across backslash continuations is denied' \
  'deny' "$(verdict 0 "$CONTINUED_TEST")"
check 'a test action whose destination value has a space is denied' \
  'deny' "$(verdict 0 "$SPACED_VALUE_TEST")"
check 'a single-line `build-for-testing` is not denied' \
  'allow' "$(verdict 0 "$SINGLE_BUILD")"
check 'a continued `build-for-testing` is not denied' \
  'allow' "$(verdict 0 "$CONTINUED_BUILD")"
check 'a later line that merely starts with `test` is not denied' \
  'allow' "$(verdict 0 "$UNRELATED_TEST_LINE")"
check 'a single-line KiteloopMobile test action is not denied' \
  'allow' "$(verdict 0 "$SINGLE_MOBILE_TEST")"
check 'the same KiteloopMobile test action across backslash continuations is not denied' \
  'allow' "$(verdict 0 "$CONTINUED_MOBILE_TEST")"

# --- Kiteloop is not running --------------------------------------------------
#
# The pattern still matches; there is just nothing to take down. Nothing the
# join changed may turn a quiet machine into a refusal.

printf '\nKiteloop is not running\n'

check 'a single-line `xcodebuild … test` is allowed' \
  'allow' "$(verdict 1 "$SINGLE_TEST")"
check 'a continued `xcodebuild … test` is allowed' \
  'allow' "$(verdict 1 "$CONTINUED_TEST")"
check 'a single-line `build-for-testing` is allowed' \
  'allow' "$(verdict 1 "$SINGLE_BUILD")"
check 'a continued `build-for-testing` is allowed' \
  'allow' "$(verdict 1 "$CONTINUED_BUILD")"
check 'a later line that starts with `test` is allowed' \
  'allow' "$(verdict 1 "$UNRELATED_TEST_LINE")"

# --- What the denial says -----------------------------------------------------
#
# The refusal is read by a person mid-task, so it has to name the app, the reason
# and the way out. The message is not copied here in full — a copy is the drift
# this file avoids for the hook command itself — but a continued command must
# arrive at the identical document, since the two are the same command and a
# denial that read differently would be a second code path.

printf '\nthe denial\n'

run_hook 0 "$SINGLE_TEST"
single_deny=$hook_out
check 'the deny path exits 0, as a hook that has spoken through its output does' \
  '0' "$hook_exit"
check 'the denial is one JSON document' \
  'PreToolUse' "$(printf '%s' "$single_deny" | jq -r '.hookSpecificOutput.hookEventName')"
reason=$(printf '%s' "$single_deny" | jq -r '.hookSpecificOutput.permissionDecisionReason')
check_contains 'the reason says the app is running' 'Kiteloop is running:' "$reason"
check_contains 'the reason says what would happen' 'terminates the running instance' "$reason"
check_contains 'the reason names the way out' 'quit Kiteloop first' "$reason"

run_hook 0 "$CONTINUED_TEST"
check 'a continued command is denied with the identical document' \
  "$single_deny" "$hook_out"

run_hook 1 "$SINGLE_BUILD"
check 'an allowed command exits 0' '0' "$hook_exit"
check 'and says nothing at all' '' "$hook_out"

printf '\n'
# BSD pgrep leaves its own ancestors out of a match unless told otherwise, and
# the shell this hook guards — an agent the app spawned — descends from Kiteloop.
# A probe without `-a` hears "not running" from exactly that shell.
: >"$tmp/pgrep-args"
run_hook 0 'xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop test'
check_contains 'the probe includes its own ancestors (-a) — the app that spawned the shell counts' \
  ' -a ' " $(tr '\n' ' ' <"$tmp/pgrep-args") "

# --- The real process list ----------------------------------------------------
#
# Every case above answers a stub, which is what makes them deterministic — and
# what let a bug live in the one part of the hook a stub cannot stand in for: the
# pattern it hands to `pgrep`. `pgrep -f` matches a whole command line, `-a` puts
# the probe's own ancestors back in the match, and the command line the harness
# runs the hook on *is the hook*, pattern and all — so the pattern matched the
# shell asking the question. Measured on 2026-09-09 with the app quit,
# `sh -c 'pgrep -a -f "<the app path>"'` printed two pids and exited 0: the hook
# answered "Kiteloop is running" on a quiet machine and refused every test run
# through xcodebuild, with nothing running to protect. The first dot is bracketed
# now, so the pattern text is no longer an instance of what it searches for.
#
# So one case runs the hook with the real `pgrep` — no stub on PATH — and holds
# its verdict against the process list read a way that cannot match the reader:
# the pids whose *argv[0]* is the app binary. A shell that merely carries the
# path as an argument has a different argv[0], so it never counts as the app
# here. The two must agree, which is both halves of the rule at once — with
# Kiteloop quit the hook lets a test run through, with Kiteloop up it still
# refuses — and it does not matter which is true while this runs.

printf '\nthe real process list\n'

# The hook, run the way the harness runs it, with nothing standing in for pgrep.
# It sets hook_exit as run_hook does, so a case that reads it after this cannot
# pick up the status of the last stubbed run instead.
run_hook_real() {
  hook_out=$(printf '%s' "$1" \
    | jq -Rs '{tool_input: {command: .}}' \
    | sh -c "$hook")
  hook_exit=$?
}

real_verdict() {
  run_hook_real "$1"
  if [ -z "$hook_out" ]; then
    printf 'allow'
    return
  fi
  printf '%s' "$hook_out" \
    | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null \
    || printf 'malformed'
}

kiteloop_pids=$(ps -Ao pid=,args= \
  | awk '$2 ~ /Kiteloop[.]app\/Contents\/MacOS\/Kiteloop$/ { print $1 }')
if [ -n "$kiteloop_pids" ]; then
  expected_real=deny
  ground='ps says it is running'
else
  expected_real=allow
  ground='ps says it is not running'
fi

before=$failed
check "the hook agrees with the process list about the app ($ground)" \
  "$expected_real" "$(real_verdict "$SINGLE_TEST")"
if [ "$failed" -ne "$before" ]; then
  # Which way it disagreed is the whole diagnosis, so say what each side saw.
  probe=$(printf '%s' "$hook" | sed -n 's/.*pgrep -a -f "\([^"]*\)".*/\1/p')
  printf '          pids whose argv[0] is the app binary: %s\n' \
    "$(printf '%s' "${kiteloop_pids:-none}" | tr '\n' ' ')"
  # `; :` keeps this a compound command, so the shell does not exec pgrep in
  # place and stays on the process list as its ancestor — the shape the hook's
  # own probe runs in, and the one a self-match shows up in.
  printf '          what the hook probe matched:\n'
  sh -c "pgrep -a -f \"$probe\"; :" 2>&1 | sed 's/^/            /'
fi

# `build-for-testing` never reaches the probe at all, so it is allowed against
# the real process list whatever that list says — including on the machine the
# refusal above was measured on, where it was the only verify left standing.
check 'a `build-for-testing` is allowed against the real process list' \
  'allow' "$(real_verdict "$SINGLE_BUILD")"

printf '\n'
if [ "$failed" -eq 0 ]; then
  printf 'test-test-host-hook: all cases passed.\n'
  exit 0
fi
printf 'test-test-host-hook: %s case(s) failed.\n' "$failed" >&2
exit 1
