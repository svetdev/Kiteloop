#!/usr/bin/env python3
"""check-target-membership — fail if a scanned .swift file is not in its Xcode target.

Walks two projects: the Kiteloop app project (`ROOTS` below) and the
KiteloopMobile companion (its `Sources` and `Tests` roots) — see `build_projects`. Scanned
means: under one of a project's roots, minus the `EXCLUDED_DIRS`. That is
narrower than "every .swift file in the checkout", and the success line says so
rather than claiming the whole tree — a preflight whose reassurance is broader
than its check is the same silence this script exists to end.

Kiteloop's targets are edited by hand (and by agents) directly in
`project.pbxproj`. Xcode adds a file to a target automatically; a file written
from the command line does not get added, and nothing complains. A test file in
that state compiles nowhere, runs never, and passes review as evidence that its
behaviour is covered — the suite stays green *because* the test is invisible.
26 test files had accumulated in exactly that state before this check existed.

The check walks the PBXGroup tree to reconstruct the real path of every file
reference, then compares that against the .swift files on disk. Comparing
basenames alone would be wrong: `Control/HTTPServer.swift` is stored as a
multi-segment path on its file reference, and two files in different groups can
share a basename.

A file reference is necessary but not sufficient: what makes a file compile is a
PBXBuildFile for it listed in some target's PBXSourcesBuildPhase. A file can be
fully visible in the group tree, carry a build file, and still be compiled by no
target because that build file appears in no phase — which is the same silence,
reached one step later. `KiteloopControlServerCoordinatorRefillTests.swift` sat
in exactly that state, its ten test methods never compiled, while this check
reported every file referenced. So the on-disk paths are resolved through the
build files into the Sources phases of the PBXNativeTargets.

Nor is *some* target sufficient. A file under `KiteloopTests/` whose build file
sits in the `Kiteloop` app target's Sources phase compiles into the app, is
never run by the test bundle, and would satisfy a check that asked only whether
something builds it — the same silence again, one step later still. So each root
is judged against the target that root belongs to, within its own project — a
project's roots and targets are read only from that project's own pbxproj —
and the three failure modes are reported apart: not referenced at all,
referenced and compiled by no target, or compiled by the wrong target.

The same walk also runs in reverse. A move that leaves a file reference behind
— because the unregister pass found nothing at the old path to drop — points a
registration at a file that is no longer on disk. Xcode does not mind; a build
does, sometimes as a raw "build input file cannot be found" from xcodebuild,
and sometimes not at all when the stale build file sits in no phase and is
never asked to compile. So every .swift reference whose resolved path falls
under a scanned root is checked against the disk too, and reported apart from
the other three.

Exits non-zero and lists the offenders if any .swift file under a scanned root
is missing from the project, missing from every target, or built by a target
other than its own — or if a project.pbxproj reference names a file that is no
longer on disk under a scanned root. No third-party dependencies (Python 3
stdlib only).

Usage
  ./scripts/check-target-membership.py            # scan every root of both projects
  ./scripts/check-target-membership.py --quiet    # only print on failure
  ./scripts/check-target-membership.py --pbxproj PATH   # read another Kiteloop project file
"""

import argparse
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(REPO, "Kiteloop", "Kiteloop.xcodeproj", "project.pbxproj")
MOBILE_PBXPROJ = os.path.join(
    REPO, "KiteloopMobile", "KiteloopMobile.xcodeproj", "project.pbxproj"
)

# Source roots, relative to the Kiteloop/ directory that holds the .xcodeproj,
# each mapped to the PBXNativeTarget that is meant to compile what is under it.
# These three are the whole scope of the Kiteloop app project (`build_projects`
# below adds the KiteloopMobile companion beside them), and `KiteloopSpike` is
# left out of them deliberately: `KiteloopSpike/spike.swift` is a standalone
# `#!/usr/bin/env swift` script, run as `swift Kiteloop/KiteloopSpike/spike.swift`
# and belonging to no target by design, so it is not an unregistered file.
ROOTS = {
    "Kiteloop": "Kiteloop",
    "KiteloopTests": "KiteloopTests",
    "KiteloopUITests": "KiteloopUITests",
}

# Directories that are deliberately outside every target, pruned inside a root.
EXCLUDED_DIRS = {"Frameworks", "Fixtures"}

