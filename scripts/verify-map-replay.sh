#!/bin/zsh
# verify-map-replay — run a repo's .kiteloop/verify-map.json against a real diff.
#
# A verify map that matches nothing is indistinguishable from no map: both let
# every run through, and both read as coverage afterwards. The only way to tell
# them apart is to make each rule fail on purpose before trusting it — and then
# to check it stays quiet on the diffs that are genuinely covered.
#
# This replays the shipped rules (Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/VerifyCoverage.swift,
# which is pure and Foundation-only, so it compiles standalone) against a real
# changed-file list and the commands an item declared. Replaying a repo's already
# *merged* items is the part worth the effort: each of those was verified to
# somebody's satisfaction, so a rule that blocks one is claiming coverage the repo
# does not agree with. Writing the two maps that exist today, that replay rejected
# a rule per repo — one for a command that never reads the file it claimed to
# cover, one for a tree with no single canonical command.
#
#   ./scripts/verify-map-replay.sh <map.json> <diff> <command> [<command>…]
#
#     <diff>     a file of repo-relative paths, one per line
#                @<rev>  the files a commit touched, read from the map's own repo,
#                        first-parent — a merge commit lists what the merge
#                        brought in, not every file its second parent ever touched
#                -       read the paths from stdin
#     <command>  a verify command as an item declares it, repeated per command
#
# Exit 0 = covered, 1 = a gap (the block message autopilot would report),
# 2 = usage, or an empty changed-file list — nothing was compared, so nothing
# gets to print COVERED for it.
#
#   ./scripts/verify-map-replay.sh ~/code/api/.kiteloop/verify-map.json \
#       @da045ae0 'npm --prefix apps/web test'

set -u

if [[ $# -lt 3 ]]; then
  print -u2 -- "usage: ${0:t} <map.json> <diff> <command> [<command>…]

  <diff>     a file of repo-relative paths, one per line
             @<rev>  the files a commit touched, read from the map's own repo,
                     first-parent
             -       read the paths from stdin
  <command>  a verify command as an item declares it, repeated per command

exit 0 = covered, 1 = a gap, 2 = usage or an empty changed-file list —
nothing was compared, so nothing prints COVERED for it."
  exit 2
fi

MAP=$1; DIFF=$2; shift 2

[[ -f $MAP ]] || { print -u2 "no map at $MAP"; exit 2 }

SCRIPT_DIR=${0:A:h}
SOURCE=$SCRIPT_DIR/../Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/VerifyCoverage.swift
[[ -f $SOURCE ]] || { print -u2 "cannot find VerifyCoverage.swift at $SOURCE"; exit 2 }

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT

# The paths, from wherever they were asked for. `@<rev>` resolves against the
# repository the map belongs to, not this one — the map being replayed usually
# describes some other checkout.
case $DIFF in
  @*) git -C "${MAP:A:h}" show --name-only --format="" -m --first-parent "${DIFF#@}" > "$WORK/files.txt" \
        || { print -u2 "cannot read ${DIFF#@} in ${MAP:A:h}"; exit 2 } ;;
  -)  cat > "$WORK/files.txt" ;;
  *)  [[ -f $DIFF ]] || { print -u2 "no such file: $DIFF"; exit 2 }
      cp "$DIFF" "$WORK/files.txt" ;;
esac
print -l -- "$@" > "$WORK/commands.txt"

# A file of blank lines is as empty as a zero-byte one to `lines()` below,
# which trims and drops them the same way.
grep -q '[^[:space:]]' "$WORK/files.txt" \
  || { print -u2 "no changed files — nothing was compared"; exit 2 }

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

func lines(_ path: String) -> [String] {
    (try? String(contentsOfFile: path, encoding: .utf8))?
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty } ?? []
}

let args = CommandLine.arguments
let (map, problem) = VerifyCoverage.Map.loadReporting(from: URL(fileURLWithPath: args[1]))
if let problem { print(problem) }
if map.isEmpty { print("no rules — nothing is checked"); exit(0) }

let verdict = VerifyCoverage.evaluate(
    changedFiles: lines(args[2]), ranCommands: lines(args[3]), map: map)
for rule in verdict.covered { print("covered  \(rule.glob) — ran `\(rule.command)`") }
if verdict.isCovered { print("COVERED"); exit(0) }
print("GAP: \(verdict.summary)")
exit(1)
SWIFT

# -package-name: the source lives in the KiteloopCore package and its
# declarations are `package`, which only compiles under the package's name.
swiftc -O -package-name kiteloopcore "$SOURCE" "$WORK/main.swift" -o "$WORK/replay" || exit 2
"$WORK/replay" "$MAP" "$WORK/files.txt" "$WORK/commands.txt"
