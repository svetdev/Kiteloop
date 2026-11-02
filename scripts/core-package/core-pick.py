#!/usr/bin/env python3
"""core-pick — which app files could move into KiteloopCore next.

A file can move when every type it references is already in the package or in
the file itself; this reads the app target and the package, resolves each
capitalised identifier in code (comments and strings stripped) to the file
that declares it, and prints the candidates with their fan-in — how many app
files name them, which is how many `import KiteloopCore` lines a move costs —
and their length. Files importing a UI framework are never candidates.

  ./scripts/core-package/core-pick.py        # every candidate
  ./scripts/core-package/core-pick.py 20     # the twenty with the least fan-in
  ./scripts/core-package/core-pick.py --blockers [N]   # the N files holding the most others out
  ./scripts/core-package/core-pick.py --why Models/KiteloopProject   # what holds one file out
  ./scripts/core-package/core-pick.py --app DIR --package DIR   # a test drives it over a fixture tree

The move itself is `core-move.py`; the inits it needs are `core-inits.py`.
"""
import collections
import os
import re
import sys

R = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), 'Kiteloop')
APP = R + '/Kiteloop'; PKG = R + '/KiteloopCore/Sources/KiteloopCore'
UI = {'SwiftUI', 'AppKit', 'Cocoa', 'WebKit', 'UserNotifications', 'Quartz', 'AVFoundation', 'CoreImage'}


def keep_interpolations(text):
    """Every string literal becomes `""` — but the code inside its `\\(…)` interpolations
    is kept beside it, since `"\\(WorktreeSession.begin)"` is a reference like any other."""
    out = []; i = 0; n = len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            if text.startswith('"""', i):
                j = text.find('"""', i + 3); j = n if j < 0 else j + 3
            else:
                j = i + 1
                while j < n and text[j] != '"' and text[j] != '\n':
                    j += 2 if text[j] == '\\' else 1
                j = min(j + 1, n)
            literal = text[i:j]; parts = []
            k = 0
            while True:
                k = literal.find('\\(', k)
                if k < 0: break
                depth = 0; m = k + 1
                while m < len(literal):
                    if literal[m] == '(': depth += 1
                    elif literal[m] == ')':
                        depth -= 1
                        if depth == 0: break
                    m += 1
                parts.append(literal[k + 2:m]); k = m + 1
            out.append('""' + ''.join(' (' + p + ')' for p in parts))
            i = j
        else:
            out.append(ch); i += 1
    return ''.join(out)


def strip(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S); s = re.sub(r'//[^\n]*', '', s)
    return keep_interpolations(s)


decl = re.compile(r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|package|final|open|indirect|nonisolated)\s+)*(?:struct|class|enum|actor|protocol|typealias)\s+([A-Z]\w*)', re.M)
ident = re.compile(r'\b([A-Z][A-Za-z0-9_]*)\b'); imp = re.compile(r'^import\s+(\w+)', re.M)


def files(d):
    return [os.path.join(dp, f) for dp, _, fs in os.walk(d) if 'Frameworks' not in dp for f in fs if f.endswith('.swift')]


def scan(app_dir, pkg_dir):
    """Walks app_dir and pkg_dir and resolves every reference: (app files, package
    files, raw source by path, each app file's dependency set, the set of package
    paths, and each dependency's fan-in across the app)."""
    app = files(app_dir); pkg = files(pkg_dir)
    raw = {f: open(f, errors='replace').read() for f in app + pkg}
    src = {f: strip(raw[f]) for f in app + pkg}
    owner = {}
    for f in app + pkg:
        for d in decl.findall(src[f]): owner.setdefault(d, f)
    inpkg = set(pkg)
    dep = {f: {owner[i] for i in set(ident.findall(src[f])) if i in owner and owner[i] != f} for f in app}
    fanin = collections.Counter(d for f in app for d in dep[f])
    return app, pkg, raw, dep, inpkg, fanin


def candidates(app_dir, app, raw, dep, inpkg, fanin):
    cands = []
    for f in app:
        if set(imp.findall(raw[f])) & UI: continue
        if all(d in inpkg for d in dep[f]):
            cands.append((fanin[f], len(raw[f].split('\n')), os.path.relpath(f, app_dir)))
    cands.sort()
    return cands


def why(app_dir, specs, raw, dep, inpkg):
    """Why each spec cannot move: the app files it depends on that are not in the package."""
    lines = []
    for spec in specs:
        f = os.path.join(app_dir, spec if spec.endswith('.swift') else spec + '.swift')
        ui = set(imp.findall(raw.get(f, ''))) & UI
        outside = sorted(os.path.relpath(d, app_dir) for d in dep.get(f, ()) if d not in inpkg)
        lines.append(f"{spec}: {'imports ' + ', '.join(sorted(ui)) + '; ' if ui else ''}{len(outside)} app dependencies" + (': ' + ', '.join(outside) if outside else ''))
    return lines


def blockers(app_dir, app, raw, dep, inpkg, limit):
    """What holds the rest out: for every app file that imports no UI framework and is
    not a candidate, the app files it depends on that are not in the package; the
    files blocking the most others are the next inversions, not the next moves."""
    blocking = collections.Counter(); held = collections.defaultdict(set)
    for f in app:
        if set(imp.findall(raw[f])) & UI: continue
        outside = {d for d in dep[f] if d not in inpkg}
        if not outside: continue
        for d in outside: blocking[d] += 1; held[d].add(os.path.relpath(f, app_dir))
    lines = []
    for d, n in blocking.most_common(limit):
        ui = ' (imports UI)' if set(imp.findall(raw[d])) & UI else ''
        lines.append(f"{n:3d}  {os.path.relpath(d, app_dir)}{ui}")
    return lines


def main(argv):
    argv = list(argv)
    app_dir, pkg_dir = APP, PKG
    if '--app' in argv:
        i = argv.index('--app'); app_dir = argv[i + 1]; del argv[i:i + 2]
    if '--package' in argv:
        i = argv.index('--package'); pkg_dir = argv[i + 1]; del argv[i:i + 2]
    app, pkg, raw, dep, inpkg, fanin = scan(app_dir, pkg_dir)
    if '--why' in argv:
        for line in why(app_dir, argv[argv.index('--why') + 1:], raw, dep, inpkg):
            print(line)
        return 0
    if '--blockers' in argv:
        limit = int(argv[1]) if len(argv) > 1 else 20
        for line in blockers(app_dir, app, raw, dep, inpkg, limit):
            print(line)
        return 0
    limit = int(argv[0]) if argv else 999
    cands = candidates(app_dir, app, raw, dep, inpkg, fanin)
    for fi, ln, p in cands[:limit]: print(f"{fi:3d} {ln:5d}  {p}")
    print(f"# {len(cands)} candidates now; {len(pkg)} files in the package", file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
