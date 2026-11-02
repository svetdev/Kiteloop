#!/usr/bin/env python3
"""check-repo-map — a two-way check between docs/repo-map.md and the tree.

`.gitignore` states the rule out loud — a file "would have to earn a row in
docs/repo-map.md to be tracked" — and until this existed nothing enforced
either direction of it.

The first direction: a file under scripts/, quality/ or .github/ named
nowhere in docs/repo-map.md. The map drifted twice this way — the scripts/
table's core-package row named eight of the twelve files that had
accumulated under scripts/core-package/, leaving four in the tree and in no
row, silently.

A row does not repeat a file's whole repo-relative path — the scripts/ table
writes `core-package/core-pick.py` once and then bare basenames,
`test-core-pick.py`, `core-move.py`, for its neighbours in the same directory,
and the quality/ table drops the `quality/` prefix the same way, `bin/mutate.py`
rather than `quality/bin/mutate.py`. So the one spelling every row agrees on,
whatever else a row does or does not repeat, is the basename — and that is
what this reads: the basename of every backticked span anywhere in the file,
against the basename of every file this check scans. Judging whether a row's
prose is accurate, or whether a basename that matches by coincidence names the
wrong file, is not this check's job: it asserts a file is named, nothing about
what is said of it.

The second direction: a row naming a file the repository no longer has — the
package migration moved enough files that five docs went stale this way. A
backticked span is only judged here when its shape says it means a file
rather than a flag, a bare extension mentioned in prose, or a version number
(see `is_candidate_span`); a candidate is stale when its basename matches
nothing the whole repository tracks or carries untracked-but-not-ignored,
where "matches" counts a directory too, since git itself only ever lists the
files inside one.

Usage
  ./scripts/check-repo-map.py            # scan scripts/, quality/ and .github/
  ./scripts/check-repo-map.py --quiet    # only print on failure
  ./scripts/check-repo-map.py --repo PATH        # scan another checkout
  ./scripts/check-repo-map.py --repo-map PATH    # read another repo-map.md
"""

import argparse
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Relative to the repo root: the project's own tooling — scripts/ and
# quality/, which covers the checks under quality/bin/, their own tests under
# quality/tests/, and any file quality/ carries directly (a ratchet baseline,
# say) — and .github/, its workflows and contribution templates. docs/ is
# prose, not a listing of files this check judges, and the app trees
# (Kiteloop/, KiteloopMobile/, copilot-bridge-extension/) each carry their own
# map table — widening the sweep to any of those is a separate decision.
SCAN_ROOTS = ["scripts", "quality", ".github"]

SPAN_RE = re.compile(r"`([^`]+)`")

# A candidate span uses only path-safe characters, throughout — this alone
# drops flags (`--dry-run`) and multi-word prose. The rest must end in an
# extension: a letter-led suffix (a version number's trailing `.5` is
# digit-led and so does not count) immediately preceded by an alphanumeric
# (a bare `.swift` mentioned in prose has nothing before its dot and so does
# not count either).
CANDIDATE_CHARS_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
CANDIDATE_EXTENSION_RE = re.compile(r"[A-Za-z0-9]\.[A-Za-z][A-Za-z0-9]*$")


class RepoMapError(RuntimeError):
    """Git could not answer what files exist in the repository."""


def _git_ls_files(repo, pathspec=None):
    """Repo-relative paths git tracks or carries untracked-but-not-ignored,
    scoped to pathspec when one is given.

    `.gitignore` is the single statement of what this project does not track
    on purpose — a compiled cache, an editor leftover — so it is git, not a
    hand-kept list of directory names, that decides what exists.
    """
    cmd = ["git", "ls-files", "--cached", "--others", "--exclude-standard"]
    if pathspec is not None:
        cmd += ["--", pathspec]
    try:
        proc = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise RepoMapError(f"{repo} could not be read through git: {exc}") from exc
    if proc.returncode != 0:
        raise RepoMapError(f"{repo} could not be read through git: {proc.stderr.strip()}")
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def scanned_files(repo):
    """Repo-relative paths (posix-separated) of every file under SCAN_ROOTS
    that git tracks or that is untracked but not ignored, each named once
    even when one root sits inside another.
    """
    found = []
    seen = set()
    for root in SCAN_ROOTS:
        abs_root = os.path.join(repo, root)
        if not os.path.isdir(abs_root):
            continue
        for rel in _git_ls_files(repo, root):
            if rel in seen:
                continue
            seen.add(rel)
            found.append(rel)
    return sorted(found)


