#!/usr/bin/env bash
#
# The hardener's stage of Kiteloop's QA flow: mutation testing over the core
# package files this tree changed, and nothing else — an `--all` pass takes hours.
# Any surviving mutant fails it, and the worker gets the survivors to write a
# test for or name as equivalent. App-target files are not mutated: mutate.py
# runs over the host-less package only.
#
#   ./scripts/qa/harden-changed.sh            # against main
#   QA_BASE=<ref> ./scripts/qa/harden-changed.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
sources=Kiteloop/KiteloopCore/Sources/KiteloopCore
base=$(git merge-base HEAD "${QA_BASE:-main}")
# A pathspec's `*` crosses directories, so this is every Swift file under the sources.
changed=$(git diff --name-only --diff-filter=AM "$base" -- "$sources/*.swift")
if [ -z "$changed" ]; then
  echo "harden: no core package source changed since $(git rev-parse --short "$base") — nothing to mutate"
  exit 0
fi
status=0
for file in $changed; do
  echo "harden: $file"
  ./quality/bin/mutate.py "${file#"$sources"/}" || status=1
done
exit "$status"
