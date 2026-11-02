#!/usr/bin/env python3
"""Move app-hosted test files into the package, where they run under `swift test`.

A test of package code that references nothing app-side — nothing
core-check.py's `app_only_names` would refuse it for once moved — is hosted by
Kiteloop.app for no reason: it cannot run while the app is up, and the CRAP
gate reads the package function it covers as untested. With no arguments this
lists those files, the way core-pick.py lists sources; with paths it moves
them: `git mv` to the package's test tree under the same first folder
(`Models/`, `Services/`, `Runtime/` — the package's tests carry no deeper
split), `@testable import Kiteloop` → `@testable import KiteloopCore`, the
pbxproj entry removed, the citation in docs/features.md rewritten, and
core-check.py run last.

A file split down the middle — a test class declared in both trees, each half
carrying its own subset of cases — is invisible to `candidates()`: neither
copy is whole, so neither is offered. `--duplicates` names every class
declared in both trees and the `func test` names each side carries, so that
split can be checked rather than trusted. It only reports; a class named on
both sides is not necessarily wrong, and a case name repeated on both sides is
flagged but not refused.

    scripts/core-package/test-move.py                      # the candidates
    scripts/core-package/test-move.py --duplicates          # classes declared in both trees
    scripts/core-package/test-move.py Services/Backlog/BacklogRoundTripTests.swift ...
"""
import importlib.util, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
R = os.path.join(ROOT, 'Kiteloop')
APP = os.path.join(R, 'Kiteloop'); TESTS = os.path.join(R, 'KiteloopTests'); PKG = os.path.join(R, 'KiteloopCore')
PBX = os.path.join(R, 'Kiteloop.xcodeproj', 'project.pbxproj')
FEATURES = os.path.join(ROOT, 'docs', 'features.md')

spec = importlib.util.spec_from_file_location('core_check', os.path.join(HERE, 'core-check.py'))
cc = importlib.util.module_from_spec(spec); spec.loader.exec_module(cc)

pr_spec = importlib.util.spec_from_file_location('pbx_register', os.path.join(HERE, 'pbx-register.py'))
pr = importlib.util.module_from_spec(pr_spec); pr_spec.loader.exec_module(pr)

def read(p):
    with open(p, errors='replace') as h: return h.read()
def write(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'w') as h: h.write(s)

def candidates():
    app_only = cc.app_only_names(APP, PKG, TESTS); out = []
    for f in sorted(cc.swift_files(TESTS)):
        if os.sep + 'Support' + os.sep in f: continue
        code = cc.strip(read(f))
        local = set(cc.LOCAL_DECL_RE.findall(code))
        names = (set(cc.IDENT_RE.findall(code)) | set(cc.CALL_RE.findall(code))) - local
        if not names & app_only and code.count('func test'):
            out.append((os.path.relpath(f, TESTS), code.count('func test')))
    return out

FUNC_TEST_RE = re.compile(r'^[ \t]*' + cc.MODS + r'func\s+(test\w*)\s*\(', re.M)

def _test_classes(root):
    """{class name: (file relative to root, sorted func-test names)} for every
    top-level class in root's swift files — one entry per class, keyed by
    name, so a class present under two roots collides and can be compared."""
    classes = {}
    for path in cc.swift_files(root):
        code = cc.strip(read(path))
        types = list(cc.TYPE_DECL_RE.finditer(code))
        funcs = list(FUNC_TEST_RE.finditer(code))
        for i, m in enumerate(types):
            start = m.end()
            end = types[i + 1].start() if i + 1 < len(types) else len(code)
            names = sorted(f.group(1) for f in funcs if start <= f.start() < end)
            if names:
                classes[m.group(1)] = (os.path.relpath(path, root), names)
    return classes

def duplicate_classes():
    """[(class name, (app file, app test names), (package file, package test
    names))] for every test class declared in both trees — the blind spot
    `candidates()` cannot see, because a class split down the middle names no
    file wholly app-side or wholly of package-only code."""
    app_classes = _test_classes(TESTS)
    pkg_classes = _test_classes(os.path.join(PKG, 'Tests', 'KiteloopCoreTests'))
    return [(name, app_classes[name], pkg_classes[name])
            for name in sorted(set(app_classes) & set(pkg_classes))]

def destination(rel):
    """Where rel (a KiteloopTests-relative path) lands under the package's
    Tests/KiteloopCoreTests, and how its docs/features.md citation should
    read once it's there. A path with a folder keeps its first folder — the
    package tests tree's one level of split; a path with none (the four
    files that sit at the root of Kiteloop/KiteloopTests) lands directly in
    the tests root, cited by its bare basename, never by a folder named
    after a .swift file."""
    parts = rel.split(os.sep); name = parts[-1]
    if len(parts) > 1:
        return os.path.join(PKG, 'Tests', 'KiteloopCoreTests', parts[0], name), parts[0] + '/' + name
    return os.path.join(PKG, 'Tests', 'KiteloopCoreTests', name), name

def move(rel):
    src = os.path.join(TESTS, rel)
    assert os.path.isfile(src), rel
    dst, cite = destination(rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    subprocess.run(['git', 'mv', src, dst], check=True, cwd=ROOT)
    text = read(dst).replace('@testable import Kiteloop\n', '@testable import KiteloopCore\n')
    if re.search(r'^@testable import KiteloopCore$', text, re.M):
        text = re.sub(r'^import KiteloopCore\n', '', text, flags=re.M)
    elif not re.search(r'^import KiteloopCore$', text, re.M):
        text = re.sub(r'^(import XCTest\n)', r'\1import KiteloopCore\n', text, count=1, flags=re.M)
    write(dst, text)
    write(PBX, pr.unregister(read(PBX), os.path.relpath(src, ROOT)))
    old_cite = '`' + rel + '`'; new_cite = '`' + cite + '`'
    if os.path.exists(FEATURES) and old_cite in read(FEATURES):
        write(FEATURES, read(FEATURES).replace(old_cite, new_cite)); print(f'  features.md: {old_cite} -> {new_cite}')
    print(f'moved {rel} -> Tests/KiteloopCoreTests/{cite}')

def print_duplicates():
    dups = duplicate_classes()
    print(f'# {len(dups)} test class(es) declared in both trees')
    for name, (app_file, app_names), (pkg_file, pkg_names) in dups:
        overlap = sorted(set(app_names) & set(pkg_names))
        print(f'{name}  (KiteloopTests/{app_file} vs KiteloopCoreTests/{pkg_file})')
        print(f'  app:      {", ".join(app_names)}')
        print(f'  package:  {", ".join(pkg_names)}')
        if overlap:
            print(f'  ! same case name(s) asserted on both sides: {", ".join(overlap)}')

def main():
    if len(sys.argv) == 1:
        cands = candidates()
        print(f'# {len(cands)} app-hosted test files reference nothing app-side ({sum(n for _, n in cands)} tests)')
        for rel, n in cands: print(f'{n:4d}  {rel}')
        return 0
    if sys.argv[1] == '--duplicates':
        print_duplicates()
        return 0
    for a in sys.argv[1:]:
        move(os.path.relpath(os.path.abspath(a), TESTS) if os.path.isabs(a) or a.startswith('Kiteloop') else a)
    print()
    return subprocess.run([sys.executable, os.path.join(HERE, 'core-check.py')]).returncode

if __name__ == '__main__':
    sys.exit(main())