def existing_names(repo):
    """The basename of every path component of every file the whole
    repository tracks or carries untracked-but-not-ignored.

    A directory never appears in git's listing on its own — only the files
    inside it do — so this names one from those files' path components,
    which is the only way a span naming a directory (`Assets.xcassets`) can
    ever be judged as naming something real.
    """
    names = set()
    for rel in _git_ls_files(repo):
        for part in rel.split("/"):
            if part:
                names.add(part)
    return names


def is_candidate_span(span):
    """Whether a backticked span is shaped like a filename worth judging for
    staleness, rather than a flag, bare extension, or version number."""
    return bool(CANDIDATE_CHARS_RE.match(span)) and bool(CANDIDATE_EXTENSION_RE.search(span))


def named_basenames(repo_map_text):
    """The basename of every backticked span in docs/repo-map.md.

    Most spans are not file paths at all — a flag such as `--dry-run`, a type
    name — but a basename that happens to collide with a real filename would
    only cause this check to under-report, never to fail a file that is
    genuinely named, so nothing here filters spans by shape.
    """
    return {os.path.basename(span.strip()) for span in SPAN_RE.findall(repo_map_text)}


def missing_files(repo, repo_map_text):
    """Scanned files whose basename is named nowhere in repo_map_text."""
    named = named_basenames(repo_map_text)
    return [path for path in scanned_files(repo) if os.path.basename(path) not in named]


def candidate_spans(repo_map_text):
    """The filename-shaped backticked spans in repo_map_text, each once."""
    seen = []
    for raw in SPAN_RE.findall(repo_map_text):
        span = raw.strip()
        if is_candidate_span(span) and span not in seen:
            seen.append(span)
    return seen


def stale_spans(repo, repo_map_text):
    """Candidate spans whose basename names nothing the repository has."""
    existing = existing_names(repo)
    return sorted(span for span in candidate_spans(repo_map_text) if os.path.basename(span) not in existing)


def report_missing(missing, where, doc):
    """Print the FAIL block for files scanned under `where` but named nowhere
    in `doc`."""
    print(
        f"FAIL: {len(missing)} file(s) under {where} are named nowhere in {doc}.\n",
        file=sys.stderr,
    )
    for path in missing:
        print(f"  {path}", file=sys.stderr)
    print(
        "\nAdd a row, or extend an existing comma-listed one, naming each file — "
        "the basename is enough.",
        file=sys.stderr,
    )


def report_stale(stale, doc):
    """Print the FAIL block for spans in `doc` that name a file the
    repository no longer has."""
    print(
        f"FAIL: {len(stale)} span(s) in {doc} name a file the repository does not have.\n",
        file=sys.stderr,
    )
    for span in stale:
        print(f"  `{span}`", file=sys.stderr)
    print(
        "\nThe file was renamed or deleted and the row was not — update or remove it.",
        file=sys.stderr,
    )


def emit(missing, stale, judged, where, doc, quiet):
    """Print the OK or FAIL block(s) for one judge and return the exit status
    -- split out of main() so each stays a single, small decision."""
    if not missing and not stale:
        if not quiet:
            print(
                f"OK: every file under {where} is named somewhere in {doc}, "
                f"and all {judged} filename-shaped span(s) in {doc} name something that exists"
            )
        return 0

    if missing:
        report_missing(missing, where, doc)

    if stale:
        if missing:
            print(file=sys.stderr)
        report_stale(stale, doc)

    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quiet", action="store_true", help="only print on failure")
    ap.add_argument(
        "--repo",
        default=REPO,
        metavar="PATH",
        help="repo root to scan scripts/, quality/ and .github/ under (default: this repo's)",
    )
    ap.add_argument(
        "--repo-map",
        default=None,
        metavar="PATH",
        help="repo-map.md to read (default: <repo>/docs/repo-map.md)",
    )
    args = ap.parse_args()

    repo = os.path.abspath(args.repo)
    repo_map_path = args.repo_map or os.path.join(repo, "docs", "repo-map.md")

    with open(repo_map_path) as handle:
        repo_map_text = handle.read()

    try:
        missing = missing_files(repo, repo_map_text)
        stale = stale_spans(repo, repo_map_text)
        judged = len(candidate_spans(repo_map_text))
    except RepoMapError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    where = ", ".join(f"{root}/" for root in SCAN_ROOTS)
    doc = os.path.relpath(repo_map_path, repo)

    return emit(missing, stale, judged, where, doc, args.quiet)


if __name__ == "__main__":
    sys.exit(main())
