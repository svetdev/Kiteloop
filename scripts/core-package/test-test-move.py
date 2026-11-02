#!/usr/bin/env python3
"""test-test-move — assert scripts/core-package/test-move.py's destination
mapping and its mkdir-before-git-mv fix, without moving anything real.

`destination()` is the one place that answers where a KiteloopTests-relative
path lands under the package's Tests/KiteloopCoreTests and how its
docs/features.md citation should read: a path with a folder keeps that first
folder and is cited by the same `<folder>/<name>` spelling it has today; a
path with none — the four files that sit at the root of
Kiteloop/KiteloopTests — lands directly in the package tests root and is
cited by its bare basename, never by a directory named after a .swift file.
`move()` creates that destination's directory before handing `git mv` a
destination it cannot create for itself — checked here by faking
`subprocess.run` so no real git command runs, and recording, at the moment
the fake sees the `git mv` argv, whether the destination directory already
exists on disk. `duplicate_classes()` and `print_duplicates()` (the
`--duplicates` mode) are checked over a fixture pair of trees built here, not
over this checkout, so the assertion holds regardless of what this checkout's
own test files currently duplicate. Importing the module performs no move and
leaves the checkout's `git status` unchanged, because the script's body sits
behind `if __name__ == "__main__"`.

  ./scripts/core-package/test-test-move.py
"""
import contextlib, importlib.util, io, os, shutil, subprocess, sys, tempfile
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "test-move.py")
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
spec = importlib.util.spec_from_file_location("test_move", SCRIPT)
tm = importlib.util.module_from_spec(spec); spec.loader.exec_module(tm)

check("importing the module performs no move and leaves the checkout's git status unchanged",
      git_status() == before_import, git_status())

# --- destination(): the acceptance criteria, verbatim ---

dst, cite = tm.destination("Services/LedgerDurableRewriteTests.swift")
check("a folder path lands under the package tests tree's same-named folder",
      dst == os.path.join(tm.PKG, "Tests", "KiteloopCoreTests", "Services", "LedgerDurableRewriteTests.swift"), dst)
check("a folder path is cited by the same `Services/…` spelling it has today",
      cite == "Services/LedgerDurableRewriteTests.swift", cite)

dst, cite = tm.destination("AgentCatalogStoreTests.swift")
check("a root-level path lands at the package tests root, not a folder named after itself",
      dst == os.path.join(tm.PKG, "Tests", "KiteloopCoreTests", "AgentCatalogStoreTests.swift"), dst)
check("no path component of a root-level destination ends in .swift except the leaf",
      all(not part.endswith(".swift") for part in dst.split(os.sep)[:-1]), dst)
check("a root-level path is cited by its bare basename",
      cite == "AgentCatalogStoreTests.swift", cite)

# --- move(): mkdir before git mv, over a sandbox so nothing real moves ---

class FakeSubprocess:
    """Stands in for the subprocess module inside move(): records the `git
    mv` argv, notes whether its destination directory already existed at
    that moment, then performs the rename itself so move() keeps working."""
    def __init__(self):
        self.dst_dir_existed = []

    def run(self, cmd, check=True, cwd=None):
        if cmd[:2] == ["git", "mv"]:
            src, dst = cmd[2], cmd[3]
            self.dst_dir_existed.append(os.path.isdir(os.path.dirname(dst)))
            os.rename(src, dst)
        return subprocess.CompletedProcess(cmd, 0)


