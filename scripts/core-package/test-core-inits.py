#!/usr/bin/env python3
"""test-core-inits — assert scripts/core-package/core-inits.py over a throwaway tree.

A nested `package struct`'s closing brace keeps its own indentation once an
init is spliced in ahead of it; a top-level one still closes at column 0; a
type that already declares an init is left untouched, so a second run over
the same fixture changes nothing; importing the module does nothing — no
argv parsing, no file rewrite — since its argparse call and its rewrite loop
live in `main()`, behind the `__main__` guard; and its `--package` default
resolves to `KiteloopCore/Sources/KiteloopCore`.

  ./scripts/core-package/test-core-inits.py
"""
import importlib.util, os, shutil, subprocess, sys, tempfile
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "core-inits.py")
ROOT = os.path.dirname(os.path.dirname(HERE))
failed = 0


def check(name, ok, detail=""):
    global failed
    print("  %s  %s" % ("ok  " if ok else "FAIL", name) + ("" if ok else "\n          " + detail))
    failed += 0 if ok else 1


def write(p, text):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as h: h.write(text)


def run(pkg):
    p = subprocess.run([sys.executable, SCRIPT, "--package", pkg], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


FIXTURE = """package struct Outer {
    package let a: Int

    package struct Inner {
        package let b: Int
    }
}
"""

tmp = tempfile.mkdtemp(prefix="core-inits-")
try:
    pkg = os.path.join(tmp, "pkg")
    fixture_path = os.path.join(pkg, "Nested.swift")
    write(fixture_path, FIXTURE)

    code, out = run(pkg)
    check("exits 0", code == 0, out)
    result = open(fixture_path).read()

    check("braces stay balanced", result.count("{") == result.count("}"), result)
    check("Outer got a memberwise init", "package init(a: Int)" in result, result)
    check("Inner got a memberwise init", "package init(b: Int)" in result, result)

    lines = result.rstrip("\n").split("\n")
    bare_closes = [i for i, l in enumerate(lines) if l == "}"]
    check("only the top-level struct's closing brace sits at column 0", bare_closes == [len(lines) - 1], result)
    check("the nested struct's closing brace keeps its own indent", any(l == "    }" for l in lines), result)

    code2, out2 = run(pkg)
    result2 = open(fixture_path).read()
    check("a second run over a fixture whose types already have inits changes nothing", result2 == result, out2)
    check("nothing is reported when there is nothing left to do", "init " not in out2, out2)

finally:
    shutil.rmtree(tmp, ignore_errors=True)

status_before = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout
real_pkg = os.path.join(ROOT, "Kiteloop", "KiteloopCore", "Sources", "KiteloopCore")
files_before = set(
    os.path.relpath(os.path.join(dp, f), real_pkg)
    for dp, _, fs in os.walk(real_pkg) for f in fs
)

spec = importlib.util.spec_from_file_location("core_inits", SCRIPT)
core_inits = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core_inits)

status_after = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True).stdout
files_after = set(
    os.path.relpath(os.path.join(dp, f), real_pkg)
    for dp, _, fs in os.walk(real_pkg) for f in fs
)
check("importing the module leaves git status unchanged", status_after == status_before, status_after)
check("importing the module writes no file under KiteloopCore/Sources/KiteloopCore", files_after == files_before, str(files_after - files_before))
check("the --package default resolves to Kiteloop/KiteloopCore/Sources/KiteloopCore",
      os.path.normpath(core_inits.DEFAULT_PKG) == os.path.normpath(real_pkg),
      core_inits.DEFAULT_PKG)

print()
if failed:
    print("test-core-inits: %d case(s) failed." % failed)
    sys.exit(1)
print("test-core-inits: all cases passed.")