# Object ids are 24 hex chars when Xcode or XcodeGen writes them, but this
# pbxproj is also edited by hand and carries ids of other lengths
# (`KP06AGENTC0001A1B2C3D4E5F6`). Matching a fixed width silently mis-keys those.
UUID = r"[0-9A-Za-z]+"
GROUP_RE = re.compile(
    r"\t\t(" + UUID + r") /\* [^\n]*? \*/ = \{\n\t\t\tisa = PBXGroup;\n"
    r"\t\t\tchildren = \(\n(.*?)\t\t\t\);\n((?:\t\t\t\w+ = [^\n]*;\n)*)\t\t\};\n",
    re.S,
)
FILE_REF_RE = re.compile(
    r"\t\t(" + UUID + r") /\* [^\n]*? \*/ = \{isa = PBXFileReference;([^\n]*)\};"
)
CHILD_RE = re.compile(r"\t\t\t\t(" + UUID + r") /\*")
ATTR_RE = re.compile(r'(\w+) = "?([^";]*)"?;')
BUILD_FILE_RE = re.compile(
    r"\t\t(" + UUID + r") /\* [^\n]*? \*/ = \{isa = PBXBuildFile; fileRef = ("
    + UUID
    + r") "
)
SOURCES_PHASE_RE = re.compile(
    r"\t\t(" + UUID + r") /\* [^\n]*? \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n"
    r".*?files = \(\n(.*?)\t\t\t\);\n",
    re.S,
)
# The whole target body, so its phases and its name can be read together — a
# phase alone cannot say which target compiles a file.
NATIVE_TARGET_RE = re.compile(
    r"\t\t" + UUID + r" /\* [^\n]*? \*/ = \{\n\t\t\tisa = PBXNativeTarget;\n"
    r"(.*?)\t\t\};\n",
    re.S,
)
BUILD_PHASES_RE = re.compile(r"buildPhases = \(\n(.*?)\t\t\t\);\n", re.S)
# `\t\t\t` anchors this to the target's own `name`, not to `productName`.
TARGET_NAME_RE = re.compile(r'\t\t\tname = "?([^";\n]*)"?;')


def resolve_compiled_by(pbxproj_text, sources_phases, build_files):
    """target name -> file-ref UUIDs it compiles, read from the native targets.

    Only phases a target actually builds count: a Sources phase orphaned from
    every PBXNativeTarget compiles nothing, and reading it would let an
    unreachable phase vouch for a file.
    """
    compiled_by = {}
    for body in NATIVE_TARGET_RE.findall(pbxproj_text):
        name = TARGET_NAME_RE.search(body)
        phases = BUILD_PHASES_RE.search(body)
        if not name or not phases:
            continue
        refs = compiled_by.setdefault(name.group(1), set())
        for phase in CHILD_RE.findall(phases.group(1)):
            for build_file in sources_phases.get(phase, []):
                if build_file in build_files:
                    refs.add(build_files[build_file])
    return compiled_by


def parse(pbxproj_text):
    """Return (groups, file_refs, compiled_by), the last target name -> file-ref UUIDs."""
    groups = {}
    for uid, children, attrs in GROUP_RE.findall(pbxproj_text):
        parsed = dict(ATTR_RE.findall(attrs))
        groups[uid] = {
            "path": parsed.get("path"),
            "children": CHILD_RE.findall(children),
        }

    file_refs = {}
    for uid, attrs in FILE_REF_RE.findall(pbxproj_text):
        parsed = dict(ATTR_RE.findall(attrs))
        if parsed.get("path", "").endswith(".swift"):
            file_refs[uid] = parsed["path"]

    # A build file is what a Sources phase actually lists; it points at the file
    # reference. Package products (`productRef = …`) carry no fileRef and are
    # skipped by the pattern.
    build_files = dict(BUILD_FILE_RE.findall(pbxproj_text))

    sources_phases = {
        uid: CHILD_RE.findall(files)
        for uid, files in SOURCES_PHASE_RE.findall(pbxproj_text)
    }

    compiled_by = resolve_compiled_by(pbxproj_text, sources_phases, build_files)
    return groups, file_refs, compiled_by