tmp = tempfile.mkdtemp(prefix="test-test-move-")
try:
    tests_dir = os.path.join(tmp, "KiteloopTests")
    pkg_dir = os.path.join(tmp, "KiteloopCore")
    pbx_path = os.path.join(tmp, "project.pbxproj")
    features_path = os.path.join(tmp, "features.md")

    write(os.path.join(tests_dir, "Backlog", "FooTests.swift"),
          "import XCTest\n@testable import Kiteloop\nfinal class FooTests: XCTestCase {\n    func testX() {}\n}\n")
    write(os.path.join(tests_dir, "RootTests.swift"),
          "import XCTest\n@testable import Kiteloop\nfinal class RootTests: XCTestCase {\n    func testX() {}\n}\n")
    write(pbx_path, "")
    write(features_path, "See `Backlog/FooTests.swift` and `RootTests.swift`.\n")

    real_tests, real_pkg, real_root = tm.TESTS, tm.PKG, tm.ROOT
    real_pbx, real_features = tm.PBX, tm.FEATURES
    fake = FakeSubprocess()
    tm.TESTS, tm.PKG, tm.ROOT = tests_dir, pkg_dir, tmp
    tm.PBX, tm.FEATURES = pbx_path, features_path
    tm.subprocess = fake
    try:
        check("the package tests tree has no Backlog folder yet, in this sandbox",
              not os.path.isdir(os.path.join(pkg_dir, "Tests", "KiteloopCoreTests", "Backlog")), pkg_dir)

        tm.move("Backlog/FooTests.swift")
        moved = os.path.join(pkg_dir, "Tests", "KiteloopCoreTests", "Backlog", "FooTests.swift")
        check("a candidate under a folder the package tests tree lacks resolves to that folder",
              os.path.isfile(moved), moved)
        check("that folder existed on disk at the moment git mv was invoked",
              fake.dst_dir_existed[0], fake.dst_dir_existed)
        check("the citation for a folder path keeps its `Backlog/…` spelling",
              "`Backlog/FooTests.swift`" in open(features_path).read(), open(features_path).read())

        tm.move("RootTests.swift")
        moved_root = os.path.join(pkg_dir, "Tests", "KiteloopCoreTests", "RootTests.swift")
        check("a root-level candidate lands directly in the package tests root",
              os.path.isfile(moved_root), moved_root)
        check("the citation for a root-level path is rewritten to its bare basename",
              "`RootTests.swift`" in open(features_path).read(), open(features_path).read())

        write(os.path.join(tests_dir, "Services", "TestableOnlyTests.swift"),
              "import XCTest\n@testable import Kiteloop\nfinal class TestableOnlyTests: XCTestCase {\n    func testX() {}\n}\n")
        tm.move("Services/TestableOnlyTests.swift")
        moved_testable_only = os.path.join(pkg_dir, "Tests", "KiteloopCoreTests", "Services", "TestableOnlyTests.swift")
        moved_text = open(moved_testable_only).read()
        check("a file carrying only `@testable import Kiteloop` ends with exactly one import of the package",
              moved_text.count("import KiteloopCore") == 1, moved_text)
        check("that one import is the `@testable` line, not a plain one",
              "@testable import KiteloopCore" in moved_text and "\nimport KiteloopCore" not in moved_text, moved_text)

        write(os.path.join(tests_dir, "Services", "TestableAndPlainTests.swift"),
              "import XCTest\n@testable import Kiteloop\nimport KiteloopCore\nfinal class TestableAndPlainTests: XCTestCase {\n    func testX() {}\n}\n")
        tm.move("Services/TestableAndPlainTests.swift")
        moved_both = os.path.join(pkg_dir, "Tests", "KiteloopCoreTests", "Services", "TestableAndPlainTests.swift")
        moved_both_text = open(moved_both).read()
        check("a file already carrying a plain `import KiteloopCore` beside `@testable import Kiteloop` ends with one import line, not two",
              moved_both_text.count("import KiteloopCore") == 1, moved_both_text)
    finally:
        tm.TESTS, tm.PKG, tm.ROOT = real_tests, real_pkg, real_root
        tm.PBX, tm.FEATURES = real_pbx, real_features
        tm.subprocess = subprocess
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# --- duplicate_classes(): a class split across both trees, over a fixture ---

tmp = tempfile.mkdtemp(prefix="test-test-move-dup-")
try:
    tests_dir = os.path.join(tmp, "KiteloopTests")
    pkg_dir = os.path.join(tmp, "KiteloopCore")

    write(os.path.join(tests_dir, "Services", "SplitTests.swift"), """\
import XCTest
@testable import Kiteloop
final class SplitTests: XCTestCase {
    func testAppOnly() {}
    func testShared() {}
}
""")
    write(os.path.join(pkg_dir, "Tests", "KiteloopCoreTests", "Services", "SplitTests.swift"), """\
import XCTest
@testable import KiteloopCore
final class SplitTests: XCTestCase {
    func testShared() {}
    func testPackageOnly() {}
}
""")
    write(os.path.join(tests_dir, "Services", "SoloTests.swift"), """\
import XCTest
@testable import Kiteloop
final class SoloTests: XCTestCase {
    func testOnlyHere() {}
}
""")

    real_tests, real_pkg = tm.TESTS, tm.PKG
    tm.TESTS, tm.PKG = tests_dir, pkg_dir
    try:
        dups = tm.duplicate_classes()
        check("a class present in only one tree is not reported",
              all(name != "SoloTests" for name, _, _ in dups), dups)
        check("a class declared in both trees is reported exactly once",
              [name for name, _, _ in dups] == ["SplitTests"], dups)

        _, (app_file, app_names), (pkg_file, pkg_names) = dups[0]
        check("the app side's file is relative to KiteloopTests",
              app_file == os.path.join("Services", "SplitTests.swift"), app_file)
        check("the package side's file is relative to KiteloopCoreTests",
              pkg_file == os.path.join("Services", "SplitTests.swift"), pkg_file)
        check("the app side lists exactly the func test names it declares",
              app_names == ["testAppOnly", "testShared"], app_names)
        check("the package side lists exactly the func test names it declares",
              pkg_names == ["testPackageOnly", "testShared"], pkg_names)
        check("the case both sides declare is visible in both lists at once",
              "testShared" in app_names and "testShared" in pkg_names, (app_names, pkg_names))

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            tm.print_duplicates()
        report = out.getvalue()
        check("the report names the shared class",
              "SplitTests" in report, report)
        overlap_line = next((l for l in report.splitlines() if "! same case name" in l), "")
        check("the report flags exactly the case name declared on both sides",
              overlap_line.endswith("testShared"), overlap_line)
    finally:
        tm.TESTS, tm.PKG = real_tests, real_pkg
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# --- with no arguments, still just the candidate list ---

before_run = git_status()
p = subprocess.run([sys.executable, SCRIPT], capture_output=True, text=True, cwd=ROOT)
check("with no arguments, exits zero", p.returncode == 0, p.stdout + p.stderr)
check("with no arguments, still prints the candidate list", p.stdout.startswith("#") and "app-hosted test files" in p.stdout, p.stdout)
check("with no arguments, leaves the checkout's git status unchanged", git_status() == before_run, git_status())

print()
if failed:
    print("test-test-move: %d case(s) failed." % failed)
    sys.exit(1)
print("test-test-move: all cases passed.")
