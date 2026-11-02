#!/usr/bin/env python3
"""test-check-target-membership — assert the readers in check-target-membership.py.

The check it asserts is the first thing the suite preflight runs, and it is the
one whose failure mode is silence. It is regex over `project.pbxproj`: one
pattern that stops matching — a group block laid out a hair differently by a
newer Xcode, an object id of a length `UUID` no longer admits — and it goes on
printing `OK: all N .swift files … are compiled by their own target` while
vouching for nothing. That is precisely the state it was written to end: 26 test
files had accumulated unregistered, compiling nowhere, running never, and the
suite stayed green *because* they were invisible. A broken checker puts every
file back in that state at once, and nothing today would say so.

So the readers are driven directly. `parse` and `referenced_paths` are called
over synthetic pbxproj text, one fixture per invariant the check's own docstring
names — the three verdicts it distinguishes, and the path composition that makes
a verdict about the right file. The script's filename has dashes, so it is loaded
with `importlib.util.spec_from_file_location` rather than imported.

Then the whole check is run end to end against mutations of this repository's own
project file: a build file taken out of its Sources phase, a file reference
deleted, the app target renamed. Each is a defect the check exists to catch, and
each case asserts it exits non-zero and names the file — because a reader that
parses correctly and a check that reports are different claims, and only the
second one is what stops a run. The mutations are written to a temporary copy;
`--pbxproj` is what lets the check read one, and nothing here writes to the
repository.

It starts no build, reads no process list and writes nothing outside a temporary
directory, so it is safe to run — on its own or as part of the suite — while
Kiteloop is running.

  ./scripts/test-check-target-membership.py
"""

import importlib.util
import os
import re
import subprocess
import shutil
import sys
import tempfile

sys.dont_write_bytecode = True  # leave no __pycache__ beside the script

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(HERE, "check-target-membership.py")

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


def check_absent(name, needle, haystack):
    check(name, needle not in haystack, "%r unexpectedly in:\n%s" % (needle, haystack))