def referenced_paths(groups, file_refs):
    """Map every .swift file reference's real path to the UUIDs that claim it.

    Two references can name the same path, so the value is a set: the file is
    compiled if *any* of them is.
    """
    found = {}
    child_uids = {c for g in groups.values() for c in g["children"]}
    roots = [uid for uid in groups if uid not in child_uids]

    def walk(uid, prefix):
        group = groups[uid]
        # A group with no path contributes no path component (a virtual group).
        here = os.path.join(prefix, group["path"]) if group["path"] else prefix
        for child in group["children"]:
            if child in groups:
                walk(child, here)
            elif child in file_refs:
                path = os.path.normpath(os.path.join(here, file_refs[child]))
                found.setdefault(path, set()).add(child)

    for root in roots:
        walk(root, "")
    return found


def stale_references(referenced, on_disk_paths, roots=None):
    """Map root -> resolved paths that fall under it but are not on disk.

    Gated on the roots of the project being judged (default ROOTS, the
    Kiteloop app project's), not on every root `referenced_paths` can resolve:
    a path resolving outside them (`referenced_paths` still returns it, since
    it walks the whole group tree) names no root this project's pass judges,
    and is not reported by it.
    """
    if roots is None:
        roots = ROOTS
    stale = {}
    for path in sorted(referenced):
        root = path.split(os.sep)[0]
        if root in roots and path not in on_disk_paths:
            stale.setdefault(root, []).append(path)
    return stale


def on_disk(root):
    paths = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIRS]
        for name in filenames:
            if name.endswith(".swift"):
                paths.append(os.path.normpath(os.path.join(dirpath, name)))
    return paths


def build_projects(pbxproj_override=None):
    """The (name, pbxproj, dir, roots) of every project this check walks.

    `pbxproj_override` swaps the Kiteloop app project's file, the way
    `--pbxproj` always has — it changes neither its directory nor its roots,
    and it leaves the KiteloopMobile entry alone.
    """
    return [
        {
            "name": "Kiteloop",
            "pbxproj": pbxproj_override or PBXPROJ,
            "dir": os.path.join(REPO, "Kiteloop"),
            "roots": ROOTS,
        },
        {
            "name": "KiteloopMobile",
            "pbxproj": MOBILE_PBXPROJ,
            "dir": os.path.join(REPO, "KiteloopMobile"),
            "roots": {"Sources": "KiteloopMobile", "Tests": "KiteloopMobileTests"},
        },
    ]


def classify_paths(paths, referenced, compiled_by, target):
    """Sort a root's on-disk paths into (unreferenced, uncompiled, misfiled)."""
    own = compiled_by.get(target, set())
    absent, silent, wrong = [], [], []
    for path in sorted(paths):
        if path not in referenced:
            absent.append(path)
            continue
        refs = referenced[path]
        if refs & own:
            continue
        # Named apart from the root's own target, so the message can say
        # which target does build the file rather than only that this one
        # does not.
        builders = sorted(n for n, r in compiled_by.items() if refs & r)
        if builders:
            wrong.append(f"{path} (compiled by {', '.join(builders)}, belongs to {target})")
        else:
            silent.append(path)
    return absent, silent, wrong


def scan_project(project):
    """Run the four passes against one (pbxproj, dir, roots) project."""
    with open(project["pbxproj"]) as handle:
        groups, file_refs, compiled_by = parse(handle.read())
    referenced = referenced_paths(groups, file_refs)

    os.chdir(project["dir"])
    unreferenced, uncompiled, misfiled = {}, {}, {}
    scanned = 0
    scanned_roots = []
    on_disk_paths = set()
    for root, target in project["roots"].items():
        if not os.path.isdir(root):
            continue
        scanned_roots.append(root)
        paths = on_disk(root)
        on_disk_paths.update(paths)
        scanned += len(paths)
        absent, silent, wrong = classify_paths(paths, referenced, compiled_by, target)
        if absent:
            unreferenced[root] = absent
        if silent:
            uncompiled[root] = silent
        if wrong:
            misfiled[root] = wrong

    stale = stale_references(referenced, on_disk_paths, project["roots"])
    return {
        "unreferenced": unreferenced,
        "uncompiled": uncompiled,
        "misfiled": misfiled,
        "stale": stale,
        "scanned": scanned,
        "scanned_roots": scanned_roots,
    }


