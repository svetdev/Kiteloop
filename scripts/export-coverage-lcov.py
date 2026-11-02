#!/usr/bin/env python3
"""export-coverage-lcov — one LCOV file from the coverage a suite run wrote.

The suite leaves coverage in two shapes the changed-line gate cannot read: the
app's in the run's `.xcresult` bundle, the package's as llvm-cov profile data
under `KiteloopCore/.build` from `swift test --enable-code-coverage`. cleat's
changed-coverage gate reads LCOV or Cobertura, so this writes the one LCOV
file both halves share, after a green row and before the postflight gates.

The app half is `xcrun xccov view --archive --json` over the bundle — the
per-line view, executable lines with their execution counts — kept to files
under the app root, because xccov records the package's files in the app's
bundle at 0% and their real coverage comes from the package half. The package
half is `xcrun llvm-cov export -format=lcov` over the package's test binary
and its `.profdata`, kept to files under the package's source root, which
drops the generated test runner llvm-cov also names. Both roots default to
what the CRAP gate reads (`crap.xccov.sources`, `crap.llvm_cov.sources` in
`quality.json`), so the two gates that read a run's coverage read the same
files.

  scripts/export-coverage-lcov.py --out .kiteloop/coverage/suite.lcov --bundle PATH.xcresult
  scripts/export-coverage-lcov.py --out FILE                # the newest bundle crap.xccov.bundles matches
  scripts/export-coverage-lcov.py --out FILE --xccov-json F --package-lcov F   # saved inputs; the test uses these

Exits 0 having written the file and said how many files each half carried;
2 when an input is missing or a tool refused, naming which.
"""
import argparse
import glob
import json
import os
import subprocess
import sys

XCRUN_TIMEOUT_SECONDS = int(os.environ.get("XCCOV_TIMEOUT_SECONDS", "600"))


class ExportError(Exception):
    """An input could not be read; the message says why."""


def repo_root(explicit):
    if explicit:
        return os.path.realpath(explicit)
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.realpath(os.path.join(here, ".."))


def crap_settings(root):
    """The two source roots and the bundle glob the CRAP gate reads, from quality.json."""
    path = os.path.join(root, "quality.json")
    try:
        with open(path) as handle:
            crap = json.load(handle).get("crap", {})
    except (OSError, ValueError) as error:
        raise ExportError("%s could not be read: %s" % (path, error))
    return (crap.get("xccov", {}).get("sources"), crap.get("llvm_cov", {}).get("sources"),
            crap.get("xccov", {}).get("bundles"))


def newest(pattern):
    matches = sorted(glob.glob(os.path.expanduser(pattern)), key=os.path.getmtime)
    return matches[-1] if matches else None


def run(argv, what):
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=XCRUN_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise ExportError("%s ran past its %ds time limit — ended" % (what, XCRUN_TIMEOUT_SECONDS))
    except OSError as error:
        raise ExportError("%s could not start: %s" % (what, error))
    if proc.returncode != 0 or not proc.stdout.strip():
        raise ExportError("%s failed (exit %d): %s" % (what, proc.returncode, proc.stderr.strip()[:400]))
    return proc.stdout


def under(path, root):
    return os.path.realpath(path).startswith(os.path.join(os.path.realpath(root), ""))


def archive_files(archive):
    """(path, line entries) pairs from either shape xccov's archive view takes: a
    dict keyed by path, or a list of {path, lines}."""
    if isinstance(archive, dict):
        return list(archive.items())
    return [(f.get("path", ""), f.get("lines", [])) for f in archive]


def line_hits(lines):
    """{line: hits} for the executable lines among xccov's per-line entries."""
    hits = {}
    for entry in lines or []:
        if not entry.get("isExecutable", entry.get("executable", False)):
            continue
        number = int(entry["line"])
        count = int(entry.get("executionCount", entry.get("count", 0)) or 0)
        hits[number] = max(hits.get(number, 0), count)
    return hits


def app_records(archive, app_root):
    """{abs path: {line: hits}} from xccov's per-line archive view, files under app_root only."""
    return {os.path.realpath(path): line_hits(lines)
            for path, lines in archive_files(archive) if path and under(path, app_root)}


def package_records(lcov_text, package_root):
    """The LCOV records for files under package_root, verbatim."""
    kept, current, keep = [], [], False
    for raw in lcov_text.splitlines():
        line = raw.strip()
        if line.startswith("SF:"):
            keep = under(line[3:], package_root)
            current = [line] if keep else []
        elif line == "end_of_record":
            if keep:
                kept.append("\n".join(current + [line]))
            current, keep = [], False
        elif keep:
            current.append(line)
    return kept


