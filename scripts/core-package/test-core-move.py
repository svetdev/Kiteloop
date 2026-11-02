#!/usr/bin/env python3
"""test-core-move — assert scripts/core-package/core-move.py's file-selection
pass and its no-paths refusal, without moving anything.

`files_needing_import` given an empty set of type names returns no files,
even over a fixture tree whose files are ordinary Swift text — the empty
alternation the old top-level code built matched every word boundary and
rewrote every app and test file, and this is the regression it guards
against. Given one type name it returns only the fixture files that name it
outside a comment, and not one that already imports the package. Invoking
core-move.py with no paths at all exits non-zero, prints why, and leaves the
checkout's `git status` unchanged. Importing the module — how this test
reaches its functions — performs no move and writes no project file, because
the script body sits behind `if __name__ == "__main__"`.

  ./scripts/core-package/test-core-move.py
"""
import contextlib, importlib.util, io, json, os, shutil, stat, subprocess, sys, tempfile
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "core-move.py")
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
failed = 0


def check(name, ok, detail=""):
    global failed
    print("  %s  %s" % ("ok  " if ok else "FAIL", name) + ("" if ok else "\n          " + detail))
    failed += 0 if ok else 1


def write(p, text):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as h: h.write(text)


def git_status():
    return subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout


before_import = git_status()
spec = importlib.util.spec_from_file_location("core_move", SCRIPT)
cm = importlib.util.module_from_spec(spec); spec.loader.exec_module(cm)

check("importing the module performs no move and leaves the checkout's git status unchanged",
      git_status() == before_import, git_status())

tmp = tempfile.mkdtemp(prefix="core-move-")
try:
    write(os.path.join(tmp, "Services", "A.swift"), "struct A {\n    let word: Int\n}\n")
    write(os.path.join(tmp, "Models", "B.swift"), "struct B {\n    let other: String\n}\n")

    empty_result = cm.files_needing_import(set(), [tmp])
    check("an empty set of type names selects no files, even over a tree of ordinary words",
          empty_result == [], empty_result)

    named = os.path.join(tmp, "Services", "UsesFoo.swift")
    write(named, "import Foundation\nstruct UsesFoo {\n    let f: Foo\n}\n")
    commented = os.path.join(tmp, "Services", "CommentOnly.swift")
    write(commented, "// references Foo only in a comment\nstruct CommentOnly {}\n")
    already = os.path.join(tmp, "Services", "AlreadyImports.swift")
    write(already, "import KiteloopCore\nstruct AlreadyImports {\n    let f: Foo\n}\n")

    result = cm.files_needing_import({"Foo"}, [tmp])
    check("returns the fixture file that names the type outside a comment", named in result, result)
    check("does not return the file naming it only in a comment", commented not in result, result)
    check("does not return a file that already imports the package", already not in result, result)
    check("returns exactly the one qualifying file", len(result) == 1, result)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

def make_layering_cfg():
    app_root = os.path.relpath(cm.APP, cm.ROOT)
    return {
        "project": "Fixture",
        "layering": {
            "roots": [
                {
                    "root": app_root,
                    "exempt": [
                        {"file": "Services/Foo.swift", "name": "Bar", "reason": "r1"},
                        {"file": "Services/Foo.swift", "name": "Kept", "reason": "r2"},
                        {"file": "Services/Moved.swift", "name": "Other", "reason": "r3"},
                    ],
                },
                {
                    "root": "Kiteloop/KiteloopCore/Sources/KiteloopCore",
                    "exempt": [
                        {"file": "Services/Foo.swift", "name": "Bar", "reason": "r4"},
                        {"file": "Services/Moved.swift", "name": "Other", "reason": "r5"},
                        {"file": "Services/Elsewhere.swift", "name": "Kept", "reason": "r6"},
                    ],
                },
            ]
        },
        "other_key": {"untouched": True},
    }


cfg, dropped = cm.prune_layering_exemptions(make_layering_cfg(), ["Services/Moved"])
app_exempt = cfg["layering"]["roots"][0]["exempt"]
pkg_exempt = cfg["layering"]["roots"][1]["exempt"]
check("leaves an exemption naming a moved type in place, in every root",
      {"file": "Services/Foo.swift", "name": "Bar", "reason": "r1"} in app_exempt
      and {"file": "Services/Foo.swift", "name": "Bar", "reason": "r4"} in pkg_exempt,
      (app_exempt, pkg_exempt))
check("drops an entry whose file moved out of the app root, but leaves the same spelling under the other root",
      all(e["file"] != "Services/Moved.swift" for e in app_exempt)
      and any(e["file"] == "Services/Moved.swift" for e in pkg_exempt),
      (app_exempt, pkg_exempt))
check("reports the number of entries actually dropped", dropped == 1, dropped)

cfg2 = make_layering_cfg()
_, dropped2 = cm.prune_layering_exemptions(cfg2, [])
check("prunes nothing and reports zero when nothing moved", dropped2 == 0, dropped2)

