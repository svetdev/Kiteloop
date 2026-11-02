#!/usr/bin/env python3
"""test-export-coverage-lcov — assert the readers and the writer in export-coverage-lcov.py.

The export is what the changed-coverage postflight reads, so a reader that
dropped executable lines, kept the package's 0% shadow copies from the app
bundle, or let the generated test runner through would make that gate judge
the wrong lines — and it would look like a coverage result, not a bug. The
readers are driven over saved inputs (an xccov archive view, an llvm-cov LCOV
export) written into a throwaway repository, and the script is run end to end
through --xccov-json and --package-lcov, so what is asserted never depends on
a bundle being on the machine. It starts no build, runs no xcrun and reads no
process list, so it is safe while Kiteloop is running.

  ./scripts/test-export-coverage-lcov.py
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "export-coverage-lcov.py")
failed = 0


def check(label, expected, actual):
    global failed
    if expected == actual:
        print("  ok    %s" % label)
    else:
        failed += 1
        print("  FAIL  %s\n          expected: %r\n          actual:   %r" % (label, expected, actual))


def check_contains(label, needle, haystack):
    global failed
    if needle in haystack:
        print("  ok    %s" % label)
    else:
        failed += 1
        print("  FAIL  %s\n          missing: %r\n          in:      %r" % (label, needle, haystack[:400]))


with tempfile.TemporaryDirectory() as tmp:
    root = os.path.realpath(tmp)
    app = os.path.join(root, "App", "App")
    pkg = os.path.join(root, "App", "Core", "Sources", "Core")
    os.makedirs(app)
    os.makedirs(pkg)
    with open(os.path.join(root, "quality.json"), "w") as handle:
        json.dump({"crap": {"xccov": {"sources": "App/App", "bundles": "nowhere/*.xcresult"},
                            "llvm_cov": {"sources": "App/Core/Sources/Core"}}}, handle)

    # xccov's per-line archive view: an app file with executable and
    # non-executable lines, and the package's file the bundle records at 0%.
    archive = {
        os.path.join(app, "Service.swift"): [
            {"line": 1, "isExecutable": False, "executionCount": 0},
            {"line": 2, "isExecutable": True, "executionCount": 3},
            {"line": 3, "isExecutable": True, "executionCount": 0},
        ],
        os.path.join(pkg, "Shadow.swift"): [
            {"line": 1, "isExecutable": True, "executionCount": 0},
        ],
    }
    xccov_json = os.path.join(root, "archive.json")
    with open(xccov_json, "w") as handle:
        json.dump(archive, handle)

    # llvm-cov's LCOV: the package file, and the generated runner it also names.
    package_lcov = os.path.join(root, "package.lcov")
    with open(package_lcov, "w") as handle:
        handle.write("SF:%s\nFN:1,$sName\nFNDA:2,$sName\nDA:1,2\nDA:2,0\nend_of_record\n"
                     "SF:%s\nDA:5,1\nend_of_record\n"
                     % (os.path.join(pkg, "Model.swift"), os.path.join(root, "App", "Core", ".build", "runner.swift")))

    out = os.path.join(root, ".kiteloop", "coverage", "suite.lcov")
    proc = subprocess.run([sys.executable, SCRIPT, "--repo", root, "--out", out,
                           "--xccov-json", xccov_json, "--package-lcov", package_lcov],
                          capture_output=True, text=True)
    check("a run over saved inputs exits 0", 0, proc.returncode)
    check_contains("and says how many files each half carried", "1 app file(s), 1 package file(s)", proc.stdout)
    written = open(out).read() if os.path.isfile(out) else ""
    check("the app file's executable lines are DA records with their counts",
          True, "SF:%s\nDA:2,3\nDA:3,0\nend_of_record" % os.path.join(app, "Service.swift") in written)
    check("a non-executable app line is not a record", False, "DA:1," in written.split("end_of_record")[0])
    check("the package's 0% shadow copy in the app bundle is dropped", False, "Shadow.swift" in written)
    check("the package file's records come through verbatim", True,
          "SF:%s\nFN:1,$sName\nFNDA:2,$sName\nDA:1,2\nDA:2,0\nend_of_record" % os.path.join(pkg, "Model.swift") in written)
    check("the generated test runner is dropped", False, "runner.swift" in written)
    check("the file ends with a newline, one record per block", True, written.endswith("end_of_record\n"))

    # The other shape xccov has been seen to write: a list of {path, lines}.
    with open(xccov_json, "w") as handle:
        json.dump([{"path": os.path.join(app, "Other.swift"), "lines": [{"line": 7, "isExecutable": True, "executionCount": 1}]}], handle)
    proc = subprocess.run([sys.executable, SCRIPT, "--repo", root, "--out", out,
                           "--xccov-json", xccov_json, "--package-lcov", package_lcov],
                          capture_output=True, text=True)
    check("a list-shaped archive view is read too", True, "Other.swift\nDA:7,1" in open(out).read())

    # Missing inputs are refused, naming which.
    proc = subprocess.run([sys.executable, SCRIPT, "--repo", root, "--out", out, "--package-lcov", package_lcov],
                          capture_output=True, text=True)
    check("no bundle and no saved view exits 2", 2, proc.returncode)
    check_contains("and names what to pass", "pass --bundle", proc.stderr)
    proc = subprocess.run([sys.executable, SCRIPT, "--repo", root, "--out", out, "--xccov-json", xccov_json,
                           "--package-build", "App/Core/.build"],
                          capture_output=True, text=True)
    check("no package coverage on disk exits 2", 2, proc.returncode)
    check_contains("and names the command that writes it", "run-core-tests.sh", proc.stderr)

    # A config without the CRAP roots and no explicit roots is refused rather than guessed.
    with open(os.path.join(root, "quality.json"), "w") as handle:
        json.dump({"crap": {}}, handle)
    proc = subprocess.run([sys.executable, SCRIPT, "--repo", root, "--out", out,
                           "--xccov-json", xccov_json, "--package-lcov", package_lcov],
                          capture_output=True, text=True)
    check("no roots anywhere exits 2", 2, proc.returncode)
    check_contains("and names the keys", "crap.xccov.sources", proc.stderr)

if failed:
    print("test-export-coverage-lcov: %d case(s) failed." % failed)
    sys.exit(1)
print("test-export-coverage-lcov: all cases passed.")