def scan_projects(projects):
    """Run `scan_project` over every project, keyed by project name so a report
    can say which project an offender belongs to."""
    unreferenced, uncompiled, misfiled, stale = {}, {}, {}, {}
    scanned = 0
    scanned_roots = []
    for project in projects:
        result = scan_project(project)
        scanned += result["scanned"]
        scanned_roots.extend(result["scanned_roots"])
        for bucket, per_root in (
            (unreferenced, result["unreferenced"]),
            (uncompiled, result["uncompiled"]),
            (misfiled, result["misfiled"]),
            (stale, result["stale"]),
        ):
            if per_root:
                bucket[project["name"]] = per_root
    return {
        "unreferenced": unreferenced,
        "uncompiled": uncompiled,
        "misfiled": misfiled,
        "stale": stale,
        "scanned": scanned,
        "scanned_roots": scanned_roots,
    }


def report(missing, headline):
    """Print one failure bucket, nested project name -> root -> offending paths."""
    count = sum(len(paths) for roots in missing.values() for paths in roots.values())
    print(f"FAIL: {count} {headline}\n", file=sys.stderr)
    for project_name, roots in missing.items():
        for root, paths in roots.items():
            print(f"  {project_name}/{root}/ ({len(paths)}):", file=sys.stderr)
            for path in paths:
                print(f"    {path}", file=sys.stderr)
    print("", file=sys.stderr)


def report_failures(result):
    unreferenced = result["unreferenced"]
    uncompiled = result["uncompiled"]
    misfiled = result["misfiled"]
    stale = result["stale"]

    for bucket, headline in (
        (
            unreferenced,
            ".swift file(s) on disk are not referenced by project.pbxproj.\n"
            "They are invisible to xcodebuild — a test file here never runs.",
        ),
        (
            uncompiled,
            ".swift file(s) are referenced but compiled by no target.\n"
            "The file reference exists; no target's Sources phase builds it, so the\n"
            "code never compiles and a test file here never runs.",
        ),
        (
            misfiled,
            ".swift file(s) are compiled by a target other than their root's.\n"
            "The code compiles, so nothing fails to build — but a test file built\n"
            "into the app target is in no test bundle and never runs.",
        ),
        (
            stale,
            "project.pbxproj reference(s) name a .swift file that is no longer on disk.\n"
            "The registration is stale — a move or delete left it behind. A build may fail\n"
            "with \"build input file cannot be found\", or not fail at all if the stale\n"
            "build file sits in no phase.",
        ),
    ):
        if bucket:
            report(bucket, headline)

    for needed, advice in (
        (
            unreferenced or uncompiled,
            "Add them to the target: open the project in Xcode and drag them in, or add\n"
            "the four entries by hand in that project's project.pbxproj -- a\n"
            "PBXFileReference, a PBXBuildFile, a child of the enclosing PBXGroup, and a\n"
            "file in that target's PBXSourcesBuildPhase. All four are needed: the first\n"
            "three make the file visible, only the fourth makes it compile.",
        ),
        (
            misfiled,
            "Move each one to the target it belongs to: its PBXBuildFile has to be listed\n"
            "in that target's PBXSourcesBuildPhase, not another's. In Xcode this is the\n"
            "Target Membership checkbox in the file inspector.",
        ),
        (
            stale,
            "Remove the stale entries by hand in that project's project.pbxproj -- the\n"
            "PBXFileReference, its PBXBuildFile if any, and the child entry in the\n"
            "enclosing PBXGroup. This check only reports; it does not edit the project.",
        ),
    ):
        if needed:
            print(advice, file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--quiet", action="store_true", help="only print on failure")
    ap.add_argument(
        "--pbxproj",
        default=None,
        metavar="PATH",
        help="Kiteloop app project's project.pbxproj to read (default: this repo's)",
    )
    args = ap.parse_args()

    result = scan_projects(build_projects(args.pbxproj))
    buckets = (result["unreferenced"], result["uncompiled"], result["misfiled"], result["stale"])

    if not any(buckets):
        if not args.quiet:
            # Name the scope beside the count: the claim is about what was
            # walked, not about every .swift file in the checkout.
            where = ", ".join(f"{root}/" for root in result["scanned_roots"])
            skipped = ", ".join(f"{name}/" for name in sorted(EXCLUDED_DIRS))
            print(
                f"OK: all {result['scanned']} .swift files under {where} are compiled by "
                f"their own target, and every project.pbxproj reference under "
                f"them resolves on disk (not scanned: {skipped})"
            )
        return 0

    report_failures(result)
    return 1


if __name__ == "__main__":
    sys.exit(main())
