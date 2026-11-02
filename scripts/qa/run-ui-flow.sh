#!/usr/bin/env bash
#
# One UI flow, for Kiteloop's QA agent (docs/qa-flow.md): a QA build of the app
# — its own bundle id (KITELOOP_QA_SUFFIX=.qa) and its own build folder, so the
# Kiteloop running the autopilot is never the app under test — launched by the
# flow's XCUITest against a throwaway home, and the screenshots it attached
# written out as a storyboard.
#
#   ./scripts/qa/run-ui-flow.sh Kiteloop/KiteloopUITests/QA/<id>.swift
#
# kiteloop-qa.json names this as its `run` and its `smoke`. The storyboard lands
# at Kiteloop/KiteloopUITests/QA/storyboards/<id>.md, one picture per step in
# storyboards/<id>/ — what the QA agent opens and judges. UI tests drive the
# screen, so runs take turns behind a lock.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
root=$PWD
spec=${1:?usage: run-ui-flow.sh Kiteloop/KiteloopUITests/QA/<id>.swift}
case "$spec" in Kiteloop/KiteloopUITests/QA/*.swift) ;; *) echo "run-ui-flow: $spec is not a flow under Kiteloop/KiteloopUITests/QA/" >&2; exit 2;; esac
[ -f "$spec" ] || { echo "run-ui-flow: no flow at $spec" >&2; exit 2; }
id=$(basename "$spec" .swift)
class=$(sed -n -E 's/^(final )?class ([A-Za-z_][A-Za-z0-9_]*): *QAStoryboardTestCase.*/\2/p' "$spec" | head -1)
[ -n "$class" ] || { echo "run-ui-flow: $spec declares no class subclassing QAStoryboardTestCase" >&2; exit 2; }

lock=${TMPDIR:-/tmp}/kiteloop-qa-ui.lock
until mkdir "$lock" 2>/dev/null; do
  owner=$(cat "$lock/pid" 2>/dev/null || echo "")
  if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$lock"; continue; fi
  echo "run-ui-flow: another QA run holds the screen (pid ${owner:-?}); waiting"; sleep 15
done
echo $$ >"$lock/pid"
work=$(mktemp -d "${TMPDIR:-/tmp}/kiteloop-qa.XXXXXX")
# Outside ~/Documents, where the repo usually lives: the QA copy is ad-hoc signed
# and rebuilt each run, so macOS treats every build as a new app and asks it
# again for any protected folder it touches — including the one its own build
# sits in. An unattended run has nobody to answer that.
derived=${KITELOOP_QA_DERIVED_DATA:-$HOME/Library/Caches/kiteloop-qa/DerivedData}
trap 'rm -rf "$lock"' EXIT
mkdir -p "$work/home"

# The signing identity: Kiteloop/Signing.local.xcconfig names it, and that file
# is git-ignored, so an item's worktree has none and its build came out ad-hoc
# signed — a new app to macOS every build, so every privacy grant the QA copy
# was given was lost on the next run (docs/unattended-permissions.md). The main
# checkout's copy is brought in; ignored, it is never part of the item's diff.
local_signing="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/Kiteloop/Signing.local.xcconfig"
if [ ! -f Kiteloop/Signing.local.xcconfig ] && [ -f "$local_signing" ]; then
  cp "$local_signing" Kiteloop/Signing.local.xcconfig
fi
if [ ! -f Kiteloop/Signing.local.xcconfig ]; then
  echo "run-ui-flow: no Kiteloop/Signing.local.xcconfig — the QA copy is ad-hoc signed, and macOS will ask it for every permission again on each build" >&2
fi

echo "▸ the QA build of $(git rev-parse --short HEAD), running $class"
status=0
TEST_RUNNER_KITELOOP_HOME="$work/home" xcodebuild -project Kiteloop/Kiteloop.xcodeproj -scheme KiteloopQA \
  -destination "platform=macOS" -derivedDataPath "$derived" \
  KITELOOP_QA_SUFFIX=.qa -resultBundlePath "$work/run.xcresult" \
  -only-testing:"KiteloopUITests/$class" test >"$work/xcodebuild.log" 2>&1 || status=$?
# awk, not grep: a run that never reached a test matches nothing, and that is not an error here.
awk '/Test (Case|Suite) .*(passed|failed)|error:/' "$work/xcodebuild.log" | tail -15 | sed 's/^/  /'

echo "▸ the storyboard"
board_dir=Kiteloop/KiteloopUITests/QA/storyboards
mkdir -p "$board_dir"
if [ -d "$work/run.xcresult" ] && xcrun xcresulttool export attachments --path "$work/run.xcresult" --output-path "$work/shots" >/dev/null; then
  python3 "$root/scripts/qa/write-storyboard.py" "$work/shots" "$board_dir" "$id" "$class"
else
  echo "run-ui-flow: the run left no result to export screenshots from — see $work/xcodebuild.log" >&2
  [ "$status" -ne 0 ] || status=1
fi
if [ "$status" -ne 0 ]; then
  # The storyboard says so itself: a red run's pictures can all look fine.
  if [ -f "$board_dir/$id.md" ]; then
    { printf '\n## The flow failed (exit %s)\n\n' "$status"; awk '/: error: /' "$work/xcodebuild.log" | sed -E 's/^.*: error: /- /'; } >>"$board_dir/$id.md"
  fi
  echo "run-ui-flow: the flow failed (exit $status); log: $work/xcodebuild.log" >&2
fi
exit "$status"