def load_script():
    """The script as a module — its filename has dashes, so it cannot be imported."""
    spec = importlib.util.spec_from_file_location("check_target_membership", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


module = load_script()


# --- Writing a pbxproj --------------------------------------------------------
#
# The four object kinds the check reads, spelled exactly as Xcode and XcodeGen
# write them — tabs, comments and all. That layout *is* what the patterns match:
# a fixture that wrote them loosely would assert nothing about the file on disk,
# so each builder below is a line taken from Kiteloop/Kiteloop.xcodeproj and
# parameterised.


def file_ref(uid, path, kind="sourcecode.swift"):
    return (
        '\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = %s; '
        'path = %s; sourceTree = "<group>"; };\n' % (uid, os.path.basename(path), kind, path)
    )


def build_file(uid, ref, name):
    return (
        "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n"
        % (uid, name, ref, name)
    )


def children_of(uids):
    return "".join("\t\t\t\t%s /* child */,\n" % uid for uid in uids)


def group(uid, name, children, path=None):
    block = (
        "\t\t%s /* %s */ = {\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        "%s"
        "\t\t\t);\n" % (uid, name, children_of(children))
    )
    if path is not None:
        block += "\t\t\tpath = %s;\n" % path
    return block + '\t\t\tsourceTree = "<group>";\n\t\t};\n'


def sources_phase(uid, build_files):
    return (
        "\t\t%s /* Sources */ = {\n"
        "\t\t\tisa = PBXSourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        "%s"
        "\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};\n" % (uid, children_of(build_files))
    )


def native_target(uid, name, phases):
    return (
        "\t\t%s /* %s */ = {\n"
        "\t\t\tisa = PBXNativeTarget;\n"
        "\t\t\tbuildConfigurationList = CFG%s /* Build configuration list */;\n"
        "\t\t\tbuildPhases = (\n"
        "%s"
        "\t\t\t);\n"
        "\t\t\tbuildRules = (\n"
        "\t\t\t);\n"
        "\t\t\tdependencies = (\n"
        "\t\t\t);\n"
        "\t\t\tname = %s;\n"
        "\t\t\tproductName = %s;\n"
        '\t\t\tproductType = "com.apple.product-type.application";\n'
        "\t\t};\n" % (uid, name, uid, children_of(phases), name, name)
    )


def pbxproj(*blocks):
    return (
        "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tobjects = {\n"
        + "".join(blocks)
        + "\t};\n\trootObject = ROOTOBJECT0000000000001 /* Project object */;\n}\n"
    )


def read(text):
    """(referenced, compiled_by) — the two readings a verdict is made of."""
    groups, file_refs, compiled_by = module.parse(text)
    return module.referenced_paths(groups, file_refs), compiled_by


def compiled_anywhere(referenced, compiled_by, path):
    refs = referenced.get(path, set())
    return sorted(name for name, built in compiled_by.items() if refs & built)


print("test-check-target-membership")

# --- The three verdicts -------------------------------------------------------
#
# What the check distinguishes, and the whole reason it walks build files and
# phases rather than stopping at the group tree. All three files below are fully
# referenced — visible in Xcode, present in the project — and only the first one
# compiles.
#
#   Compiled    build file listed in a phase the app target builds
#   Uncompiled  build file exists, listed in no phase at all
#   Orphaned    build file listed in a Sources phase no native target names
#
# The second is the state KiteloopControlServerCoordinatorRefillTests.swift sat
# in, ten test methods never compiled while the check reported every file
# referenced. The third is the same silence read from the other end: a phase no
# target builds compiles nothing, and reading it would let an unreachable phase
# vouch for a file.

VERDICTS = pbxproj(
    file_ref("FR000000000000000000COM", "Compiled.swift"),
    file_ref("FR000000000000000000UNC", "Uncompiled.swift"),
    file_ref("FR000000000000000000ORP", "Orphaned.swift"),
    file_ref("FR0000000000000000APP", "Kiteloop.app", kind="wrapper.application"),
    build_file("BF000000000000000000COM", "FR000000000000000000COM", "Compiled.swift"),
    build_file("BF000000000000000000UNC", "FR000000000000000000UNC", "Uncompiled.swift"),
    build_file("BF000000000000000000ORP", "FR000000000000000000ORP", "Orphaned.swift"),
    group("GR000000000000000000ROT", "Root", ["GR000000000000000000APP"]),
    group(
        "GR000000000000000000APP",
        "Kiteloop",
        [
            "FR000000000000000000COM",
            "FR000000000000000000UNC",
            "FR000000000000000000ORP",
            "FR0000000000000000APP",
        ],
        path="Kiteloop",
    ),
    sources_phase("PH000000000000000000APP", ["BF000000000000000000COM"]),
    # A Sources phase that exists and that no PBXNativeTarget lists.
    sources_phase("PH000000000000000000ORP", ["BF000000000000000000ORP"]),
    native_target("TG000000000000000000APP", "Kiteloop", ["PH000000000000000000APP"]),
)

referenced, compiled_by = read(VERDICTS)

check_equal(
    "the target compiles the one file its Sources phase lists",
    {"Kiteloop": {"FR000000000000000000COM"}},
    compiled_by,
)
check_equal(
    "every .swift reference resolves to its path under the group",
    ["Kiteloop/Compiled.swift", "Kiteloop/Orphaned.swift", "Kiteloop/Uncompiled.swift"],
    sorted(referenced),
)
check_absent(
    "a reference that is not a .swift file is not tracked at all",
    "Kiteloop/Kiteloop.app",
    repr(sorted(referenced)),
)

check_equal(
    "a file whose build file is in the target's Sources phase is compiled by it",
    ["Kiteloop"],
    compiled_anywhere(referenced, compiled_by, "Kiteloop/Compiled.swift"),
)
check_equal(
    "a file whose build file appears in no phase is compiled by nothing",
    [],
    compiled_anywhere(referenced, compiled_by, "Kiteloop/Uncompiled.swift"),
)
check_equal(
    "a file in a Sources phase no native target lists is compiled by nothing",
    [],
    compiled_anywhere(referenced, compiled_by, "Kiteloop/Orphaned.swift"),
)

# The orphaned file is referenced and carries a build file — it fails on the
# phase alone. Stated apart so a fixture that lost either would not read as the
# orphaned-phase rule holding.
check(
    "the orphaned file is referenced and does carry a build file",
    "Kiteloop/Orphaned.swift" in referenced
    and "BF000000000000000000ORP" in VERDICTS,
)

# --- Which target ------------------------------------------------------------
#
# `some target` is not enough: a file under KiteloopTests/ built into the app
# target compiles, is in no test bundle and never runs. So the sets are kept
# apart by target name, which is what the ROOTS mapping is judged against.

def two_targets(app_phase_files, test_phase_files):
    """An app file and a test file; which phase lists the test file's build file."""
    return pbxproj(
        file_ref("FR000000000000000000APP", "App.swift"),
        file_ref("FR00000000000000000TST", "AppTests.swift"),
        build_file("BF000000000000000000APP", "FR000000000000000000APP", "App.swift"),
        build_file("BF00000000000000000TST", "FR00000000000000000TST", "AppTests.swift"),
        group(
            "GR000000000000000000ROT",
            "Root",
            ["GR00000000000000000APP", "GR0000000000000TST"],
        ),
        group("GR00000000000000000APP", "Kiteloop", ["FR000000000000000000APP"], path="Kiteloop"),
        group(
            "GR0000000000000TST",
            "KiteloopTests",
            ["FR00000000000000000TST"],
            path="KiteloopTests",
        ),
        sources_phase("PH000000000000000000APP", app_phase_files),
        sources_phase("PH0000000000000000TST", test_phase_files),
        native_target("TG000000000000000000APP", "Kiteloop", ["PH000000000000000000APP"]),
        native_target("TG0000000000000000TST", "KiteloopTests", ["PH0000000000000000TST"]),
    )


referenced, compiled_by = read(
    two_targets(["BF000000000000000000APP"], ["BF00000000000000000TST"])
)
check_equal(
    "each target compiles its own files and not the other's",
    {
        "Kiteloop": {"FR000000000000000000APP"},
        "KiteloopTests": {"FR00000000000000000TST"},
    },
    compiled_by,
)

# The misfiled shape: the same test file, its build file listed by the app
# target's phase instead. It compiles — and by the target that cannot run it.
referenced, compiled_by = read(
    two_targets(["BF000000000000000000APP", "BF00000000000000000TST"], [])
)
check_equal(
    "a test file built by the app target is named as compiled by that target",
    ["Kiteloop"],
    compiled_anywhere(referenced, compiled_by, "KiteloopTests/AppTests.swift"),
)

# --- Where a file actually is -------------------------------------------------
#
# A verdict is about a path, so the path has to be the real one. Comparing
# basenames would be wrong twice over: two files in different groups share one,
# and `Control/HTTPServer.swift` is stored as a multi-segment path on its own
# reference. Group paths compose, and a group with no path of its own — Xcode's
# virtual group, which exists to organise the navigator and names no directory —
# contributes no component.

PATHS = pbxproj(
    file_ref("FR000000000000000000DEP", "Deep.swift"),
    file_ref("FR000000000000000000LOO", "Loose.swift"),
    file_ref("FR000000000000000000MUL", "Control/HTTPServer.swift"),
    group("GR000000000000000000ROT", "Root", ["GR000000000000000000APP"]),
    group("GR000000000000000000APP", "Kiteloop", ["GR000000000000000000VIR"], path="Kiteloop"),
    # No `path` attribute at all: a virtual group.
    group(
        "GR000000000000000000VIR",
        "Support",
        ["GR000000000000000000SRV", "FR000000000000000000LOO"],
    ),
    group(
        "GR000000000000000000SRV",
        "Services",
        ["FR000000000000000000DEP", "FR000000000000000000MUL"],
        path="Services",
    ),
)

referenced, _ = read(PATHS)
check_equal(
    "a nested group's path composes through its parents",
    {"FR000000000000000000DEP"},
    referenced.get("Kiteloop/Services/Deep.swift", set()),
)
check_equal(
    "a virtual group contributes no path component",
    {"FR000000000000000000LOO"},
    referenced.get("Kiteloop/Loose.swift", set()),
)
check_equal(
    "a multi-segment path on the reference resolves whole",
    {"FR000000000000000000MUL"},
    referenced.get("Kiteloop/Services/Control/HTTPServer.swift", set()),
)
check_equal(
    "and nothing else is resolved beside them",
    3,
    len(referenced),
)

# --- Object ids that Xcode did not write --------------------------------------
#
# Xcode and XcodeGen write 24 hex characters; this project is also edited by hand
# and carries ids of other lengths — `KP06AGENTC0001A1B2C3D4E5F6` is in the file
# today. A pattern matching a fixed width mis-keys those, and a mis-keyed build
# file is a file the check quietly stops vouching for.

ODD_IDS = pbxproj(
    file_ref("KP06AGENTC0001A1B2C3D4E5F6", "Handwritten.swift"),
    build_file("AB12", "KP06AGENTC0001A1B2C3D4E5F6", "Handwritten.swift"),
    group("R1", "Root", ["G2"]),
    group("G2", "Kiteloop", ["KP06AGENTC0001A1B2C3D4E5F6"], path="Kiteloop"),
    sources_phase("P3", ["AB12"]),
    native_target("T4", "Kiteloop", ["P3"]),
)

referenced, compiled_by = read(ODD_IDS)
check_equal(
    "an object id that is not 24 characters still parses and still compiles",
    ["Kiteloop"],
    compiled_anywhere(referenced, compiled_by, "Kiteloop/Handwritten.swift"),
)

# --- Two references, one path -------------------------------------------------
#
# A hand-edited project can end up with the same file referenced twice. The file
# is compiled if *any* of its references is, so the reading is a set of uids per
# path rather than one uid — and which of the two carries the build file must not
# decide the verdict.

def duplicated(compiled_ref):
    """Two references to Dup.swift; only `compiled_ref` is in the phase."""
    blocks = [
        file_ref("FR000000000000000000ONE", "Dup.swift"),
        file_ref("FR000000000000000000TWO", "Dup.swift"),
        group("GR000000000000000000ROT", "Root", ["GR000000000000000000APP"]),
        group(
            "GR000000000000000000APP",
            "Kiteloop",
            ["FR000000000000000000ONE", "FR000000000000000000TWO"],
            path="Kiteloop",
        ),
    ]
    listed = []
    if compiled_ref:
        blocks.append(build_file("BF000000000000000000DUP", compiled_ref, "Dup.swift"))
        listed = ["BF000000000000000000DUP"]
    blocks.append(sources_phase("PH000000000000000000APP", listed))
    blocks.append(native_target("TG000000000000000000APP", "Kiteloop", ["PH000000000000000000APP"]))
    return pbxproj(*blocks)


referenced, compiled_by = read(duplicated("FR000000000000000000ONE"))
check_equal(
    "two references naming one path are read as both claiming it",
    {"FR000000000000000000ONE", "FR000000000000000000TWO"},
    referenced.get("Kiteloop/Dup.swift", set()),
)
check_equal(
    "the path is compiled when the first of them is",
    ["Kiteloop"],
    compiled_anywhere(referenced, compiled_by, "Kiteloop/Dup.swift"),
)

referenced, compiled_by = read(duplicated("FR000000000000000000TWO"))
check_equal(
    "and when the second of them is",
    ["Kiteloop"],
    compiled_anywhere(referenced, compiled_by, "Kiteloop/Dup.swift"),
)

referenced, compiled_by = read(duplicated(None))
check_equal(
    "and by neither when no reference to it is built",
    [],
    compiled_anywhere(referenced, compiled_by, "Kiteloop/Dup.swift"),
)

# --- Two projects in one run ---------------------------------------------------
#
# `scan_projects` is what turns the single (pbxproj, dir, roots) triple `main`
# used to run once into a list run once per project — the shape that lets the
# Kiteloop app project and the KiteloopMobile companion be judged in the same
# pass without one's files being compared against the other's target. Each
# project here needs real files on disk, not just synthetic pbxproj text: the
# unreferenced verdict comes from `on_disk`, which walks an actual directory.


def synthetic_project(name, pbxproj_text, files):
    """A temp dir laid out like a project: `files` (relative paths) written to
    disk under it, `pbxproj_text` written at <dir>/<name>.xcodeproj/project.pbxproj.
    Returns (dir, pbxproj_path)."""
    root = tempfile.mkdtemp(prefix="test-check-target-membership-%s-" % name)
    fixtures.append(root)
    proj_dir = os.path.join(root, "%s.xcodeproj" % name)
    os.makedirs(proj_dir)
    with open(os.path.join(proj_dir, "project.pbxproj"), "w") as handle:
        handle.write(pbxproj_text)
    for rel_path in files:
        full = os.path.join(root, rel_path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as handle:
            handle.write("// synthetic\n")
    return root, os.path.join(proj_dir, "project.pbxproj")


PROJECT_ONE_TEXT = pbxproj(
    file_ref("FR00000000000000000CP1", "Compiled1.swift"),
    build_file("BF00000000000000000CP1", "FR00000000000000000CP1", "Compiled1.swift"),
    group("GR00000000000000000RO1", "Root", ["GR00000000000000000AP1"]),
    group("GR00000000000000000AP1", "Kiteloop", ["FR00000000000000000CP1"], path="Kiteloop"),
    sources_phase("PH00000000000000000AP1", ["BF00000000000000000CP1"]),
    native_target("TG00000000000000000AP1", "Kiteloop", ["PH00000000000000000AP1"]),
)

# The second project deliberately reuses the target name "Kiteloop" for a
# target that owns none of its `Sources` root, alongside the target that
# actually does — so a leak between the two projects' own `compiled_by`
# readings would show up as a false compile rather than passing by accident.
PROJECT_TWO_TEXT = pbxproj(
    file_ref("FR00000000000000000CP2", "Compiled2.swift"),
    file_ref("FR00000000000000000MF2", "Misfiled2.swift"),
    build_file("BF00000000000000000CP2", "FR00000000000000000CP2", "Compiled2.swift"),
    build_file("BF00000000000000000MF2", "FR00000000000000000MF2", "Misfiled2.swift"),
    group("GR00000000000000000RO2", "Root", ["GR00000000000000000SR2"]),
    group(
        "GR00000000000000000SR2",
        "Sources",
        ["FR00000000000000000CP2", "FR00000000000000000MF2"],
        path="Sources",
    ),
    sources_phase("PH00000000000000000MB2", ["BF00000000000000000CP2"]),
    sources_phase("PH00000000000000000OT2", ["BF00000000000000000MF2"]),
    native_target("TG00000000000000000MB2", "KiteloopMobile", ["PH00000000000000000MB2"]),
    native_target("TG00000000000000000OT2", "Kiteloop", ["PH00000000000000000OT2"]),
)

ORIGINAL_CWD = os.getcwd()
dir1, pbxproj1 = synthetic_project("ProjOne", PROJECT_ONE_TEXT, ["Kiteloop/Compiled1.swift"])
dir2, pbxproj2 = synthetic_project(
    "ProjTwo",
    PROJECT_TWO_TEXT,
    ["Sources/Compiled2.swift", "Sources/Misfiled2.swift", "Sources/Unreferenced2.swift"],
)
two_projects = [
    {"name": "ProjOne", "pbxproj": pbxproj1, "dir": dir1, "roots": {"Kiteloop": "Kiteloop"}},
    {"name": "ProjTwo", "pbxproj": pbxproj2, "dir": dir2, "roots": {"Sources": "KiteloopMobile"}},
]
two_project_result = module.scan_projects(two_projects)
os.chdir(ORIGINAL_CWD)  # scan_project chdirs into each project's own dir

check_equal(
    "scanning two projects in one run counts every file across both",
    4,
    two_project_result["scanned"],
)
check_equal(
    "and names each project's own root",
    ["Kiteloop", "Sources"],
    two_project_result["scanned_roots"],
)
check_equal(
    "a file unreferenced in the second project is reported, its project named apart",
    {"ProjTwo": {"Sources": ["Sources/Unreferenced2.swift"]}},
    two_project_result["unreferenced"],
)
check_equal(
    "a file compiled by the wrong target of its own project is misfiled there, not"
    " read as compiled by the first project's identically-named target",
    {"ProjTwo": {"Sources": ["Sources/Misfiled2.swift (compiled by Kiteloop, belongs to KiteloopMobile)"]}},
    two_project_result["misfiled"],
)
check_equal("the first project has nothing wrong", False, "ProjOne" in two_project_result["unreferenced"])
check_equal("nor is it misfiled", False, "ProjOne" in two_project_result["misfiled"])

# --- The reverse direction: a reference with nothing on disk -----------------
#
# `referenced_paths` returns whatever the group tree resolves to, including a
# path outside every root this check judges — `stale_references` has to leave
# that one alone rather than reporting it as a dangling registration.

MIXED_REFS = {
    "Kiteloop/Gone.swift": {"FR0"},
    "Kiteloop/Here.swift": {"FR1"},
    "KiteloopTests/AlsoGone.swift": {"FR2"},
    "Elsewhere/Ghost.swift": {"FR3"},
}
ON_DISK = {"Kiteloop/Here.swift"}
check_equal(
    "a path resolving under a scanned root and missing on disk is stale",
    {
        "Kiteloop": ["Kiteloop/Gone.swift"],
        "KiteloopTests": ["KiteloopTests/AlsoGone.swift"],
    },
    module.stale_references(MIXED_REFS, ON_DISK),
)
check_equal(
    "a path found on disk is never reported as stale",
    False,
    any(
        "Here.swift" in path
        for paths in module.stale_references(MIXED_REFS, ON_DISK).values()
        for path in paths
    ),
)
check_equal(
    "a reference resolving outside the three roots is never reported as stale",
    False,
    any(
        "Ghost.swift" in path
        for paths in module.stale_references(MIXED_REFS, ON_DISK).values()
        for path in paths
    ),
)

# --- Against this checkout ----------------------------------------------------
#
# The fixtures say what the readers do; these say that they still do it to the
# file the check actually reads. A pattern that has stopped matching this
# project's layout parses it into nothing at all, and nothing-parsed is exactly
# how the check comes to vouch for every file — so the shape of what it reads
# here is asserted rather than assumed, without writing down counts that a
# registered file would make stale.

PROJECT_TEXT = open(module.PBXPROJ).read()
groups, file_refs, compiled_by = module.parse(PROJECT_TEXT)
referenced = module.referenced_paths(groups, file_refs)

check("this project file parses into groups", len(groups) > 0, "no PBXGroup matched")
check(
    "this project file parses into .swift references",
    len(file_refs) > 0,
    "no .swift PBXFileReference matched",
)
for _root, _target in sorted(module.ROOTS.items()):
    check(
        "the %s target is read, and compiles something" % _target,
        compiled_by.get(_target),
        "compiled_by holds %r" % sorted(compiled_by),
    )
check(
    "every reference resolves under one of the scanned roots",
    {p.split(os.sep)[0] for p in referenced} <= set(module.ROOTS),
    "resolved outside ROOTS: %r"
    % sorted({p for p in referenced if p.split(os.sep)[0] not in module.ROOTS}),
)
check(
    "composition runs deeper than one group here, so nesting is exercised",
    max((len(p.split(os.sep)) for p in referenced), default=0) >= 3,
    "no resolved path is more than two components deep",
)

# --- The companion's test root -------------------------------------------------
#
# `build_projects` maps the KiteloopMobile entry's `Tests` root to the
# KiteloopMobileTests target, beside the existing `Sources` -> KiteloopMobile
# mapping — the same shape the Kiteloop app project uses to keep its own app
# and test files apart. A companion test file registered in no target has to
# fail this scan the way a Mac one does, which needs the root actually walked
# against this checkout's own KiteloopMobile project, not just the dict shape.

mobile_project = next(p for p in module.build_projects() if p["name"] == "KiteloopMobile")
check_equal(
    "the KiteloopMobile entry names both its Sources and Tests roots",
    {"Sources": "KiteloopMobile", "Tests": "KiteloopMobileTests"},
    mobile_project["roots"],
)

mobile_result = module.scan_project(mobile_project)
os.chdir(ORIGINAL_CWD)  # scan_project chdirs into the project's own dir
check(
    "the companion's Tests root is scanned",
    "Tests" in mobile_result["scanned_roots"],
    "scanned_roots: %r" % mobile_result["scanned_roots"],
)
check_equal(
    "every companion file on disk, app and test, is referenced by its project",
    {},
    mobile_result["unreferenced"],
)
check_equal(
    "and none of them sit uncompiled or built by the wrong target",
    ({}, {}),
    (mobile_result["uncompiled"], mobile_result["misfiled"]),
)


# --- The check itself ---------------------------------------------------------
#
# A reader that parses and a check that reports are different claims, and only
# the second one stops a run. Each mutation below is one of the three failures
# the check exists to name, made in a copy of this repository's project file and
# handed back through `--pbxproj` — so what is asserted is the exit status and
# the message a person would actually get.


def run(pbxproj_path, *args):
    proc = subprocess.run(
        [sys.executable, SCRIPT, "--pbxproj", pbxproj_path, *args],
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout, proc.stderr


def mutated(text):
    """`text` written where the check can be pointed at it."""
    root = tempfile.mkdtemp(prefix="test-check-target-membership-")
    fixtures.append(root)
    path = os.path.join(root, "project.pbxproj")
    with open(path, "w") as handle:
        handle.write(text)
    return path


# A file this project compiles into the app target, chosen off the tree rather
# than written down: what it is does not matter, only that the check stops
# naming it once its registration is broken.
victim = sorted(
    path
    for path, refs in referenced.items()
    if path.startswith("Kiteloop" + os.sep) and refs & compiled_by["Kiteloop"]
)[0]
victim_ref = sorted(referenced[victim])[0]
victim_build_files = [
    uid
    for uid, ref in module.BUILD_FILE_RE.findall(PROJECT_TEXT)
    if ref == victim_ref
]
check(
    "the file the mutations below break is registered to begin with",
    victim_build_files,
    "no PBXBuildFile points at %s (%s)" % (victim, victim_ref),
)

code, out, err = run(module.PBXPROJ)
check_equal("the check passes against this project file", 0, code)
check_contains(
    "and says what it walked rather than claiming the whole tree",
    "are compiled by their own target",
    out,
)
check_contains(
    "and states the reverse direction too, not only that on-disk files compile",
    "every project.pbxproj reference under them resolves on disk (not scanned:",
    out,
)

# Its build file taken out of every phase: referenced, visible in Xcode, built by
# nothing.
no_phase = "".join(
    line + "\n"
    for line in PROJECT_TEXT.split("\n")
    if not any(line.startswith("\t\t\t\t%s " % uid) for uid in victim_build_files)
)
code, out, err = run(mutated(no_phase))
check_equal("a build file in no phase fails the check", 1, code)
check_contains(
    "and is reported as referenced but compiled by no target",
    "referenced but compiled by no target",
    err,
)
check_contains("the report names the file", victim, err)
check_equal("the failure is on stderr, and stdout carries none of it", "", out)

code, out, err = run(mutated(no_phase), "--quiet")
check_equal("--quiet still fails", 1, code)
check_contains("--quiet still names the offender", victim, err)

# Its file reference deleted outright: the state a file written from the command
# line is in, and the one 26 test files were in.
no_ref = "".join(
    line + "\n"
    for line in PROJECT_TEXT.split("\n")
    if not line.startswith("\t\t%s /* " % victim_ref)
)
code, out, err = run(mutated(no_ref))
check_equal("a .swift file with no file reference fails the check", 1, code)
check_contains(
    "and is reported as not referenced by the project at all",
    "are not referenced by project.pbxproj",
    err,
)
check_contains("that report names the file too", victim, err)

# The app target under another name: every file under Kiteloop/ is then compiled
# by a target that is not the one its root belongs to.
assert PROJECT_TEXT.count("\n\t\t\tname = Kiteloop;\n") == 1
renamed = PROJECT_TEXT.replace(
    "\n\t\t\tname = Kiteloop;\n", "\n\t\t\tname = KiteloopRenamed;\n"
)
code, out, err = run(mutated(renamed))
check_equal("a file built by another target than its root's fails the check", 1, code)
check_contains(
    "and the report says which target does build it",
    "%s (compiled by KiteloopRenamed, belongs to Kiteloop)" % victim,
    err,
)

# The reference's own path attribute rewritten to a name that is not on disk:
# the state a move leaves when the unregister pass found nothing to drop at
# the old path. Everything else about the reference — its build file, its
# phase, its target — is untouched.
victim_line_re = re.compile(
    r"\t\t%s /\* [^\n]*? \*/ = \{isa = PBXFileReference;[^\n]*\};\n" % re.escape(victim_ref)
)
old_line = victim_line_re.search(PROJECT_TEXT).group(0)
check("the victim's own file reference line is found before mutating it", bool(old_line))
GHOST_NAME = "GhostFileThatDoesNotExist.swift"
new_line = re.sub(r'path = "?[^";]*"?;', "path = %s;" % GHOST_NAME, old_line)
gone_path = PROJECT_TEXT.replace(old_line, new_line, 1)
code, out, err = run(mutated(gone_path))
check_equal("a reference naming a file that is not on disk fails the check", 1, code)
check_contains(
    "and is reported as pointing at a file no longer on disk",
    "no longer on disk",
    err,
)
check_contains("the report names the ghost path", GHOST_NAME, err)

for path in fixtures:
    shutil.rmtree(path, ignore_errors=True)

print("\n%s" % ("FAILED" if failed else "All checks passed."))
sys.exit(1 if failed else 0)
