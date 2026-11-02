#!/usr/bin/env python3
"""test-check-doc-links — assert the readers in check-doc-links.py.

Two links in the published repository pointed at documents the pre-publish
audit had removed, and nothing said so — the shape this check exists to end.
What it must not do is as load-bearing as what it must: an external URL
resolved against the filesystem would make the preflight depend on the
network, and an illustration of a link — `[detail](backlog/<id>.md)`, written
inside a code span in `docs/backlog-format.md` — is not a link and must never
be resolved, since treating it as one is what would force an exemption list.

So the readers are driven directly, the way test-check-repo-map.py drives its
own: `masked` and `links_in` over synthetic Markdown, one fixture per shape,
then `is_filesystem_target` over each kind of target. Then the check itself is
run end to end through `--repo` over a throwaway git checkout carrying a good
link, a dangling one, an anchor, an http link, and dangling links inside a
fence and an inline code span, so a reader that parses correctly and a check
that reports non-zero are both exercised. Finally the real check is run against
this checkout, where it must pass.

It starts no build, reads no process list and writes nothing outside a
temporary directory, so it is safe to run — on its own or as part of the
suite — while Kiteloop is running.

The neighbouring suites each carry their own module-level copy of a counting
`check`/`check_equal`/`check_contains` trio; those copies predate the
duplication gate, which fails a block in changed lines that has a twin, so the
same assertions are a small reporter here instead of a fifth copy.

  ./scripts/test-check-doc-links.py
"""

import importlib.util
import os
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True  # leave no __pycache__ beside the script

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(HERE, "check-doc-links.py")


class Report:
    """Counted assertions, printed as they are made."""

    def __init__(self, title):
        print(title)
        self.failures = 0

    def check(self, name, ok, detail=""):
        if ok:
            print("  ok    %s" % name)
            return
        self.failures += 1
        print("  FAIL  %s%s" % (name, "\n          " + detail if detail else ""))

    def equal(self, name, expected, actual):
        self.check(name, expected == actual, "expected %r, got %r" % (expected, actual))

    def contains(self, name, needle, haystack):
        self.check(name, needle in haystack, "%r not in:\n%s" % (needle, haystack))

    def verdict(self):
        print("\n%s" % ("FAILED" if self.failures else "All checks passed."))
        return 1 if self.failures else 0


