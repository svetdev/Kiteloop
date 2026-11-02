#!/usr/bin/env python3
"""test-pbx-register — assert scripts/core-package/pbx-register.py's register and
unregister over fixture text, keyed by path rather than basename.

The fixture nests two groups — Services and Models — under a top-level group
whose path is the app target folder, and gives both a file named Foo.swift
(distinct ids, so it is possible today for two files to share a basename in
different groups even though no real registration currently does). Over that:
unregistering Services/Foo.swift drops its build-file line, its file-reference
line and both its membership lines, and leaves everything else — Bar.swift and
Models' Foo.swift included — byte for byte; registering Models/Foo.swift when
Models does not yet have it adds a file reference, a build file and both
membership lines, because "already registered" is asked of Models' group, not
of the file text as a whole; unregistering a path whose folder is not in the
group tree returns the text unchanged, prints that the file was not
registered, and does not raise. Also checked by reading their source: neither
core-move.py nor test-move.py still carries a file-reference search of its own
now that both call unregister.

  ./scripts/core-package/test-pbx-register.py
"""
import contextlib, importlib.util, io, os, sys
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "pbx-register.py")
failed = 0


def check(name, ok, detail=""):
    global failed
    print("  %s  %s" % ("ok  " if ok else "FAIL", name) + ("" if ok else "\n          " + detail))
    failed += 0 if ok else 1


spec = importlib.util.spec_from_file_location("pbx_register", SCRIPT)
pr = importlib.util.module_from_spec(spec); spec.loader.exec_module(pr)

REF_FOO, BF_FOO = "AAAA1111AAAA1111AAAA1111", "BBBB2222BBBB2222BBBB2222"
REF_BAR, BF_BAR = "CCCC3333CCCC3333CCCC3333", "DDDD4444DDDD4444DDDD4444"
REF_FOO2, BF_FOO2 = "3333000033330000CCCC0003", "4444000044440000DDDD0004"
TARGET_GROUP, SERVICES, MODELS = "1111000011110000AAAA0001", "EEEE5555EEEE5555EEEE5555", "2222000022220000BBBB0002"
NATIVE_TARGET, SOURCES_PHASE = "5555000055550000EEEE0005", "FFFF6666FFFF6666FFFF6666"

BF_FOO_LINE = "\t\t%s /* Foo.swift in Sources */ = {isa = PBXBuildFile; fileRef = %s /* Foo.swift */; };" % (BF_FOO, REF_FOO)
BF_BAR_LINE = "\t\t%s /* Bar.swift in Sources */ = {isa = PBXBuildFile; fileRef = %s /* Bar.swift */; };" % (BF_BAR, REF_BAR)
BF_FOO2_LINE = "\t\t%s /* Foo.swift in Sources */ = {isa = PBXBuildFile; fileRef = %s /* Foo.swift */; };" % (BF_FOO2, REF_FOO2)
REF_FOO_LINE = "\t\t%s /* Foo.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Foo.swift; sourceTree = \"<group>\"; };" % REF_FOO
REF_BAR_LINE = "\t\t%s /* Bar.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Bar.swift; sourceTree = \"<group>\"; };" % REF_BAR
REF_FOO2_LINE = "\t\t%s /* Foo.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Foo.swift; sourceTree = \"<group>\"; };" % REF_FOO2
GROUP_FOO_LINE = "\t\t\t\t%s /* Foo.swift */," % REF_FOO
GROUP_BAR_LINE = "\t\t\t\t%s /* Bar.swift */," % REF_BAR
GROUP_FOO2_LINE = "\t\t\t\t%s /* Foo.swift */," % REF_FOO2
PHASE_FOO_LINE = "\t\t\t\t%s /* Foo.swift in Sources */," % BF_FOO
PHASE_BAR_LINE = "\t\t\t\t%s /* Bar.swift in Sources */," % BF_BAR
PHASE_FOO2_LINE = "\t\t\t\t%s /* Foo.swift in Sources */," % BF_FOO2


def fixture(models_has_foo2):
    models_children = ([GROUP_FOO2_LINE] if models_has_foo2 else [])
    phase_files = [PHASE_FOO_LINE, PHASE_BAR_LINE] + ([PHASE_FOO2_LINE] if models_has_foo2 else [])
    return "\n".join([
        "/* Begin PBXBuildFile section */",
        BF_FOO_LINE,
        BF_BAR_LINE,
    ] + ([BF_FOO2_LINE] if models_has_foo2 else []) + [
        "/* End PBXBuildFile section */",
        "/* Begin PBXFileReference section */",
        REF_FOO_LINE,
        REF_BAR_LINE,
    ] + ([REF_FOO2_LINE] if models_has_foo2 else []) + [
        "/* End PBXFileReference section */",
        "/* Begin PBXGroup section */",
        "\t\t%s /* Kiteloop */ = {" % TARGET_GROUP,
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        "\t\t\t\t%s /* Services */," % SERVICES,
        "\t\t\t\t%s /* Models */," % MODELS,
        "\t\t\t);",
        "\t\t\tpath = Kiteloop;",
        "\t\t\tsourceTree = \"<group>\";",
        "\t\t};",
        "\t\t%s /* Services */ = {" % SERVICES,
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
        GROUP_FOO_LINE,
        GROUP_BAR_LINE,
        "\t\t\t);",
        "\t\t\tpath = Services;",
        "\t\t\tsourceTree = \"<group>\";",
        "\t\t};",
        "\t\t%s /* Models */ = {" % MODELS,
        "\t\t\tisa = PBXGroup;",
        "\t\t\tchildren = (",
    ] + models_children + [
        "\t\t\t);",
        "\t\t\tpath = Models;",
        "\t\t\tsourceTree = \"<group>\";",
        "\t\t};",
        "/* End PBXGroup section */",
        "/* Begin PBXNativeTarget section */",
        "\t\t%s /* Kiteloop */ = {" % NATIVE_TARGET,
        "\t\t\tisa = PBXNativeTarget;",
        "\t\t\tbuildPhases = (",
        "\t\t\t\t%s /* Sources */," % SOURCES_PHASE,
        "\t\t\t);",
        "\t\t\tname = Kiteloop;",
        "\t\t};",
        "/* End PBXNativeTarget section */",
        "/* Begin PBXSourcesBuildPhase section */",
        "\t\t%s /* Sources */ = {" % SOURCES_PHASE,
        "\t\t\tisa = PBXSourcesBuildPhase;",
        "\t\t\tbuildActionMask = 2147483647;",
        "\t\t\tfiles = (",
    ] + phase_files + [
        "\t\t\t);",
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;",
        "\t\t};",
        "/* End PBXSourcesBuildPhase section */",
    ]) + "\n"


