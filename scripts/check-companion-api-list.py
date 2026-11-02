#!/usr/bin/env python3
"""check-companion-api-list — the phone app's README lists exactly the API it calls.

`KiteloopMobile/README.md` carries a table of every control API endpoint the
companion relies on. A row nobody calls is a promise the app does not need; a
call no row names is a dependency the Mac can break without anyone knowing; a
row naming a path the Mac does not serve is a lie. So: the set of `/v1/…` paths
in `KiteloopMobile/Sources` must equal the set of paths in the table, and every
one of them must be a route in `ControlRouter.table`. Paths are compared without
their query strings — the table spells `?project=` for the reader's sake.

Exit 0 with one line when they agree; exit 1 naming each disagreement.
"""
import re
import subprocess
import sys
from pathlib import Path

QUIET = "--quiet" in sys.argv[1:]


def repo_root():
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(out.stdout.strip() or ".")


def strip_query(path):
    return path.split("?", 1)[0].rstrip("/")


def called_paths(sources):
    paths = set()
    for swift in sources.rglob("*.swift"):
        for match in re.finditer(r'"(/v1/[A-Za-z0-9/_\-]+)', swift.read_text()):
            paths.add(strip_query(match.group(1)))
    return paths


def listed_paths(readme):
    paths = set()
    for line in readme.read_text().splitlines():
        if not line.startswith("| ") or line.startswith("| Method") or line.startswith("|---"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 2:
            continue
        match = re.match(r"`([^`]+)`", cells[1])
        if match:
            paths.add(strip_query(match.group(1)))
    return paths


def served_paths(router):
    text = router.read_text()
    routes = set()
    for match in re.finditer(r'Row\("(?:GET|POST|PUT|DELETE)",\s*"([^"]+)"\)', text):
        routes.add(strip_query(match.group(1)))
    return routes


def is_capture_segment(segment):
    return segment.startswith(":") or (segment.startswith("{") and segment.endswith("}"))


def route_pattern(route):
    """A regex matching any concrete spelling of `route`, or None if it has no capture segment."""
    segments = route.split("/")
    if not any(is_capture_segment(segment) for segment in segments):
        return None
    parts = ["[^/]+" if is_capture_segment(segment) else re.escape(segment) for segment in segments]
    return "^" + "/".join(parts) + "$"


def route_serves(path, routes):
    if path in routes:
        return True
    # a templated route (`/v1/runs/:id/approve`) serves any concrete spelling
    for route in routes:
        pattern = route_pattern(route)
        if pattern and re.match(pattern, path):
            return True
    return False


def disagreements(called, listed, served):
    """One line per way the three sets disagree; empty when they agree."""
    problems = []
    for path in sorted(called - listed):
        problems.append(f"{path} is called from KiteloopMobile/Sources and has no row in KiteloopMobile/README.md")
    for path in sorted(listed - called):
        problems.append(f"{path} has a row in KiteloopMobile/README.md and nothing under KiteloopMobile/Sources calls it")
    for path in sorted(listed | called):
        if not route_serves(path, served):
            problems.append(f"{path} is not a route in ControlRouter.table")
    return problems


def main():
    root = repo_root()
    readme = root / "KiteloopMobile" / "README.md"
    sources = root / "KiteloopMobile" / "Sources"
    router = root / "Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Control/ControlRouter.swift"
    for required in (readme, sources, router):
        if not required.exists():
            print(f"FAIL: {required.relative_to(root)} is missing", file=sys.stderr)
            return 1
    called = called_paths(sources)
    problems = disagreements(called, listed_paths(readme), served_paths(router))
    if problems:
        print("FAIL: the companion's API list and its sources disagree:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    if not QUIET:
        print(f"OK: KiteloopMobile/README.md lists all {len(called)} control API paths the companion calls, every one a route the Mac serves")
    return 0


if __name__ == "__main__":
    sys.exit(main())