def load_script():
    """The script as a module — its filename has dashes, so it cannot be imported."""
    spec = importlib.util.spec_from_file_location("check_doc_links", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


module = load_script()
fixtures = []


def make_tree():
    """A throwaway git checkout, cleaned up at the end of the run."""
    holder = tempfile.TemporaryDirectory(prefix="test-check-doc-links-")
    fixtures.append(holder)
    subprocess.run(["git", "init", "-q", holder.name], check=True)
    return holder.name


def track(repo):
    """Stage everything written so far — `git ls-files` is the sweep, so a
    file has to be tracked before the check can see it at all."""
    subprocess.run(["git", "-C", repo, "add", "-A"], check=True)


def write(path, text=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)


def run(repo, *args):
    proc = subprocess.run(
        [sys.executable, SCRIPT, "--repo", repo] + list(args), capture_output=True, text=True
    )
    return proc.returncode, proc.stdout, proc.stderr


report = Report("test-check-doc-links")

# --- masked ---------------------------------------------------------------
#
# Code is blanked rather than deleted: an offset into the masked text has to
# be the same offset into the original, since that is where the link's text is
# read back from.

fenced = "before\n```\n[a](gone.md)\n```\nafter\n"
report.equal("masking keeps the text's length", len(fenced), len(module.masked(fenced)))
report.check("a link inside a fence is masked away", "gone.md" not in module.masked(fenced))
report.contains("and the prose around it is untouched", "before", module.masked(fenced))

tilde = "~~~\n[a](gone.md)\n~~~\n"
report.check("a ~~~ fence masks the same way", "gone.md" not in module.masked(tilde))

spanned = "see `[a](gone.md)` for the shape\n"
report.check("a link inside an inline code span is masked away", "gone.md" not in module.masked(spanned))
report.contains("and the sentence around it is untouched", "for the shape", module.masked(spanned))
report.equal("the span's length is kept too", len(spanned), len(module.masked(spanned)))

report.contains(
    "a link outside code survives masking",
    "[a](real.md)",
    module.masked("a `code` span then [a](real.md)\n"),
)

# --- links_in -------------------------------------------------------------

report.equal(
    "a link is read with its line, text and target",
    [(2, "the docs", "docs/x.md")],
    module.links_in("first line\nsee [the docs](docs/x.md) here\n"),
)
report.equal(
    "a title after the target is not part of it",
    [(1, "x", "x.md")],
    module.links_in('[x](x.md "the title")\n'),
)
report.equal(
    "an angle-bracketed target is unwrapped",
    [(1, "x", "x.md")],
    module.links_in("[x](<x.md>)\n"),
)
report.equal(
    "link text carrying code is read from the original, not the mask",
    [(1, "`run.sh`", "run.sh")],
    module.links_in("[`run.sh`](run.sh)\n"),
)
report.equal("a link inside a fence is not read", [], module.links_in("```\n[a](gone.md)\n```\n"))
report.equal("a link inside a code span is not read", [], module.links_in("`[a](gone.md)`\n"))

# --- is_filesystem_target -------------------------------------------------
#
# What is never resolved against the filesystem at all.

report.check("a relative path is resolved", module.is_filesystem_target("docs/x.md"))
report.check("a path with a fragment is resolved", module.is_filesystem_target("docs/x.md#heading"))
report.check("a bare anchor is not resolved", not module.is_filesystem_target("#heading"))
report.check("an http link is not resolved", not module.is_filesystem_target("http://example.com/x.md"))
report.check("an https link is not resolved", not module.is_filesystem_target("https://example.com/x.md"))
report.check("a mailto link is not resolved", not module.is_filesystem_target("mailto:someone@example.com"))
report.check("a scheme-relative link is not resolved", not module.is_filesystem_target("//example.com/x.md"))
report.check("an empty target is not resolved", not module.is_filesystem_target(""))

# --- resolve --------------------------------------------------------------
#
# A target resolves against the linking file's own directory, and a fragment
# is cut off before the path is looked at: whether a heading anchor exists is
# a different question from whether the document does.

tree = make_tree()
write(os.path.join(tree, "docs", "sibling.md"), "# sibling\n")
write(os.path.join(tree, "top.md"), "# top\n")

report.equal(
    "a target resolves against the linking file's directory",
    os.path.join(tree, "docs", "sibling.md"),
    module.resolve(tree, "docs/index.md", "sibling.md"),
)
report.equal(
    "a ../ target climbs out of it",
    os.path.join(tree, "top.md"),
    module.resolve(tree, "docs/index.md", "../top.md"),
)
report.equal(
    "a fragment is dropped before the path is resolved",
    os.path.join(tree, "docs", "sibling.md"),
    module.resolve(tree, "docs/index.md", "sibling.md#a-heading"),
)
report.equal(
    "a leading slash reads as repo-root-relative, never the filesystem root",
    os.path.join(tree, "top.md"),
    module.resolve(tree, "docs/index.md", "/top.md"),
)

# --- The check itself, end to end ------------------------------------------

write(
    os.path.join(tree, "docs", "index.md"),
    "A good link to [the sibling](sibling.md).\n"
    "A good link with a fragment to [the sibling](sibling.md#a-heading).\n"
    "A dangling link to [the triage note](triage-2026-08-08.md).\n"
    "An anchor on this page: [above](#a-heading).\n"
    "An external one: [example](https://example.com/nothing-here.md).\n"
    "A contact: [us](mailto:someone@example.com).\n"
    "An illustration inside a span: `[detail](backlog/<id>.md)`.\n"
    "```\n"
    "[detail](backlog/an-id.md)\n"
    "```\n",
)
track(tree)

code, out, err = run(tree)
report.equal("the check fails while a link dangles", 1, code)
report.contains("and names the dangling target", "triage-2026-08-08.md", err)
report.contains("and names the file and line it is on", "docs/index.md:3", err)
report.contains("and names the link's text", "[the triage note]", err)
report.equal("nothing is said on stdout when it fails", "", out)
report.check("the resolvable sibling is not named", "sibling.md" not in err)
report.check("the http link is never resolved, so never named", "example.com" not in err)
report.check("the mailto link is never resolved, so never named", "mailto:" not in err)
report.check("the anchor is never resolved, so never named", "#a-heading" not in err)
report.check("the link inside a code span is never named", "backlog/<id>.md" not in err)
report.check("the link inside a fence is never named", "backlog/an-id.md" not in err)

code, out, err = run(tree, "--quiet")
report.equal("--quiet still fails", 1, code)
report.contains("--quiet still names the offender", "triage-2026-08-08.md", err)

# Saying the thing in the sentence rather than linking a document that is gone
# is the fix, and it closes the failure.
write(
    os.path.join(tree, "docs", "index.md"),
    "A good link to [the sibling](sibling.md).\n"
    "A good link with a fragment to [the sibling](sibling.md#a-heading).\n"
    "The triage note was removed at the pre-publish audit.\n"
    "An anchor on this page: [above](#a-heading).\n"
    "An external one: [example](https://example.com/nothing-here.md).\n"
    "An illustration inside a span: `[detail](backlog/<id>.md)`.\n",
)
code, out, err = run(tree)
report.equal("the check passes once the dead link is gone", 0, code)
report.contains("and says how many relative links it resolved", "all 2 relative Markdown link(s)", out)

code, out, err = run(tree, "--quiet")
report.equal("--quiet prints nothing on success", "", out)
report.equal("and fails nothing", 0, code)

# An untracked file is not judged: the sweep is what git lists, which is what
# keeps dist/ and .build/ out without naming either.
write(os.path.join(tree, "docs", "untracked.md"), "[gone](nowhere-at-all.md)\n")
code, out, err = run(tree)
report.equal("an untracked Markdown file is not swept", 0, code)
track(tree)
code, out, err = run(tree)
report.equal("the same file, once tracked, is", 1, code)
report.contains("and its dangling link is named", "nowhere-at-all.md", err)

# --- Not a git checkout -----------------------------------------------------

holder = tempfile.TemporaryDirectory(prefix="test-check-doc-links-not-a-repo-")
fixtures.append(holder)
not_a_repo = holder.name
write(os.path.join(not_a_repo, "docs", "index.md"), "[gone](nowhere.md)\n")

raised = False
message = ""
try:
    module.tracked_markdown(not_a_repo)
except module.DocLinkError as exc:
    raised = True
    message = str(exc)
report.check("tracked_markdown raises when the tree is not a git checkout", raised)
report.contains("and the error says the tree could not be read through git", "could not be read through git", message)

code, out, err = run(not_a_repo)
report.equal("the check exits non-zero for a tree that is not a git checkout", 1, code)
report.contains("and says so on stderr, rather than sweeping it anyway", "could not be read through git", err)

# --- Against this checkout --------------------------------------------------
#
# The fixtures say what the readers do; this says every relative link in the
# repository resolves — the state this file's own backlog item leaves it in.

code, out, err = run(REPO)
report.equal("the check passes against this repository", 0, code)
report.contains("and says what it resolved", "relative Markdown link(s) resolve", out)

for holder in fixtures:
    holder.cleanup()

sys.exit(report.verdict())
