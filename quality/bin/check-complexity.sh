#!/bin/bash
# check-complexity.sh — Kiteloop's spelling of cleat's complexity gate.
#
# Not part of cleat's template: attach.py --refresh replaces the template's
# files and keeps this one. It exists because this name is wired into the
# tree — the verify map's rule for every **/*.swift change (SignalDrafting),
# the chat tool's default clean command, the backlog's verify_default and the
# verify: line of every ready item — and a gate that vanished from under
# those would refuse every run for a reason that has nothing to do with the
# code. It runs quality/bin/check-complexity.py, the gate itself, with the
# flags it is handed (--quiet is the one the callers use), and exits with the
# gate's own status.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/check-complexity.py" "$@"
