#!/usr/bin/env python3
"""Register a QA flow in the KiteloopUITests target.

    ./scripts/qa/register-ui-flow.py Kiteloop/KiteloopUITests/QA/<id>.swift

A .swift file missing from project.pbxproj is in no target, so it compiles
nowhere and its test never runs — silently. This adds the file reference, the
build file, the KiteloopUITests group child and the Sources-phase entry, cloned
from the target's own KiteloopUITests.swift. Running it twice changes nothing.
Then: ./scripts/check-target-membership.py
"""
import re
import secrets
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PBX = ROOT / "Kiteloop/Kiteloop.xcodeproj/project.pbxproj"
GROUP_DIR = "Kiteloop/KiteloopUITests/"
SIBLING = "KiteloopUITests.swift"


def fresh_id(text: str) -> str:
    """A 24-hex-digit object id the project does not use yet."""
    while True:
        candidate = secrets.token_hex(12).upper()
        if candidate not in text:
            return candidate


def sibling_entries(text: str):
    """The sibling's file-reference and build-file lines, or None when either is missing."""
    ref = re.search(r"\t\t([0-9A-F]{24}) /\* " + re.escape(SIBLING) + r" \*/ = \{isa = PBXFileReference;[^\n]*\n", text)
    build = re.search(r"\t\t([0-9A-F]{24}) /\* " + re.escape(SIBLING) + r" in Sources \*/ = \{isa = PBXBuildFile;[^\n]*\n", text)
    return (ref, build) if ref and build else None


def register(text: str, relative: str, name: str) -> str:
    """`text` with `relative` registered beside the sibling, or raises ValueError saying why it cannot be."""
    entries = sibling_entries(text)
    if entries is None:
        raise ValueError(f"{SIBLING}'s entries were not found")
    ref, build = entries
    ref_id, build_id, new_ref, new_build = ref.group(1), build.group(1), fresh_id(text), fresh_id(text)
    ref_line = ref.group(0).replace(ref_id, new_ref).replace(f"/* {SIBLING} */", f"/* {name} */")
    ref_line = re.sub(r"path = [^;]+;", f'path = "{relative}";', ref_line)
    build_line = build.group(0).replace(build_id, new_build).replace(ref_id, new_ref).replace(SIBLING, name)
    text = text.replace(ref.group(0), ref.group(0) + ref_line, 1)
    text = text.replace(build.group(0), build.group(0) + build_line, 1)
    for old, new in ((f"\t\t\t\t{ref_id} /* {SIBLING} */,\n", f"\t\t\t\t{new_ref} /* {name} */,\n"),
                     (f"\t\t\t\t{build_id} /* {SIBLING} in Sources */,\n", f"\t\t\t\t{new_build} /* {name} in Sources */,\n")):
        if text.count(old) != 1:
            raise ValueError(f"{SIBLING}'s group or Sources entry is not unique")
        text = text.replace(old, old + new, 1)
    return text


def main(path: str) -> int:
    if not path.startswith(GROUP_DIR) or not path.endswith(".swift"):
        print(f"register-ui-flow: {path} is not a .swift file under {GROUP_DIR}", file=sys.stderr)
        return 2
    relative, name = path[len(GROUP_DIR):], Path(path).name
    text = PBX.read_text()
    if f"path = {relative};" in text or f'path = "{relative}";' in text:
        print(f"register-ui-flow: {relative} is already registered")
        return 0
    try:
        PBX.write_text(register(text, relative, name))
    except ValueError as reason:
        print(f"register-ui-flow: {reason}", file=sys.stderr)
        return 1
    print(f"register-ui-flow: registered {relative} in KiteloopUITests")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]) if len(sys.argv) == 2 else 2)
