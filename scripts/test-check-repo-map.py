#!/usr/bin/env python3
"""test-check-repo-map — assert the readers in check-repo-map.py.

`.gitignore` says a file "would have to earn a row in docs/repo-map.md to be
tracked" and nothing checked that until check-repo-map.py — the map had
already drifted twice, most recently naming eight of the twelve files under
scripts/core-package/ and leaving four silently unlisted. So the readers are
driven directly, the way test-check-target-membership.py drives its own:
`named_basenames` over synthetic markdown, one fixture per shape a row takes —
a full path in one span, a bare basename in the next, a span that is not a
path at all — and `missing_files` and `scanned_files` over a throwaway tree
built for this file alone, so what is asserted does not depend on the state of
the real scripts/, quality/ or .github/. Then the check itself is run end to end
against that tree through --repo and --repo-map, so a reader that parses
correctly and a check that reports non-zero are both exercised, not just the
first.

It starts no build, reads no process list and writes nothing outside a
temporary directory, so it is safe to run — on its own or as part of the
suite — while Kiteloop is running.

  ./scripts/test-check-repo-map.py
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True  # leave no __pycache__ beside the script

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(HERE, "check-repo-map.py")

failed = 0
fixtures = []


def check(name, ok, detail=""):
    global failed
    if ok:
        print("  ok    %s" % name)
    else:
        print("  FAIL  %s%s" % (name, "\n          " + detail if detail else ""))
        failed += 1


def check_equal(name, expected, actual):
    check(name, expected == actual, "expected %r, got %r" % (expected, actual))


def check_contains(name, needle, haystack):
    check(name, needle in haystack, "%r not in:\n%s" % (needle, haystack))


def load_script():
    """The script as a module — its filename has dashes, so it cannot be imported."""
    spec = importlib.util.spec_from_file_location("check_repo_map", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


module = load_script()


def make_tree():
    """A throwaway git repo: scripts/, quality/, docs/repo-map.md, torn down after.

    scanned_files reads what exists through git, so the tree needs its own
    checkout and its own .gitignore, the same as the real repo's, to prune a
    compiled cache without a hard-coded directory name.
    """
    root = tempfile.mkdtemp(prefix="test-check-repo-map-")
    fixtures.append(root)
    subprocess.run(["git", "init", "-q", root], check=True)
    write(os.path.join(root, ".gitignore"), "__pycache__/\n")
    return root


def write(path, text=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)


def run(repo, repo_map=None, *args):
    argv = [sys.executable, SCRIPT, "--repo", repo]
    if repo_map is not None:
        argv += ["--repo-map", repo_map]
    argv += list(args)
    proc = subprocess.run(argv, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


print("test-check-repo-map")

# --- named_basenames -----------------------------------------------------
#
# The only spelling every row of docs/repo-map.md agrees on is the basename:
# a row spells a file's full path once and its neighbours in the same
# directory bare, and the quality/ table drops the quality/ prefix throughout.

check_equal(
    "a full path in backticks is read by its basename",
    {"core-pick.py"},
    module.named_basenames("`core-package/core-pick.py`"),
)
check_equal(
    "a bare basename in backticks is read as itself",
    {"test-core-pick.py"},
    module.named_basenames("`test-core-pick.py`"),
)
check_equal(
    "several spans on one line are all read",
    {"a.py", "b.py", "c.sh"},
    module.named_basenames("`a.py`, `b.py`, and `dir/c.sh` too"),
)
check_equal(
    "text outside backticks is not a span",
    set(),
    module.named_basenames("mentions core-pick.py with no backticks at all"),
)
check_equal(
    "an unclosed backtick names no span",
    set(),
    module.named_basenames("`core-pick.py stays open"),
)
check_equal(
    "a non-path span is read too, harmlessly, by its own basename",
    {"--dry-run"},
    module.named_basenames("`--dry-run` runs nothing"),
)

# --- is_candidate_span ----------------------------------------------------
#
# Only a span shaped like a filename is judged for staleness at all; a flag,
# a bare extension mentioned in prose, and a version number would all read
# as harmless basenames to named_basenames, but must never reach the
# staleness check that follows.

check("a full file path is a candidate", module.is_candidate_span("core-package/core-pick.py"))
check("a bare basename is a candidate", module.is_candidate_span("core-pick.py"))
check(
    "a directory-shaped span is a candidate",
    module.is_candidate_span("Kiteloop/Kiteloop/Resources/Assets.xcassets"),
)
check("a flag is not a candidate", not module.is_candidate_span("--dry-run"))
check("a bare extension mentioned in prose is not a candidate", not module.is_candidate_span(".swift"))
check("a version number is not a candidate", not module.is_candidate_span("0.3.5"))
check("a type name with no extension is not a candidate", not module.is_candidate_span("BacklogItem"))
check("a span with a space is not a candidate", not module.is_candidate_span("swift test"))

# --- scanned_files and missing_files, over a throwaway tree ---------------
#
# The shapes the item asks for: a file with no row fails and is named, a file
# with a row passes, a file sitting directly under quality/ (not one of its
# subdirectories) is swept too, a file under .github/workflows/ the map names
# nowhere is reported the same way, and a compiled cache pruned by .gitignore
# is not flagged as missing just because nothing names it on purpose.

tree = make_tree()
write(os.path.join(tree, "scripts", "named.py"), "# named\n")
write(os.path.join(tree, "scripts", "orphan.py"), "# orphan\n")
write(os.path.join(tree, "scripts", "core-package", "nested.py"), "# nested\n")
write(os.path.join(tree, "quality", "bin", "gated.py"), "# gated\n")
write(os.path.join(tree, "quality", "tests", "tested.py"), "# tested\n")
write(os.path.join(tree, "quality", "tests", "untested.py"), "# untested\n")
write(os.path.join(tree, "quality", "baseline.json"), "{}\n")
write(os.path.join(tree, "scripts", "__pycache__", "named.cpython-312.pyc"), "junk")
write(os.path.join(tree, ".github", "workflows", "ci.yml"), "# ci\n")
write(os.path.join(tree, ".github", "workflows", "orphan.yml"), "# orphan workflow\n")
write(
    os.path.join(tree, "docs", "repo-map.md"),
    "| `named.py` | why |\n| `core-package/nested.py` | why |\n| `bin/gated.py` | why |\n"
    "| `tests/tested.py` | why |\n| `ci.yml` | why |\n",
)

found = module.scanned_files(tree)
check_equal(
    "scanned_files walks all three roots, reaches quality/ itself, and prunes __pycache__",
    [
        ".github/workflows/ci.yml",
        ".github/workflows/orphan.yml",
        "quality/baseline.json",
        "quality/bin/gated.py",
        "quality/tests/tested.py",
        "quality/tests/untested.py",
        "scripts/core-package/nested.py",
        "scripts/named.py",
        "scripts/orphan.py",
    ],
    found,
)

original_roots = module.SCAN_ROOTS
module.SCAN_ROOTS = ["scripts", "quality", "quality/bin"]
try:
    overlapping = module.scanned_files(tree)
finally:
    module.SCAN_ROOTS = original_roots
check_equal(
    "a file reachable from both a root and its parent root is counted once",
    1,
    overlapping.count("quality/bin/gated.py"),
)

with open(os.path.join(tree, "docs", "repo-map.md")) as handle:
    text = handle.read()
missing = module.missing_files(tree, text)
check_equal(
    "missing_files names the files no row mentions, and none of the others",
    [
        ".github/workflows/orphan.yml",
        "quality/baseline.json",
        "quality/tests/untested.py",
        "scripts/orphan.py",
    ],
    missing,
)

# --- The check itself, end to end -----------------------------------------

code, out, err = run(tree)
check_equal("the check fails while files are unlisted", 1, code)
check_contains("and names the scripts/ offender on stderr", "scripts/orphan.py", err)
check_contains("and names the quality/tests/ offender on stderr", "quality/tests/untested.py", err)
check_contains("and names the file directly under quality/ on stderr", "quality/baseline.json", err)
check_contains(
    "and names the .github/workflows/ offender on stderr",
    ".github/workflows/orphan.yml",
    err,
)
check_equal("nothing named is on stdout", "", out)
for named in (
    "scripts/named.py",
    "scripts/core-package/nested.py",
    "quality/bin/gated.py",
    "quality/tests/tested.py",
    ".github/workflows/ci.yml",
):
    check("the report does not also name a file that does have a row (%s)" % named, named not in err)
check(
    "the __pycache__ file is never named, passing or failing",
    "named.cpython" not in err and "named.cpython" not in out,
)

code, out, err = run(tree, None, "--quiet")
check_equal("--quiet still fails", 1, code)
check_contains("--quiet still names the offenders", "scripts/orphan.py", err)
check_contains("--quiet still names the quality/tests/ offender", "quality/tests/untested.py", err)
check_contains(
    "--quiet still names the .github/workflows/ offender",
    ".github/workflows/orphan.yml",
    err,
)

# --- existing_names and stale_spans, over the same throwaway tree ---------
#
# The other direction: a row naming a file the tree does not have. Its
# candidate spans are judged against the basename of every path component
# the tree carries, not just its files.

names = module.existing_names(tree)
check("existing_names includes a plain tracked file", "named.py" in names)
check("existing_names excludes a name nothing in the tree has", "not-a-real-file.py" not in names)

stale_text = (
    "| `named.py` | why |\n"
    "| `core-package/nested.py` | why |\n"
    "| `deleted-script.py` | why |\n"
    "| `--dry-run` | not a file |\n"
    "| `.swift` | not a file |\n"
    "| `0.3.5` | not a file |\n"
)
check_equal(
    "stale_spans names only the deleted file, not the flag, extension or version",
    ["deleted-script.py"],
    module.stale_spans(tree, stale_text),
)

# A directory itself never appears in git's listing — only the files inside
# it do — so a span naming one that happens to look like a file (an
# extension-shaped suffix, `Assets.xcassets`) must still read as real.

dir_tree = make_tree()
write(os.path.join(dir_tree, "scripts", "plugin.bundle", "inner.py"), "# inner\n")
write(
    os.path.join(dir_tree, "docs", "repo-map.md"),
    "| `inner.py` | why |\n| `plugin.bundle` | why |\n",
)
check(
    "existing_names includes a directory whose name looks like a file",
    "plugin.bundle" in module.existing_names(dir_tree),
)
code, out, err = run(dir_tree)
check_equal("a directory-shaped span that exists is not reported stale", 0, code)

# The check itself, end to end: a copy of the completed map (built below)
# plus one row naming a file that was deleted, and a few non-file spans that
# must never be mistaken for it.

stale_map = os.path.join(tree, "docs", "repo-map-stale.md")
write(
    stale_map,
    "| `named.py` | why |\n| `core-package/nested.py` | why |\n"
    "| `bin/gated.py` | why |\n| `tests/tested.py` | why |\n"
    "| `orphan.py` | why |\n| `tests/untested.py` | why |\n| `baseline.json` | why |\n"
    "| `ci.yml` | why |\n| `orphan.yml` | why |\n"
    "| `deleted-script.py` | why |\n"
    "| `--dry-run` | a flag, not a file |\n"
    "| `.swift` | a bare extension, not a file |\n"
    "| `0.3.5` | a version, not a file |\n",
)
code, out, err = run(tree, stale_map)
check_equal("the check fails when a row names a deleted file", 1, code)
check_contains("and names the deleted script on stderr", "deleted-script.py", err)
check("a flag is never reported as stale", "`--dry-run`" not in err)
check("a bare extension is never reported as stale", "`.swift`" not in err)
check("a version number is never reported as stale", "`0.3.5`" not in err)

# Naming the missing files closes the gap; a fresh copy of the map so the
# fixture above is left untouched for the cases above it.
complete_map = os.path.join(tree, "docs", "repo-map-complete.md")
write(
    complete_map,
    "| `named.py` | why |\n| `core-package/nested.py` | why |\n"
    "| `bin/gated.py` | why |\n| `tests/tested.py` | why |\n"
    "| `orphan.py` | why |\n| `tests/untested.py` | why |\n| `baseline.json` | why |\n"
    "| `ci.yml` | why |\n| `orphan.yml` | why |\n",
)
code, out, err = run(tree, complete_map)
check_equal("the check passes once every file has a row", 0, code)
check_contains(
    "and says what it checked",
    "every file under scripts/, quality/, .github/ is named somewhere",
    out,
)
check_contains(
    "and says how many filename-shaped spans it judged for staleness",
    "%d filename-shaped span" % len(module.candidate_spans(open(complete_map).read())),
    out,
)

code, out, err = run(tree, complete_map, "--quiet")
check_equal("--quiet prints nothing on success", "", out)
check_equal("and fails nothing", 0, code)

# --- Not a git checkout ------------------------------------------------------
#
# scanned_files asks git what exists; a tree git cannot read is a hard
# failure, not silent fallback to scanning everything.

not_a_repo = tempfile.mkdtemp(prefix="test-check-repo-map-not-a-repo-")
fixtures.append(not_a_repo)
write(os.path.join(not_a_repo, "scripts", "stray.py"), "# stray\n")
write(os.path.join(not_a_repo, "docs", "repo-map.md"), "| `stray.py` | why |\n")

raised = False
message = ""
try:
    module.scanned_files(not_a_repo)
except module.RepoMapError as exc:
    raised = True
    message = str(exc)
check("scanned_files raises when the tree is not a git checkout", raised)
check_contains("and the error says the tree could not be read through git", "could not be read through git", message)

code, out, err = run(not_a_repo)
check_equal("the check exits non-zero for a tree that is not a git checkout", 1, code)
check_contains("and says so on stderr, rather than scanning it anyway", "could not be read through git", err)

# --- Against this checkout -------------------------------------------------
#
# The fixtures say what the readers do; this says the check still says OK
# about the real docs/repo-map.md — the state this file's own backlog item
# leaves the repository in once every row is filled in.

code, out, err = run(REPO)
check_equal("the check passes against this repository", 0, code)
check_contains("and names the roots it swept", "scripts/, quality/, .github/", out)
with open(os.path.join(REPO, "docs", "repo-map.md")) as handle:
    real_map_text = handle.read()
check_contains(
    "and names no span as stale against the real repo-map.md",
    "%d filename-shaped span" % len(module.candidate_spans(real_map_text)),
    out,
)

for path in fixtures:
    shutil.rmtree(path, ignore_errors=True)

print("\n%s" % ("FAILED" if failed else "All checks passed."))
sys.exit(1 if failed else 0)
