#!/usr/bin/env python3
"""test-core-check — assert scripts/core-package/core-check.py over a throwaway tree.

A package test naming a type only the app declares fails and is named with
its line; one naming only package types passes; a name in a comment or a
string is not a use; a top-level app function is caught as well as a type;
a reference inside a multiline (triple-quoted) string's interpolation is
caught too — a case the old regex stripper could not express, since it
discarded a triple-quoted block wholesale before ever looking inside it;
--quiet prints nothing on success; and this checkout passes. Starts no build.
Also asserts test-move.py's candidate list shares core-check.py's app_only_names:
a file naming a fixture declared anywhere in the app-hosted test tree (not just
Support) is withheld, a file whose own top-level declaration shadows an
app-only name is still offered, and a file the list offers passes core-check.py
once placed in the package's test tree.

  ./scripts/core-package/test-core-check.py
"""
import importlib.util, os, shutil, subprocess, sys, tempfile
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__)); SCRIPT = os.path.join(HERE, "core-check.py")
failed = 0
def check(name, ok, detail=""):
    global failed
    print("  %s  %s" % ("ok  " if ok else "FAIL", name) + ("" if ok else "\n          " + detail)); failed += 0 if ok else 1
def write(p, text):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as h: h.write(text)
def read(p):
    with open(p, errors="replace") as h: return h.read()
