#!/bin/bash
# check-test-host-hook — fail if the PreToolUse backstop classifies an xcodebuild
# command wrongly.
#
# `KiteloopTests` is hosted by `Kiteloop.app`, so any xcodebuild action that
# *runs* the tests launches a second Kiteloop as the XCTest host and macOS
# terminates the running instance — including the app running an autopilot item,
# which strands that item mid-run. The `PreToolUse` hook in
# `.claude/settings.json` denies those commands while the app is up; it is a
# backstop, but it is the last one, and nothing else notices when it stops
# covering an action.
#
# It stopped covering one. The pattern required whitespace or end-of-line after
# `test`, which is what keeps `build-for-testing` — the standing verify — from
# being denied, but it also let `test-without-building` through: that action runs
# the tests and takes the app down exactly as `test` does, and it is the natural
# next command after the `build-for-testing` CLAUDE.md recommends. A regex whose
# only reader is a hook nobody watches fire is not something to hand-check again.
#
# So this reads the pattern *out of* `.claude/settings.json` rather than keeping
# a copy of it, and runs a table of commands through `grep -E` exactly as the
# hook does. A copy could agree with itself while disagreeing with the hook that
# actually runs, which is the whole failure being checked for.
#
# It judges the classification — which commands the pattern matches — and one
# thing about the guard beside it, because that one is textual too: the pattern
# the hook hands to `pgrep -f` must not match the hook's own command line, which
# is what the shell running it carries, and must still match a real Kiteloop's.
# Spelled with a plain dot it matched itself, and the hook refused every test run
# on a machine where the app was down. Whether the hook then denies a particular
# process list is the guard's business and `scripts/test-test-host-hook.sh` takes
# it; this script reads no process list, starts no build and spawns no xcodebuild:
# it is safe to run at any time, including while Kiteloop is running.
#
# Exits non-zero and names every command the pattern classifies wrongly.
#
# Usage
#   ./scripts/check-test-host-hook.sh          # report every case
#   ./scripts/check-test-host-hook.sh --quiet  # only print on failure

set -u

quiet=0
case "${1-}" in
  --quiet) quiet=1 ;;
  "") ;;
  *)
    printf 'usage: %s [--quiet]\n' "$0" >&2
    exit 2
    ;;
esac

here=$(cd -- "$(dirname -- "$0")" && pwd -P) || exit 1
root=$(cd -- "$here/.." && pwd -P) || exit 1
settings="$root/.claude/settings.json"

if ! command -v jq >/dev/null 2>&1; then
  # The hook itself shells out to jq, so a checkout without it cannot run the
  # hook either -- but say so rather than reporting a pattern that was never read.
  printf 'FAIL: jq is not on PATH, so the hook command cannot be read.\n' >&2
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
  printf 'several and this check can no longer tell which one to read.\n' >&2
  exit 1
fi

# The pattern is the argument to the hook's own `grep -Eq '...'`. It contains no
# single quote, so the first quoted run after `grep -Eq ` is the whole of it; a
# pattern that grew one would come out truncated, and the cases below would fail
# rather than pass on a fragment.
pattern=$(printf '%s' "$hook" | sed -n "s/.*grep -Eq '\\([^']*\\)'.*/\\1/p")

if [ -z "$pattern" ]; then
  printf 'FAIL: could not read a `grep -Eq` pattern out of the hook command in %s.\n' \
    "$settings" >&2
  printf 'The hook no longer classifies commands the way this check knows how to read,\n' >&2
  printf 'so it cannot be checked -- teach this script the new shape.\n' >&2
  exit 1
fi

# The hook's other pattern: the one it hands to `pgrep -f` to decide whether
# Kiteloop is actually up. Read out of the hook for the same reason as the one
# above, and by the same shape -- it is the first double-quoted run after
# `pgrep -a -f `, and the app path contains no double quote.
probe=$(printf '%s' "$hook" | sed -n 's/.*pgrep -a -f "\([^"]*\)".*/\1/p')

if [ -z "$probe" ]; then
  printf 'FAIL: could not read a `pgrep -a -f` pattern out of the hook command in %s.\n' \
    "$settings" >&2
  printf 'The hook no longer asks the process list the way this check knows how to read,\n' >&2
  printf 'so its probe cannot be checked -- teach this script the new shape.\n' >&2
  exit 1
fi

# Every case is a command someone plausibly types in this repo, with the verdict
# the hook must reach for it. `deny` means the action runs the tests and would
# take a running Kiteloop down with it; `allow` means it does not.
#
# The two `allow` build actions matter as much as the denials: the standing verify
# is `build-for-testing`, and a pattern that swallowed it would make the one check
# every run performs undeniable-by-hook work.
CASES=(
  'deny|cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" test'
  'deny|xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" -only-testing:KiteloopTests test'
  'deny|cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" test-without-building'
  'deny|xcodebuild -scheme Kiteloop test-without-building -destination "platform=macOS"'
  'allow|cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build-for-testing'
  'allow|cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build'
  'allow|xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS" build-for-testing -derivedDataPath .kiteloop/DerivedData'
  'allow|xcodebuild -showBuildSettings -project Kiteloop.xcodeproj'
  'deny|cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS,name=My Mac" test'
  'allow|cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination "platform=macOS,name=My Mac" build-for-testing'
)