def lcov_for(app, package_blocks):
    blocks = []
    for path in sorted(app):
        lines = ["SF:%s" % path]
        lines += ["DA:%d,%d" % (number, hits) for number, hits in sorted(app[path].items())]
        lines.append("end_of_record")
        blocks.append("\n".join(lines))
    return "\n".join(blocks + package_blocks) + ("\n" if blocks or package_blocks else "")


def read_app(args, root, app_root, bundles_glob):
    if args.xccov_json:
        with open(args.xccov_json) as handle:
            return app_records(json.load(handle), app_root)
    bundle = args.bundle or (bundles_glob and newest(os.path.join(root, bundles_glob) if not bundles_glob.startswith(("~", "/")) else bundles_glob))
    if not bundle:
        raise ExportError("no .xcresult bundle: pass --bundle, or run the suite with -enableCodeCoverage YES first")
    if not os.path.isdir(bundle):
        raise ExportError("%s is not a bundle on disk" % bundle)
    text = run(["xcrun", "xccov", "view", "--archive", "--json", bundle], "xccov over %s" % bundle)
    return app_records(json.loads(text), app_root)


def read_package(args, build_dir, package_root):
    if args.package_lcov:
        with open(args.package_lcov) as handle:
            return package_records(handle.read(), package_root)
    # Both through `.build/debug`, the link swift test points at whichever tree
    # its build system last wrote: `<triple>/debug` before Swift 6.4,
    # `out/Products/Debug` since. A glob over `*/debug` kept finding the older
    # layout's test binary, stale beside a fresh profile.
    profile = os.path.join(build_dir, "debug", "codecov", "default.profdata")
    binaries = glob.glob(os.path.join(build_dir, "debug", "*.xctest", "Contents", "MacOS", "*"))
    if not os.path.isfile(profile) or not binaries:
        raise ExportError("no package coverage under %s — run ./scripts/run-core-tests.sh first" % build_dir)
    text = run(["xcrun", "llvm-cov", "export", "-format=lcov", "-instr-profile", profile, binaries[0]],
               "llvm-cov over %s" % binaries[0])
    return package_records(text, package_root)


def settings(args):
    """(repo root, app root, package root, package build dir) from the flags and quality.json."""
    root = repo_root(args.repo)
    app_src, pkg_src, bundles_glob = crap_settings(root)
    if not (args.app_root or app_src) or not (args.package_root or pkg_src):
        raise ExportError("quality.json names no crap.xccov.sources / crap.llvm_cov.sources and no --app-root / --package-root was given")
    return (root, os.path.join(root, args.app_root or app_src), os.path.join(root, args.package_root or pkg_src),
            os.path.join(root, args.package_build or "Kiteloop/KiteloopCore/.build"), bundles_glob)


def write(out, text):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "w") as handle:
        handle.write(text)
    os.replace(tmp, out)


def main():
    parser = argparse.ArgumentParser(description="one LCOV file from a suite run's coverage")
    parser.add_argument("--out", required=True, help="the LCOV file to write")
    parser.add_argument("--bundle", help="the run's .xcresult (default: the newest crap.xccov.bundles matches)")
    parser.add_argument("--xccov-json", help="a saved `xccov view --archive --json` instead of a bundle")
    parser.add_argument("--package-build", help="the package's .build directory (default: Kiteloop/KiteloopCore/.build)")
    parser.add_argument("--package-lcov", help="a saved llvm-cov LCOV export instead of the build directory")
    parser.add_argument("--app-root", help="keep app files under this root (default: crap.xccov.sources)")
    parser.add_argument("--package-root", help="keep package files under this root (default: crap.llvm_cov.sources)")
    parser.add_argument("--repo", help="the repository root (default: this script's parent)")
    args = parser.parse_args()
    try:
        root, app_root, package_root, build_dir, bundles_glob = settings(args)
        app = read_app(args, root, app_root, bundles_glob)
        package = read_package(args, build_dir, package_root)
    except ExportError as error:
        print("export-coverage-lcov: %s" % error, file=sys.stderr)
        return 2
    out = os.path.join(root, args.out) if not os.path.isabs(args.out) else args.out
    write(out, lcov_for(app, package))
    print("export-coverage-lcov: wrote %s — %d app file(s), %d package file(s)" % (
        os.path.relpath(out, root), len(app), len(package)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
