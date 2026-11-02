#!/usr/bin/env python3
"""check-doc-links — fail a relative Markdown link that resolves to nothing.

Two documents in the published repository linked at files that are not in it.
`docs/suite-status.md` linked `suite-triage-2026-08-08.md` and
`docs/autonomy.md` linked `memory-audit-2026-08.md`; both were among the
records the 2026-08-17 pre-publish audit removed — `docs/repo-map.md` says so
— and both 404'd for anyone reading the repository on GitHub. Nothing caught
it. The doc-citations gate resolves paths, but only the ones cited in
`docs/features.md`, and `check-repo-map.py` reads backticked spans by
basename, which a link's target is not.

So this reads the tracked Markdown of the checkout — `git ls-files '*.md'`,
which leaves out `dist/`, `.build/` and everything else `.gitignore` prunes,
by construction rather than by a hand-kept list — and for every `[text](target)`
whose target is relative resolves it against the linking file's own directory,
failing when it names nothing on disk. A `#fragment` is cut off first: whether
a heading anchor exists is a different question from whether the document
does, and this one answers only the second. A target that is a bare `#anchor`,
or carries a scheme (`http:`, `https:`, `mailto:`), is never resolved against
the filesystem at all — an external link would need a network call, which has
no place in a preflight.

Code is masked before any link is read: a fenced block, and an inline code
span, become runs of spaces of the same length, so the offsets of what remains
still index the original text. That is what makes an exemption list
unnecessary. `docs/backlog-format.md` and `Kiteloop/GETTING_STARTED.md` both
illustrate the shape of a detail link — `[detail](backlog/<id>.md)` — with no
such file anywhere, and every one of those illustrations sits inside a fence
or a code span. An illustration of a link is not a link.

Usage
  ./scripts/check-doc-links.py            # this checkout
  ./scripts/check-doc-links.py --quiet    # only print on failure
  ./scripts/check-doc-links.py --repo PATH        # another checkout
"""

import argparse
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# A fence opens and closes on its own line; the closing run is the same
# character as the opening one, which is why the opener is remembered rather
# than matched against either spelling.
FENCE_RE = re.compile(r"\s*(```+|~~~+)")

# An inline code span: a run of backticks closed by a run of the same length.
# No DOTALL — a span does not cross a line here, so an unclosed backtick
# swallows nothing past its own line.
CODE_SPAN_RE = re.compile(r"(`+)(?:(?!\1).)*?\1")

# An inline link. The target stops at the first whitespace, which drops a
# `"title"` without having to parse one, and at a parenthesis, which is what
# ends it.
LINK_RE = re.compile(r"\[(?P<text>[^\]\n]*)\]\(\s*(?P<target>[^()\s]*)")

SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


class DocLinkError(RuntimeError):
    """Git could not answer what Markdown files the repository has."""


def tracked_markdown(repo):
    """Repo-relative paths of every tracked `.md` file, sorted."""
    cmd = ["git", "ls-files", "--", "*.md"]
    try:
        proc = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise DocLinkError(f"{repo} could not be read through git: {exc}") from exc
    if proc.returncode != 0:
        raise DocLinkError(f"{repo} could not be read through git: {proc.stderr.strip()}")
    return sorted(line.strip() for line in proc.stdout.splitlines() if line.strip())


def fence_state(line, fence):
    """The fence still open after `line`, and whether `line` is code.

    A fence line is itself code — it is blanked along with the block it
    delimits, so a closing fence never leaves a stray backtick run behind for
    the inline-span pass to pair off against.
    """
    opener = FENCE_RE.match(line)
    if fence is not None:
        closed = opener is not None and line.strip().startswith(fence)
        return (None if closed else fence), True
    return (opener.group(1) if opener else None), opener is not None


def mask_fenced_blocks(text):
    """`text` with every fenced block, and its fence lines, blanked to spaces.

    Length and line structure are preserved, so an offset into the result is
    the same offset into the original.
    """
    out = list(text)
    fence = None
    at = 0
    for line in text.split("\n"):
        fence, is_code = fence_state(line, fence)
        if is_code:
            out[at : at + len(line)] = " " * len(line)
        at += len(line) + 1
    return "".join(out)


def mask_code_spans(text):
    """`text` with every inline code span blanked to spaces, length kept."""
    return CODE_SPAN_RE.sub(lambda m: " " * len(m.group(0)), text)


def masked(text):
    """`text` with all code — fenced and inline — blanked to spaces."""
    return mask_code_spans(mask_fenced_blocks(text))


def is_filesystem_target(target):
    """Whether a link target names a path in the repository rather than an
    anchor on the page, an external URL, or nothing at all."""
    if not target or target.startswith("#") or target.startswith("//"):
        return False
    return not SCHEME_RE.match(target)


def resolve(repo, source, target):
    """The absolute path `target`, written in `source`, names.

    A leading `/` is read as repo-root-relative, never as the machine's
    filesystem root: this check judges a repository, and a link out of one is
    not something it can be asked about.
    """
    path = target.split("#", 1)[0]
    if path.startswith("/"):
        return os.path.normpath(os.path.join(repo, path.lstrip("/")))
    return os.path.normpath(os.path.join(repo, os.path.dirname(source), path))


def links_in(text):
    """Every `(line, text, target)` inline link outside code, in order."""
    found = []
    for match in LINK_RE.finditer(masked(text)):
        target = match.group("target").strip()
        if target.startswith("<") and target.endswith(">"):
            target = target[1:-1]
        label = text[match.start("text") : match.end("text")].strip()
        found.append((text.count("\n", 0, match.start()) + 1, label, target))
    return found


def dangling_in(repo, source, text):
    """The `(source, line, text, target)` links in one file that resolve to
    nothing, and how many links in it were resolved at all."""
    judged = 0
    bad = []
    for line, label, target in links_in(text):
        if not is_filesystem_target(target):
            continue
        judged += 1
        path = target.split("#", 1)[0]
        if path and not os.path.exists(resolve(repo, source, target)):
            bad.append((source, line, label, target))
    return bad, judged


def dangling_links(repo):
    """Every dangling link across the tracked Markdown, and the number of
    relative links judged."""
    judged = 0
    bad = []
    for source in tracked_markdown(repo):
        with open(os.path.join(repo, source), errors="replace") as handle:
            text = handle.read()
        found, count = dangling_in(repo, source, text)
        bad += found
        judged += count
    return bad, judged


def report(bad):
    """Print the FAIL block naming every dangling link."""
    print(f"FAIL: {len(bad)} relative link(s) resolve to nothing.\n", file=sys.stderr)
    for source, line, label, target in bad:
        print(f"  {source}:{line}  [{label}]({target})", file=sys.stderr)
    print(
        "\nThe file was renamed or removed and the link was not — repoint it, "
        "or say the thing in the sentence instead of linking a document that is gone.",
        file=sys.stderr,
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quiet", action="store_true", help="only print on failure")
    ap.add_argument(
        "--repo",
        default=REPO,
        metavar="PATH",
        help="repo root whose tracked Markdown is read (default: this repo's)",
    )
    args = ap.parse_args()

    repo = os.path.abspath(args.repo)
    try:
        bad, judged = dangling_links(repo)
    except DocLinkError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    if bad:
        report(bad)
        return 1
    if not args.quiet:
        print(f"OK: all {judged} relative Markdown link(s) resolve to a file that exists")
    return 0


if __name__ == "__main__":
    sys.exit(main())