wrong=()
for entry in "${CASES[@]}"; do
  expected=${entry%%|*}
  command=${entry#*|}
  if printf '%s' "$command" | grep -Eq "$pattern"; then
    actual=deny
  else
    actual=allow
  fi
  if [ "$actual" != "$expected" ]; then
    wrong+=("$expected|$actual|$command")
  elif [ "$quiet" -eq 0 ]; then
    printf '  ok    %-5s %s\n' "$actual" "$command"
  fi
done

# The probe decides the other half of the verdict: having classified a command as
# one that runs the tests, the hook denies it only if Kiteloop is up. `pgrep -f`
# matches a whole command line, and `-a` — which the probe needs, so that a worker
# the app itself spawned still counts its own ancestor — puts the probe's own
# ancestors back in the match. The command line the harness runs the hook on *is
# the hook*, pattern and all, so a pattern that is a literal instance of what it
# searches for matches the shell running it: the hook reports the app up on a
# machine where it is down and refuses every test run, guarding nothing. Measured
# on 2026-09-09 with the app quit, `sh -c 'pgrep -a -f
# "Kiteloop.app/Contents/MacOS/Kiteloop"'` printed two pids and exited 0.
#
# Two things have to hold at once, and either alone is easy to satisfy: the probe
# must not match the text of the hook that carries it, and it must still match a
# real Kiteloop. A pattern that matched nothing would pass the first.
PROBE_CASES=(
  "match|a Debug build run out of DerivedData|/Users/me/Library/Developer/Xcode/DerivedData/Kiteloop-abcdefgh/Build/Products/Debug/Kiteloop.app/Contents/MacOS/Kiteloop"
  "match|an installed Release build|/Applications/Kiteloop.app/Contents/MacOS/Kiteloop"
  "nomatch|the hook's own command line, which the shell running it carries|$hook"
  "nomatch|a shell that merely quotes the probe|sh -c pgrep -a -f \"$probe\""
)

probe_wrong=()
for entry in "${PROBE_CASES[@]}"; do
  expected=${entry%%|*}
  rest=${entry#*|}
  label=${rest%%|*}
  subject=${rest#*|}
  if printf '%s' "$subject" | grep -Eq "$probe"; then
    actual=match
  else
    actual=nomatch
  fi
  if [ "$actual" != "$expected" ]; then
    probe_wrong+=("$expected|$actual|$label")
  elif [ "$quiet" -eq 0 ]; then
    printf '  ok    %-7s %s\n' "$actual" "$label"
  fi
done

if [ ${#wrong[@]} -eq 0 ] && [ ${#probe_wrong[@]} -eq 0 ]; then
  if [ "$quiet" -eq 0 ]; then
    printf '\nOK: the PreToolUse pattern classifies all %s command(s) as it must,\n' \
      "${#CASES[@]}"
    printf 'and its probe answers all %s process line(s) as it must.\n' \
      "${#PROBE_CASES[@]}"
  fi
  exit 0
fi

if [ ${#wrong[@]} -ne 0 ]; then
  printf 'FAIL: %s xcodebuild command(s) are classified wrongly by the PreToolUse hook\n' \
    "${#wrong[@]}" >&2
  printf 'pattern in %s:\n\n' "$settings" >&2
  for entry in "${wrong[@]}"; do
    expected=${entry%%|*}
    rest=${entry#*|}
    actual=${rest%%|*}
    command=${rest#*|}
    printf '  wrongly %s (must be %s):\n    %s\n' "$actual" "$expected" "$command" >&2
  done
  printf '\nThe pattern read from the hook was:\n  %s\n' "$pattern" >&2
  printf '\nA command wrongly allowed runs the app-hosted suite while Kiteloop is up,\n' >&2
  printf 'terminating the running instance and stranding any autopilot item mid-run.\n' >&2
  printf 'A command wrongly denied blocks work that never launches a test host --\n' >&2
  printf 'including `build-for-testing`, the standing verify.\n' >&2
fi

if [ ${#probe_wrong[@]} -ne 0 ]; then
  printf 'FAIL: the PreToolUse hook probe answers %s process line(s) wrongly:\n\n' \
    "${#probe_wrong[@]}" >&2
  for entry in "${probe_wrong[@]}"; do
    expected=${entry%%|*}
    rest=${entry#*|}
    actual=${rest%%|*}
    label=${rest#*|}
    printf '  wrongly %s (must be %s):\n    %s\n' "$actual" "$expected" "$label" >&2
  done
  printf '\nThe probe read from the hook was:\n  %s\n\n' "$probe" >&2
  printf 'A probe that matches the command line it is carried on finds the shell running\n' >&2
  printf 'the hook and reports Kiteloop up on a machine where it is down, so every test\n' >&2
  printf 'run through xcodebuild is refused while nothing is at risk. A probe that no\n' >&2
  printf 'longer matches a real Kiteloop reports it down while it is up, and the suite\n' >&2
  printf 'takes the app and its autopilot run with it. Bracket the first dot --\n' >&2
  printf '`Kiteloop[.]app` -- so the pattern text is not an instance of what it searches\n' >&2
  printf 'for.\n' >&2
fi
exit 1