FIXTURE = fixture(models_has_foo2=True)

EXPECTED_AFTER = FIXTURE
for line in (BF_FOO_LINE, REF_FOO_LINE, GROUP_FOO_LINE, PHASE_FOO_LINE):
    EXPECTED_AFTER = EXPECTED_AFTER.replace(line + "\n", "", 1)

buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    result = pr.unregister(FIXTURE, "Kiteloop/Kiteloop/Services/Foo.swift")

check("build-file line removed", BF_FOO_LINE not in result, result)
check("file-reference line removed", REF_FOO_LINE not in result, result)
check("group membership line removed", GROUP_FOO_LINE not in result, result)
check("sources-phase membership line removed", PHASE_FOO_LINE not in result, result)
check("Bar.swift's four lines untouched",
      all(line in result for line in (BF_BAR_LINE, REF_BAR_LINE, GROUP_BAR_LINE, PHASE_BAR_LINE)), result)
check("Models' Foo.swift (a different reference, same basename) is untouched",
      all(line in result for line in (BF_FOO2_LINE, REF_FOO2_LINE, GROUP_FOO2_LINE, PHASE_FOO2_LINE)), result)
check("the rest of the text is byte for byte the same", result == EXPECTED_AFTER, result)

buf2 = io.StringIO()
with contextlib.redirect_stdout(buf2):
    result2 = pr.unregister(EXPECTED_AFTER, "Kiteloop/Kiteloop/Services/Foo.swift")

check("text that never mentions the file is returned unchanged", result2 == EXPECTED_AFTER, result2)
check("prints that the file was not registered", "was not registered" in buf2.getvalue(), buf2.getvalue())

REGISTER_BASE = fixture(models_has_foo2=False)
buf3 = io.StringIO()
with contextlib.redirect_stdout(buf3):
    result3 = pr.register(REGISTER_BASE, "Kiteloop/Kiteloop/Models/Foo.swift")

check("registering a basename already used in another group does not print 'already registered'",
      "already registered" not in buf3.getvalue(), buf3.getvalue())
new_ref = pr.ident("Kiteloop/Kiteloop/Models/Foo.swift")
new_bf = pr.ident("Kiteloop/Kiteloop/Models/Foo.swift in Sources")
check("a new file-reference line was added for Models' Foo.swift",
      ("%s /* Foo.swift */ = {isa = PBXFileReference" % new_ref) in result3, result3)
check("a new build-file line was added for Models' Foo.swift",
      ("%s /* Foo.swift in Sources */ = {isa = PBXBuildFile; fileRef = %s" % (new_bf, new_ref)) in result3, result3)
check("Models' group gained a membership line for the new reference",
      ("\t\t\t\t%s /* Foo.swift */," % new_ref) in result3, result3)
check("the Sources phase gained a membership line for the new build file",
      ("\t\t\t\t%s /* Foo.swift in Sources */," % new_bf) in result3, result3)
check("Services' Foo.swift is untouched",
      all(line in result3 for line in (BF_FOO_LINE, REF_FOO_LINE, GROUP_FOO_LINE, PHASE_FOO_LINE)), result3)

buf4 = io.StringIO()
with contextlib.redirect_stdout(buf4):
    result4 = pr.unregister(FIXTURE, "Kiteloop/Kiteloop/Elsewhere/Ghost.swift")

check("a path whose folder the group tree doesn't have is returned unchanged", result4 == FIXTURE, result4)
check("prints that the (unresolved) file was not registered", "was not registered" in buf4.getvalue(), buf4.getvalue())

for path, label in ((os.path.join(HERE, "core-move.py"), "core-move.py"),
                     (os.path.join(HERE, "test-move.py"), "test-move.py")):
    source = open(path).read()
    check("%s no longer carries a file-reference search of its own" % label,
          "isa = PBXFileReference" not in source, source)

print()
if failed:
    print("test-pbx-register: %d case(s) failed." % failed)
    sys.exit(1)
print("test-pbx-register: all cases passed.")
