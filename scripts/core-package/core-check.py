#!/usr/bin/env python3
"""core-check — package test files that reach into the app.

A test moves into KiteloopCore with its subject, and compiles there only if
everything it names is in the package too. Twice in the first day a test went
across naming `BacklogAutopilot` or `ControlRouter`, and `swift test` said so
an hour later, after the build. This says so at the move: every capitalised
identifier (and every top-level function name) in the package's test tree is
resolved against what the app target declares and the package declares, and a
name only the app declares is reported with its file and first line. The
remedy is the operator's — move the test back (`core-move.py` moved it, `git
mv` undoes it, with `@testable import Kiteloop` + `import KiteloopCore`), or
split the one case that reaches across into an app-hosted file beside it —
because which of the two is right is a judgement about what the test is of.

Comments and string literals are stripped first, by parsing the file with
tree-sitter-swift (ast-grep's bundled grammar, via `ast-grep-py`) rather than
guessing where they start and end with a regex — a stripper bug is a missed
or invented finding, and this class of bug has shipped three times (see
quality/STRATEGY.md's roadmap entry). Declarations are read the same way,
structurally: a type is top-level when the tree says its parent is the file,
not when the regex sees no leading whitespace. Exit 1 on any offender.

Needs `ast-grep-py` (`pip3 install --user ast-grep-py`); absent, this fails
naming the install, the way check-complexity.sh does for swiftlint.

  ./scripts/core-package/core-check.py
  ./scripts/core-package/core-check.py --app DIR --package DIR   # the tests use these
"""
import argparse
import os
import re
import sys

sys.dont_write_bytecode = True

try:
    from ast_grep_py import SgRoot
except ImportError:
    SgRoot = None

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, "Kiteloop", "Kiteloop")
PACKAGE = os.path.join(ROOT, "Kiteloop", "KiteloopCore")
TESTS = os.path.join(ROOT, "Kiteloop", "KiteloopTests")

MODS = r"(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|package|final|open|indirect|nonisolated|static|class|mutating|override)\s+)*"
# Top-level declarations only. A nested type is reached through its outer name, which is
# top-level and seen here, and a method through its receiver — while a nested `Thread`
# or a method `map` counted at depth would shadow Foundation's for every package test.
# Kept for test-move.py, which matches its own questions (duplicate test classes, move
# candidates) against these same patterns; core-check's own declared() reads the tree.
TYPE_DECL_RE = re.compile(r"^" + MODS + r"(?:struct|class|enum|actor|protocol|typealias)\s+([A-Za-z_]\w*)", re.M)
FUNC_DECL_RE = re.compile(r"^" + MODS + r"func\s+([A-Za-z_]\w*)", re.M)
LOCAL_DECL_RE = re.compile(r"^[ \t]*" + MODS + r"(?:struct|class|enum|actor|protocol|typealias|func)\s+([A-Za-z_]\w*)", re.M)
IDENT_RE = re.compile(r"\b([A-Z]\w*)\b")
CALL_RE = re.compile(r"(?<![.\w])([a-z]\w*)\(")

# Node kinds whose text is comment or string-literal content, never code — blanked by
# strip() so the regexes above never see inside them. Everything else in the tree,
# including a `\(…)` interpolation's `interpolated_expression` subtree, is real code and
# stays untouched: a reference named only inside a string (single-line, multi-line, raw,
# nested) is still a reference, at whatever depth the grammar finds it.
_BLANK_MARKERS = ("comment", "str_text", "str_part", "str_end_part", "str_escaped_char")
_TOP_LEVEL_TYPE_KEYWORDS = {"struct", "class", "enum", "actor"}


def _sg_root(text):
    if SgRoot is None:
        raise RuntimeError("ast-grep-py is not installed — pip3 install --user ast-grep-py")
    return SgRoot(text, "swift").root()


def strip(text):
    """Blank every comment and string-literal text span the Swift grammar finds, keeping
    every newline so line numbers hold. Structural, not textual: a nested quote, a raw
    string's `#"…"#` escaping, or an interpolation inside a `\"\"\"…\"\"\"` block cannot
    fool it the way they can a regex, because the grammar parses them itself."""
    root = _sg_root(text)
    chars = list(text)

    def blank(node):
        start, end = node.range().start.index, node.range().end.index
        for i in range(start, end):
            if chars[i] != "\n":
                chars[i] = " "

    def walk(node):
        kind = node.kind()
        if kind == "multiline_comment" or any(marker in kind for marker in _BLANK_MARKERS):
            blank(node)
            return
        for child in node.children():
            walk(child)

    walk(root)
    return "".join(chars)


