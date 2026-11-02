#!/usr/bin/env python3
"""check-control-api-docs — fail if docs/control-api.md drifts from ControlRouter.table.

`docs/control-api.md` is a second, hand-maintained list of every endpoint the
control API answers, alongside the one the server actually matches against —
`ControlRouter.table` in
`Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Control/ControlRouter.swift`.
Nothing before this check compared the two: two retired endpoints,
`POST /v1/coordinator/action` and `PUT /v1/coordinator/policy`, stayed
documented in the endpoint index for a day after the routes themselves were
gone, and nothing said so.

Four ways the two can disagree, each read straight off the offending method
and path:

  - an index row (`| METHOD | \\`path\\` | ... |`) naming a request the table
    has no route for — documented, not answered;
  - a route in the table with no index row for it — answered, not documented;
  - the same (method, path) as two index rows — a duplicate;
  - a `### METHOD /path` section heading with no index row to match it.

A `:id` capture segment in the table and its doc spelling, `{runId}`, are the
same path — both collapse to one placeholder segment before comparing, so
they are never read as a disagreement. A `?query` suffix on a documented path
(`/v1/backlog?project=`) is stripped the same way, since the router matches
on path alone.

This reads two files and starts no build, spawns no xcodebuild and consults
no process list, so it is safe to run — on its own or as part of the suite —
while Kiteloop is running.

Usage
  ./scripts/check-control-api-docs.py            # check this repo's own files
  ./scripts/check-control-api-docs.py --quiet     # only print on failure
  ./scripts/check-control-api-docs.py --router PATH --doc PATH   # read others
"""

import argparse
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROUTER = os.path.join(
    REPO, "Kiteloop", "KiteloopCore", "Sources", "KiteloopCore",
    "Services", "Control", "ControlRouter.swift",
)
DOC = os.path.join(REPO, "docs", "control-api.md")

ROW_RE = re.compile(r'Row\("([A-Z]+)",\s*"([^"]+)"\)')
INDEX_ROW_RE = re.compile(r'^\|\s*([A-Z]+)\s*\|\s*`([^`]+)`\s*\|')
SECTION_RE = re.compile(r'^### ([A-Z]+) (\S+)\s*$')


def normalize_path(path):
    """Segment-wise placeholder form: `:id` and `{runId}` both become `*`, and
    a `?query` suffix is dropped, so the router's and the doc's spellings of
    the same request compare equal."""
    path = path.split("?", 1)[0]
    segments = []
    for segment in path.split("/"):
        if not segment:
            continue
        if segment.startswith(":") or (segment.startswith("{") and segment.endswith("}")):
            segments.append("*")
        else:
            segments.append(segment)
    return "/" + "/".join(segments)


def read_routes(swift_text):
    """[(method, normalized_path, raw_path), ...] from `ControlRouter.table`."""
    return [(method, normalize_path(path), path) for method, path in ROW_RE.findall(swift_text)]


def read_index_rows(doc_text):
    """[(method, normalized_path, raw_path, line_no), ...] from the endpoint index table."""
    rows = []
    for line_no, line in enumerate(doc_text.splitlines(), start=1):
        match = INDEX_ROW_RE.match(line)
        if match:
            method, path = match.group(1), match.group(2)
            rows.append((method, normalize_path(path), path, line_no))
    return rows


def read_sections(doc_text):
    """[(method, normalized_path, raw_path, line_no), ...] from `### METHOD /path` headings."""
    sections = []
    for line_no, line in enumerate(doc_text.splitlines(), start=1):
        match = SECTION_RE.match(line)
        if match:
            method, path = match.group(1), match.group(2)
            sections.append((method, normalize_path(path), path, line_no))
    return sections


def find_duplicates(index_rows):
    """[(method, normalized_path, raw_path, line_no), ...] — index rows repeating
    an earlier row's (method, path)."""
    seen = set()
    duplicates = []
    for method, path, raw, line_no in index_rows:
        key = (method, path)
        if key in seen:
            duplicates.append((method, path, raw, line_no))
        else:
            seen.add(key)
    return duplicates


def compare(routes, index_rows, sections):
    """(undocumented, unanswered, duplicates, orphan_sections) — the four ways
    the table and the doc can disagree."""
    route_keys = {(method, path) for method, path, _ in routes}
    index_keys = {(method, path) for method, path, _, _ in index_rows}

    undocumented = sorted(set(route_keys - index_keys))

    unanswered = [
        (method, path, raw, line_no)
        for method, path, raw, line_no in index_rows
        if (method, path) not in route_keys
    ]

    duplicates = find_duplicates(index_rows)

    orphan_sections = [
        (method, path, raw, line_no)
        for method, path, raw, line_no in sections
        if (method, path) not in index_keys
    ]

    return undocumented, unanswered, duplicates, orphan_sections


def report_block(rows, header, line_for):
    """Print `header` and one `line_for(row)` line per row, if there are any."""
    if not rows:
        return
    print(header, file=sys.stderr)
    for row in rows:
        print(line_for(row), file=sys.stderr)
    print("", file=sys.stderr)


def report(undocumented, unanswered, duplicates, orphan_sections):
    report_block(
        undocumented,
        f"FAIL: {len(undocumented)} route(s) the API answers have no row in the "
        "endpoint index:",
        lambda row: f"    {row[0]} {row[1]}",
    )
    report_block(
        unanswered,
        f"FAIL: {len(unanswered)} endpoint index row(s) name a request the router "
        "has no route for:",
        lambda row: f"    docs/control-api.md:{row[3]}: {row[0]} {row[2]}",
    )
    report_block(
        duplicates,
        f"FAIL: {len(duplicates)} endpoint index row(s) are duplicates:",
        lambda row: f"    docs/control-api.md:{row[3]}: {row[0]} {row[2]}",
    )
    report_block(
        orphan_sections,
        f"FAIL: {len(orphan_sections)} section heading(s) match no endpoint index row:",
        lambda row: f"    docs/control-api.md:{row[3]}: ### {row[0]} {row[2]}",
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quiet", action="store_true", help="only print on failure")
    ap.add_argument(
        "--router", default=None, metavar="PATH",
        help="ControlRouter.swift to read (default: this repo's)",
    )
    ap.add_argument(
        "--doc", default=None, metavar="PATH",
        help="docs/control-api.md to read (default: this repo's)",
    )
    args = ap.parse_args()

    with open(args.router or ROUTER) as handle:
        routes = read_routes(handle.read())
    with open(args.doc or DOC) as handle:
        doc_text = handle.read()

    index_rows = read_index_rows(doc_text)
    sections = read_sections(doc_text)

    undocumented, unanswered, duplicates, orphan_sections = compare(routes, index_rows, sections)

    if not (undocumented or unanswered or duplicates or orphan_sections):
        if not args.quiet:
            print(
                f"OK: all {len(routes)} routes in ControlRouter.table are documented, "
                f"{len(index_rows)} endpoint index rows all name a real route, and "
                f"{len(sections)} section headings all match one"
            )
        return 0

    report(undocumented, unanswered, duplicates, orphan_sections)
    return 1


if __name__ == "__main__":
    sys.exit(main())