def run(app, pkg, *args):
    p = subprocess.run([sys.executable, SCRIPT, "--app", app, "--package", pkg, "--tests", os.path.join(app, "..", "KiteloopTests"), *args], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr
tmp = tempfile.mkdtemp(prefix="core-check-")
try:
    app = os.path.join(tmp, "app"); pkg = os.path.join(tmp, "pkg")
    write(os.path.join(app, "Services", "Orchestrator.swift"), "final class Orchestrator {}\nfunc kiteloopOnly() {}\n")
    write(os.path.join(pkg, "Sources", "Core", "Thing.swift"), "package struct Thing {}\n")
    write(os.path.join(pkg, "Tests", "CoreTests", "ThingTests.swift"), "import XCTest\n@testable import Core\nfinal class ThingTests: XCTestCase {\n    // Orchestrator in a comment\n    func testA() { let s = \"Orchestrator\"; _ = Thing(); _ = s }\n}\n")
    code, out = run(app, pkg)
    check("a package test naming only package types passes", code == 0, out)
    check("names in comments and strings are not uses", "Orchestrator" not in out, out)
    code, out = run(app, pkg, "--quiet")
    check("--quiet prints nothing on success", out == "", repr(out))
    write(os.path.join(pkg, "Tests", "CoreTests", "CrossTests.swift"), "import XCTest\n@testable import Core\nfinal class CrossTests: XCTestCase {\n    func testB() {\n        _ = Orchestrator()\n        kiteloopOnly()\n    }\n}\n")
    code, out = run(app, pkg)
    check("a test naming an app-only type fails", code == 1, out)
    check("and is named with the identifier and line", "CrossTests.swift: Orchestrator (line 5), kiteloopOnly (line 6)" in out, out)
    check("the clean file is not reported", "ThingTests" not in out, out)
    check("the remedy is stated", "Move the test back" in out, out)
    # a helper the app-hosted test target declares is app-side too: the package's tests
    # do not see KiteloopTests/Support, and the compiler says so an hour later
    write(os.path.join(app, "..", "KiteloopTests", "Support", "RepositoryRoot.swift"), "enum RepositoryRoot { static func of() -> String { \"/\" } }\n")
    write(os.path.join(pkg, "Tests", "CoreTests", "HelperTests.swift"), "import XCTest\n@testable import Core\nfinal class HelperTests: XCTestCase {\n    func testC() { _ = RepositoryRoot.of() }\n}\n")
    code, out = run(app, pkg)
    check("a test using a helper only the app-hosted test target declares fails", "HelperTests.swift: RepositoryRoot (line 4)" in out, out)
    write(os.path.join(pkg, "Tests", "CoreTests", "Support", "RepositoryRoot.swift"), "enum RepositoryRoot { static func of() -> String { \"/\" } }\n")
    code, out = run(app, pkg)
    check("the same helper declared in the package's tests too is not app-only", "HelperTests" not in out, out)
    # a helper the test file declares itself, as a method, shadows the app's free function of that name
    write(os.path.join(pkg, "Tests", "CoreTests", "OwnHelperTests.swift"), "import XCTest\n@testable import Core\nfinal class OwnHelperTests: XCTestCase {\n    private func kiteloopOnly() {}\n    func testD() { kiteloopOnly() }\n}\n")
    code, out = run(app, pkg)
    check("a name the file declares itself is not an offender", "OwnHelperTests" not in out, out)
    # an app type named only inside a string interpolation is a reference all the same
    write(os.path.join(pkg, "Tests", "CoreTests", "InterpolationTests.swift"), "import XCTest\n@testable import Core\nfinal class InterpolationTests: XCTestCase {\n    func testE() { _ = \"seen \\(Orchestrator.self) here\" }\n}\n")
    code, out = run(app, pkg)
    check("a type named only inside \"\\(…)\" is an offender", "InterpolationTests.swift: Orchestrator (line 4)" in out, out)
    # a regex stripper that discards a triple-quoted block wholesale (as core-check's did,
    # to keep a multiline string's own \n count right) cannot see an interpolation inside
    # one; a stripper that parses the grammar sees the reference regardless of the quoting
    write(os.path.join(pkg, "Tests", "CoreTests", "MultilineInterpolationTests.swift"),
          "import XCTest\n@testable import Core\nfinal class MultilineInterpolationTests: XCTestCase {\n    func testF() {\n        let s = \"\"\"\n        seen \\(Orchestrator.self) here\n        \"\"\"\n        _ = s\n    }\n}\n")
    code, out = run(app, pkg)
    check("a type named only inside a multiline string's \"\\(…)\" is an offender",
          "MultilineInterpolationTests.swift: Orchestrator (line 6)" in out, out)
    p = subprocess.run([sys.executable, SCRIPT], capture_output=True, text=True)
    check("this checkout passes", p.returncode == 0, p.stdout + p.stderr)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# test-move.py's candidate list must judge by the same app_only_names core-check.py's
# offenders uses — a candidate it offers is a file core-check.py will accept once moved.
mv_spec = importlib.util.spec_from_file_location("test_move_module", os.path.join(HERE, "test-move.py"))
mv = importlib.util.module_from_spec(mv_spec); mv_spec.loader.exec_module(mv)
tmp2 = tempfile.mkdtemp(prefix="test-move-")
try:
    mv.APP = os.path.join(tmp2, "app")
    mv.TESTS = os.path.join(tmp2, "KiteloopTests")
    mv.PKG = os.path.join(tmp2, "pkg")
    write(os.path.join(mv.APP, "Services", "Widget.swift"), "final class Widget {}\n")
    # a fixture declared at file scope in a non-Support app-hosted test file is app-side too
    write(os.path.join(mv.TESTS, "Services", "WidgetFixtures.swift"), "final class WidgetFixture {}\n")
    write(os.path.join(mv.TESTS, "Services", "UsesFixtureTests.swift"),
          "import XCTest\nfinal class UsesFixtureTests: XCTestCase {\n    func testA() { _ = WidgetFixture() }\n}\n")
    cands = dict(mv.candidates())
    check("a test naming a fixture from a non-Support app-hosted test file is not a candidate",
          "Services/UsesFixtureTests.swift" not in cands, str(cands))
    # a test whose own top-level declaration shares a name with an app declaration still resolves locally
    write(os.path.join(mv.TESTS, "Services", "ShadowsAppTests.swift"),
          "import XCTest\nfinal class ShadowsAppTests: XCTestCase {\n    private class Widget {}\n    func testB() { _ = Widget() }\n}\n")
    cands = dict(mv.candidates())
    check("a test whose own declaration shadows an app-only name is still a candidate",
          "Services/ShadowsAppTests.swift" in cands, str(cands))
    write(os.path.join(mv.PKG, "Tests", "PkgTests", "ShadowsAppTests.swift"),
          read(os.path.join(mv.TESTS, "Services", "ShadowsAppTests.swift")))
    code, out = run(mv.APP, mv.PKG)
    check("a file the candidate list offers passes core-check.py once placed in the package's test tree",
          code == 0, out)
finally:
    shutil.rmtree(tmp2, ignore_errors=True)
print()
if failed: print("test-core-check: %d case(s) failed." % failed); sys.exit(1)
print("test-core-check: all cases passed.")
