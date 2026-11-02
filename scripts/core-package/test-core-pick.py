#!/usr/bin/env python3
"""test-core-pick — assert scripts/core-package/core-pick.py over a throwaway tree.

Importing the module walks neither tree and prints nothing, because its scan
and its three output modes sit behind `main()`, itself behind the
`__main__` guard; a fixture app/package pair then pins the candidate rule —
a file whose every reference is already in the package is a candidate, one
referencing an app file that has not moved is not, a file importing SwiftUI
is never a candidate no matter its dependencies, and the fan-in column
counts the app files naming it — and `--why` and `--blockers` are driven
over the same fixture, reached (like the candidate scan) through `--app` and
`--package` rather than the checkout.

  ./scripts/core-package/test-core-pick.py
"""
import contextlib, importlib.util, io, os, shutil, subprocess, sys, tempfile
from unittest import mock

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "core-pick.py")
ROOT = os.path.dirname(os.path.dirname(HERE))
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


def run(app, pkg, *args):
    p = subprocess.run([sys.executable, SCRIPT, "--app", app, "--package", pkg, *args], capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


# --- importing the module scans nothing and prints nothing ---

status_before = git_status()
walk_calls = []
real_walk = os.walk
captured = io.StringIO()
with mock.patch("os.walk", lambda *a, **k: walk_calls.append(a) or real_walk(*a, **k)), \
        contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
    spec = importlib.util.spec_from_file_location("core_pick", SCRIPT)
    core_pick = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(core_pick)

check("importing the module walks neither the app nor the package tree", walk_calls == [], walk_calls)
check("importing the module prints nothing", captured.getvalue() == "", repr(captured.getvalue()))
check("importing the module leaves git status unchanged", git_status() == status_before, git_status())
check("the module exposes main() for the __main__ guard", hasattr(core_pick, "main"), "")
check("the --app default resolves to Kiteloop/Kiteloop",
      os.path.normpath(core_pick.APP) == os.path.normpath(os.path.join(ROOT, "Kiteloop", "Kiteloop")), core_pick.APP)
check("the --package default resolves to KiteloopCore/Sources/KiteloopCore",
      os.path.normpath(core_pick.PKG) == os.path.normpath(os.path.join(ROOT, "Kiteloop", "KiteloopCore", "Sources", "KiteloopCore")),
      core_pick.PKG)

# --- the candidate rule, over a fixture app/package pair ---

tmp = tempfile.mkdtemp(prefix="core-pick-")
try:
    app = os.path.join(tmp, "app"); pkg = os.path.join(tmp, "pkg")
    write(os.path.join(pkg, "Widget.swift"), "package struct Widget {}\n")
    write(os.path.join(app, "Services", "Ready.swift"), "final class Ready {\n    let w = Widget()\n}\n")
    write(os.path.join(app, "Services", "Other.swift"), "final class Other {}\n")
    write(os.path.join(app, "Services", "NotReady.swift"), "final class NotReady {\n    let o = Other()\n}\n")
    write(os.path.join(app, "Views", "SomeView.swift"), "import SwiftUI\nstruct SomeView {\n    let w = Widget()\n}\n")
    write(os.path.join(app, "Services", "UsesReadyA.swift"), "final class UsesReadyA {\n    let r = Ready()\n}\n")
    write(os.path.join(app, "Services", "UsesReadyB.swift"), "final class UsesReadyB {\n    let r = Ready()\n}\n")

    code, out, err = run(app, pkg)
    check("exits 0", code == 0, out + err)
    check("a file whose every reference is already in the package is a candidate", "Services/Ready.swift" in out, out)
    check("a file referencing an app file that has not moved is not a candidate", "Services/NotReady.swift" not in out, out)
    check("a file importing SwiftUI is never a candidate, even with every reference in the package",
          "Views/SomeView.swift" not in out, out)
    ready_line = next((line for line in out.splitlines() if line.endswith("Services/Ready.swift")), "")
    check("the fan-in column counts the app files naming it: Ready is named by 2",
          ready_line.split()[0] == "2", out)
    check("the stderr summary reports the candidate count and the package size",
          err.strip() == "# 2 candidates now; 1 files in the package", err)

    code, out, err = run(app, pkg, "--why", "Services/NotReady")
    check("--why exits 0", code == 0, out + err)
    check("--why reports the app dependency holding the file out",
          out.strip() == "Services/NotReady: 1 app dependencies: Services/Other.swift", out)

    code, out, err = run(app, pkg, "--blockers", "5")
    check("--blockers exits 0", code == 0, out + err)
    lines = out.splitlines()
    check("--blockers ranks Ready.swift, named outside the package by two files, ahead of Other.swift, named by one",
          lines and lines[0].split()[-1] == "Services/Ready.swift" and lines[0].split()[0] == "2", out)
    check("--blockers never lists a file only a SwiftUI-importing file depends on through no other path",
          "SomeView" not in out, out)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print()
if failed:
    print("test-core-pick: %d case(s) failed." % failed)
    sys.exit(1)
print("test-core-pick: all cases passed.")
