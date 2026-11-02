#!/usr/bin/env python3
"""check-features-map — Kiteloop's spelling of the two cleat gates that replaced it.

Not part of cleat's template: attach.py --refresh replaces the template's files
and keeps this one. The features-map check was retired upstream into
doc-citations (every path docs/features.md cites resolves under its roots) and
reachability (every Services/* file is constructed by something); this name
stays because the verify map's rule for a docs/features.md change and older
verify: lines call it. It runs both gates through gate.py and exits with the
runner's status. --quiet is accepted: output is shown only on failure, the way
the retired check behaved.
"""
import os
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
quiet = "--quiet" in args
args = [a for a in args if a != "--quiet"]
proc = subprocess.run(
    [sys.executable, os.path.join(here, "gate.py"), "--gate", "doc-citations", "--gate", "reachability", *args],
    capture_output=quiet,
)
if quiet and proc.returncode != 0:
    sys.stdout.write(proc.stdout.decode())
    sys.stderr.write(proc.stderr.decode())
sys.exit(proc.returncode)
