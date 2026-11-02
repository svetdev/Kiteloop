#!/bin/bash
# test-verify-map-replay — assert scripts/verify-map-replay.sh reaches a real
# verdict on a merge commit, and refuses an empty changed-file list instead of
# printing COVERED for a comparison that never happened.
#
# `git show --name-only --format="" <rev>` prints nothing for a merge commit,
# and `VerifyCoverage.evaluate`'s `guard !paths.isEmpty else { return .covered }`
# — a documented fail-open, not this test's to touch — turns that silence into
# a clean COVERED nobody actually checked. These cases build tiny fixture
# repos with a real merge commit, drive the real script against them, and hold
# both ends: a merge commit reaches an actual verdict, and every other way to
# reach an empty changed-file list — an empty file, empty stdin, a commit that
# touches nothing — is refused with exit 2 rather than printed as coverage. A
# non-merge rev, a file of paths and stdin are also checked to still behave
# exactly as before.
#
#   ./scripts/test-verify-map-replay.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$here/verify-map-replay.sh"
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

tmp=$(mktemp -d -t verify-map-replay)
trap 'rm -rf "$tmp"' EXIT

# A fixture repo of its own — @<rev> resolves against the map's own directory,
# and a merge commit needs a real merge to prove the first-parent diff is what
# gets read, not what any repo happens to hold right now.
repo="$tmp/repo"
mkdir -p "$repo/.kiteloop"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@t.com
git -C "$repo" config user.name t

cat > "$repo/.kiteloop/verify-map.json" <<'JSON'
{"rules": [{"glob": "*.txt", "command": "run-tests"}]}
JSON
MAP="$repo/.kiteloop/verify-map.json"

echo a > "$repo/a.txt"; git -C "$repo" add a.txt; git -C "$repo" commit -q -m init
git -C "$repo" checkout -q -b topic
echo b > "$repo/b.txt"; git -C "$repo" add b.txt; git -C "$repo" commit -q -m "add b"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff topic -m "merge topic"
MERGE_SHA=$(git -C "$repo" rev-parse HEAD)

echo c > "$repo/c.txt"; git -C "$repo" add c.txt; git -C "$repo" commit -q -m "add c"
NONMERGE_SHA=$(git -C "$repo" rev-parse HEAD)

git -C "$repo" commit -q --allow-empty -m "touches nothing"
EMPTY_REV_SHA=$(git -C "$repo" rev-parse HEAD)

run() { "$SCRIPT" "$MAP" "$@" 2>&1; }

# --- a merge commit reaches a real verdict ---

out=$(run "@$MERGE_SHA" "run-tests"); status=$?
check "merge commit, command declared — exit 0" 0 "$status"
check_contains "merge commit lists what the merge brought in, covered" 'covered  *.txt — ran `run-tests`' "$out"
check_contains "and prints COVERED" "COVERED" "$out"

out=$(run "@$MERGE_SHA" "true"); status=$?
check "merge commit, command missing — a real gap, exit 1" 1 "$status"
check_contains "the gap names the file the merge brought in" "b.txt" "$out"
check_not_contains "never COVERED on a real gap" "COVERED" "$out"

# --- every way to reach an empty changed-file list is refused, not covered ---

: > "$tmp/empty.txt"
out=$(run "$tmp/empty.txt" "run-tests"); status=$?
check "an empty file — exit 2" 2 "$status"
check_contains "says nothing was compared (empty file)" "nothing was compared" "$out"
check_not_contains "never COVERED on an empty file" "COVERED" "$out"

printf ' \n\n' > "$tmp/blank.txt"
out=$(run "$tmp/blank.txt" "run-tests"); status=$?
check "a file of only blank lines — exit 2" 2 "$status"
check_not_contains "never COVERED on blank lines" "COVERED" "$out"

out=$(printf '' | run - "run-tests"); status=$?
check "empty stdin — exit 2" 2 "$status"
check_contains "says nothing was compared (stdin)" "nothing was compared" "$out"
check_not_contains "never COVERED on empty stdin" "COVERED" "$out"

out=$(run "@$EMPTY_REV_SHA" "run-tests"); status=$?
check "a rev that touches nothing — exit 2" 2 "$status"
check_contains "says nothing was compared (empty commit)" "nothing was compared" "$out"
check_not_contains "never COVERED on a commit that changed nothing" "COVERED" "$out"

# --- a non-merge rev, a file of paths, and stdin all behave as before ---

out=$(run "@$NONMERGE_SHA" "run-tests"); status=$?
check "non-merge rev, covered — exit 0 (unchanged)" 0 "$status"
check_contains "COVERED for an ordinary commit" "COVERED" "$out"

out=$(run "@$NONMERGE_SHA" "true"); status=$?
check "non-merge rev, gap — exit 1 (unchanged)" 1 "$status"
check_contains "the gap summary is unchanged" 'diff touches *.txt (1 file: c.txt) but verify never runs `run-tests`' "$out"

printf 'd.txt\n' > "$tmp/paths.txt"
out=$(run "$tmp/paths.txt" "run-tests"); status=$?
check "a file of paths, covered — exit 0 (unchanged)" 0 "$status"

out=$(run "$tmp/paths.txt" "true"); status=$?
check "a file of paths, gap — exit 1 (unchanged)" 1 "$status"
check_contains "gap summary for a plain file (unchanged)" 'diff touches *.txt (1 file: d.txt) but verify never runs `run-tests`' "$out"

out=$(printf 'e.txt\n' | run - "run-tests"); status=$?
check "stdin, covered — exit 0 (unchanged)" 0 "$status"

out=$(printf 'e.txt\n' | run - "true"); status=$?
check "stdin, gap — exit 1 (unchanged)" 1 "$status"
check_contains "gap summary for stdin (unchanged)" 'diff touches *.txt (1 file: e.txt) but verify never runs `run-tests`' "$out"

# --- the header and the usage block both say what an empty diff does ---

occurrences=$(grep -c "empty changed-file list" "$SCRIPT")
check "the header comment and the usage block both name the empty-diff case" 2 "$occurrences"

usage_out=$("$SCRIPT" 2>&1); usage_status=$?
check "too few args still exits 2" 2 "$usage_status"
check_contains "the printed usage block states the empty-diff exit code" "2 = usage" "$usage_out"
check_contains "and that nothing was compared" "nothing was compared" "$usage_out"

echo
if [ "$failed" -ne 0 ]; then echo "test-verify-map-replay: $failed case(s) failed."; exit 1; fi
echo "test-verify-map-replay: all cases passed."