def swift_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ("Frameworks", ".build")]
        for name in sorted(filenames):
            if name.endswith(".swift"):
                yield os.path.join(dirpath, name)


def _type_decl_name(node):
    """None for anything that isn't struct/class/enum/actor — an `extension` reuses the
    same node kind in this grammar but declares nothing, the way TYPE_DECL_RE's keyword
    alternation already excludes it; a leading `modifiers`/`attribute` child means the
    keyword itself isn't node.children()[0], so it's found by kind, not position."""
    for child in node.children():
        kind = child.kind()
        if kind in _TOP_LEVEL_TYPE_KEYWORDS:
            name = node.field("name")
            return name.text() if name else None
        if kind == "extension":
            return None
    return None


_TOP_LEVEL_DECL_KINDS = {"class_declaration", "protocol_declaration", "typealias_declaration", "function_declaration"}


def declared(root):
    """Every top-level type and function name a tree in root declares — top-level meaning
    the declaration node's own parent is the file, read from the parse tree directly
    rather than approximated by a regex requiring no leading whitespace on its line. One
    walk per file, not one `find_all` per declaration kind: the tree is the same size
    either way, and a source file this size is walked in one pass in every other check
    here — four passes bought nothing but four times the node visits."""
    names = set()
    for path in swift_files(root):
        with open(path, errors="replace") as handle:
            tree = _sg_root(handle.read())
        for node in tree.children():
            kind = node.kind()
            if kind not in _TOP_LEVEL_DECL_KINDS:
                continue
            name = _type_decl_name(node) if kind == "class_declaration" else node.field("name")
            name = name if isinstance(name, str) else (name.text() if name else None)
            if name:
                names.add(name)
    return names


def app_only_names(app, package, tests=None):
    """Names a package test cannot use: everything the app declares, plus everything the
    app-hosted test target declares (support helpers, fixtures) — minus what the package
    and its own tests declare."""
    app_side = declared(app) | (declared(tests) if tests else set())
    return app_side - declared(os.path.join(package, "Sources")) - declared(os.path.join(package, "Tests"))


def offenders(app, package, tests=None):
    """[(relative test path, name, line)] for every app-side name a package test uses —
    declared by the app, or by the app-hosted test target's support helpers, and not by
    the package or its own tests."""
    app_only = app_only_names(app, package, tests)
    found = []
    for path in swift_files(os.path.join(package, "Tests")):
        with open(path, errors="replace") as handle:
            code = strip(handle.read())
        # a name the file declares itself, at any depth — its own helper method, a
        # fixture type — resolves here before anything the app has by that name
        local = set(LOCAL_DECL_RE.findall(code))
        seen = set(local)
        for number, line in enumerate(code.split("\n"), 1):
            for name in IDENT_RE.findall(line) + CALL_RE.findall(line):
                if name in app_only and name not in seen:
                    seen.add(name)
                    found.append((os.path.relpath(path, package), name, number))
    return found


def main():
    parser = argparse.ArgumentParser(description="package test files that name an app-only type or function")
    parser.add_argument("--app", default=APP)
    parser.add_argument("--package", default=PACKAGE)
    parser.add_argument("--tests", default=TESTS, help="the app-hosted test target, whose support helpers are app-side too")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    if SgRoot is None:
        print("FAIL: ast-grep-py is not installed, so core-check cannot parse Swift — pip3 install --user ast-grep-py", file=sys.stderr)
        return 1
    found = offenders(os.path.abspath(args.app), os.path.abspath(args.package), os.path.abspath(args.tests))
    if found:
        by_file = {}
        for path, name, line in found:
            by_file.setdefault(path, []).append("%s (line %d)" % (name, line))
        print("FAIL: %d package test file(s) name something only the app declares — they will not compile in the package:" % len(by_file))
        for path, names in by_file.items():
            print("  %s: %s" % (path, ", ".join(names)))
        print("Move the test back to KiteloopTests (git mv, @testable import Kiteloop + import KiteloopCore), or split the case that reaches across into an app-hosted file beside it.")
        return 1
    if not args.quiet:
        print("OK: no package test names anything only the app declares")
    return 0


if __name__ == "__main__":
    sys.exit(main())