cfg_unnamed = make_layering_cfg()
_, dropped_unnamed = cm.prune_layering_exemptions(cfg_unnamed, ["Services/NotThere"])
check("a moved file no exemption names still drops nothing", dropped_unnamed == 0, dropped_unnamed)

no_layering = {"project": "Fixture", "other_key": {"untouched": True}}
result_cfg, dropped3 = cm.prune_layering_exemptions(no_layering, ["Services/Moved"])
check("a config with no layering section prunes nothing and raises nothing",
      dropped3 == 0 and result_cfg == no_layering, (dropped3, result_cfg))

survivor_cfg = make_layering_cfg()
before_other_key = dict(survivor_cfg["other_key"])
cm.prune_layering_exemptions(survivor_cfg, ["Services/Moved"])
check("every other key of the parsed config survives the rewrite unchanged",
      survivor_cfg["other_key"] == before_other_key and survivor_cfg["project"] == "Fixture",
      survivor_cfg)

before_run = git_status()
p = subprocess.run([sys.executable, SCRIPT], capture_output=True, text=True)
check("invoked with no paths exits non-zero", p.returncode != 0, p.stdout + p.stderr)
check("prints why", "no paths given" in (p.stdout + p.stderr), p.stdout + p.stderr)
check("leaves the checkout's git status unchanged", git_status() == before_run, git_status())


def write_stub_swiftlint(bindir, body):
    stub = os.path.join(bindir, "swiftlint")
    write(stub, "#!/bin/sh\n" + body + "\n")
    os.chmod(stub, os.stat(stub).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return stub


def path_without_swiftlint():
    """The current PATH with whatever directory `swiftlint` actually resolves
    from (if any) removed, so a test can put a controlled stub first without
    a real swiftlint elsewhere on PATH answering instead."""
    found = shutil.which("swiftlint")
    entries = os.environ.get("PATH", "").split(os.pathsep)
    if not found: return entries
    excluded = os.path.abspath(os.path.dirname(found))
    return [d for d in entries if os.path.abspath(d) != excluded]


# failure 1: no swiftlint on PATH at all — refuses before the first git mv,
# names swiftlint, and (like the no-paths case above) mutates nothing
before_no_swiftlint = git_status()
env = dict(os.environ, PATH=os.pathsep.join(path_without_swiftlint()))
p = subprocess.run([sys.executable, SCRIPT, "Nonexistent/DoesNotExist"], capture_output=True, text=True, env=env)
check("with no swiftlint on PATH, invoking with a real spec still exits non-zero", p.returncode != 0, p.stdout + p.stderr)
check("names swiftlint as the reason", "swiftlint" in (p.stdout + p.stderr).lower(), p.stdout + p.stderr)
check("leaves the checkout's git status unchanged", git_status() == before_no_swiftlint, git_status())

# failure 2: swiftlint is on PATH but the rewrite it runs exits non-zero —
# the extracted function reports failure and prints swiftlint's stderr,
# rather than the misleading "entries (must be equal)" line
tmp = tempfile.mkdtemp(prefix="core-move-baseline-")
try:
    bindir = os.path.join(tmp, "bin")
    os.makedirs(bindir)
    write_stub_swiftlint(bindir, 'echo "stub swiftlint: complexity threshold exceeded" 1>&2\nexit 1')
    baseline = os.path.join(tmp, ".swiftlint-baseline.json")
    write(baseline, json.dumps([{"file": "a", "text": "func f()"}]))
    before_baseline = open(baseline).read()

    old_path = os.environ.get("PATH", "")
    os.environ["PATH"] = bindir + os.pathsep + old_path
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            ok = cm.rewrite_complexity_baseline(baseline, tmp)
    finally:
        os.environ["PATH"] = old_path

    check("a non-zero swiftlint exit is reported as a failed rewrite", ok is False, ok)
    check("prints the stub's stderr", "complexity threshold exceeded" in err.getvalue(), err.getvalue())
    check("does not print the misleading 'entries (must be equal)' line", "must be equal" not in out.getvalue(), out.getvalue())
    check("leaves the baseline file untouched", open(baseline).read() == before_baseline, open(baseline).read())

    # a rewrite that does run still prints the before/after counts
    write_stub_swiftlint(bindir, "exit 0")
    out2 = io.StringIO()
    os.environ["PATH"] = bindir + os.pathsep + old_path
    try:
        with contextlib.redirect_stdout(out2):
            ok2 = cm.rewrite_complexity_baseline(baseline, tmp)
    finally:
        os.environ["PATH"] = old_path
    check("a rewrite that runs successfully reports success", ok2 is True, ok2)
    check("prints the before and after entry counts", "1 -> 1 entries (must be equal)" in out2.getvalue(), out2.getvalue())
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print()
if failed:
    print("test-core-move: %d case(s) failed." % failed)
    sys.exit(1)
print("test-core-move: all cases passed.")
