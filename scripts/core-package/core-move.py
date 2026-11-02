#!/usr/bin/env python3
"""core-move — move app files into KiteloopCore with package access.

For each path given (under Kiteloop/Kiteloop, without `.swift`): `git mv` the
file into the package under the same subdirectory; mark every declaration at
type scope `package` (a scope stack tells a type body from a function body, so
a local `let` is never touched); move its `<Name>Tests.swift` from wherever the
subsystem split put it into the package's tests with `@testable import
KiteloopCore`; unregister both from the pbxproj; and add `import KiteloopCore`
to every app and test file that names a moved type. It ends by running
`core-check.py`, which names any moved test that reaches into the app — the
one thing the compiler used to discover an hour later — so the operator moves
it back or splits it before building. Then `core-inits.py` for the memberwise
inits, build, and read the compiler for the rest.

Refuses, before the first `git mv`, when given no paths at all, when
`swiftlint` is not on PATH (it rewrites the complexity baseline at the end,
and an absent swiftlint should not be discovered after every file has
already moved), or when a given path's declarations the type regex does not
recognise (it only sees `final`/`indirect` in front of
struct/class/enum/actor/protocol/typealias — a same-line attribute or an
explicit `public`/`package` reads as no type) — the last of these because an
empty set of "moved types" would otherwise match every word boundary and
rewrite every app and test file with a needless import. The baseline
rewrite itself can still fail after the move (swiftlint exits non-zero): that
prints swiftlint's stderr and exits non-zero rather than the misleading
"entries (must be equal)" line.

  ./scripts/core-package/core-move.py Services/Foo Models/Bar
"""
import importlib.util, json, os, re, shutil, sys, subprocess
ROOT=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); R=ROOT+'/Kiteloop'
APP=R+'/Kiteloop'; TESTS=R+'/KiteloopTests'; PKG=R+'/KiteloopCore'; PBX=R+'/Kiteloop.xcodeproj/project.pbxproj'

_spec=importlib.util.spec_from_file_location('pbx_register', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pbx-register.py'))
pr=importlib.util.module_from_spec(_spec); _spec.loader.exec_module(pr)

def read(p): return open(p).read()
def write(p,s): os.makedirs(os.path.dirname(p),exist_ok=True); open(p,'w').write(s)
def git(*a):
    if a[0]=='mv': os.makedirs(os.path.dirname(a[2]),exist_ok=True)
    subprocess.run(['git',*a],check=True,cwd=ROOT)

TYPE_RE=re.compile(r'^(\s*)((?:@\w+(?:\([^)]*\))?\s+)*)((?:(?:final|indirect)\s+)*)(struct|class|enum|actor|protocol|extension)\s+([A-Z]\w*)')
MEMBER_RE=re.compile(r'^(\s*)((?:@\w+(?:\([^)]*\))?\s+)*)((?:(?:static|mutating|nonisolated|final|override|required|convenience|lazy|weak|unowned|class|indirect|(?:file)?private\(set\))\s+)*)(func|var|let|init|typealias|subscript|struct|class|enum|actor|protocol)\b')
ACCESS=('public ','package ','private ','fileprivate ','internal ','open ')
def brace_delta(line):
    code=re.sub(r'"(?:\\.|[^"\\])*"','""',line); code=re.sub(r'//.*','',code)
    return code.count('{')-code.count('}')
def annotate(text):
    out=[]; stack=[]   # entries: 'type' | 'protocol' | 'code'
    for line in text.split('\n'):
        stripped=line.lstrip()
        top=stack[-1] if stack else 'file'
        new=line
        if top in ('file','type') and stripped and not stripped.startswith(('//','/*','*','case ','#')):
            m=MEMBER_RE.match(line)
            # `private(set)` is a setter restriction, not the member's access: a
            # `private(set) var` is internal and needs `package` in front of it
            setter_free=lambda t: re.sub(r'\b(file)?private\(set\)\s*','',t)
            if m and not any(a in setter_free(m.group(2)+m.group(3)+' ') or stripped.startswith(a) for a in ACCESS) and 'private' not in setter_free(m.group(2)+m.group(3)):
                indent,attrs,mods,kw=m.group(1),m.group(2),m.group(3),m.group(4)
                if stripped.startswith('internal '): new=line.replace('internal ','package ',1)
                elif not re.search(r'\b(public|package|private|fileprivate|open)\b', setter_free(line[:m.end()])):
                    new=indent+attrs+'package '+line[len(indent)+len(attrs):]
        t=TYPE_RE.match(line)
        d=brace_delta(line)
        kind='code'
        if t: kind='protocol' if t.group(4)=='protocol' else 'type'
        elif top in ('file','type') and MEMBER_RE.match(line): kind='code'
        if d>0: stack.extend([kind]+['code']*(d-1))
        elif d<0:
            for _ in range(-d):
                if stack: stack.pop()
        out.append(new)
    return '\n'.join(out)

# the "moved types" regex: final/indirect only, nothing else in front of the
# keyword — a same-line attribute or an explicit access modifier declares
# nothing as far as this is concerned, and that's the refusal's trigger
DECL_RE=re.compile(r'^(?:(?:final|indirect)\s+)*(?:struct|class|enum|actor|protocol|typealias)\s+([A-Z]\w*)', re.M)
def declared_types(text):
    return set(DECL_RE.findall(text))

def strip_comments(s):
    return re.sub(r'//[^\n]*','',re.sub(r'/\*.*?\*/','',s,flags=re.S))

def files_needing_import(type_names, roots):
    """The .swift files under roots that name one of type_names outside a
    comment and don't already `import KiteloopCore` — the files core-move
    rewrites. An empty type_names returns no files: the caller must not build
    an empty alternation and hand it to re.compile, which matches everywhere."""
    if not type_names: return []
    pat=re.compile(r'\b('+'|'.join(sorted(type_names))+r')\b')
    out=[]
    for base in roots:
        for root,_,files in os.walk(base):
            for f in files:
                if not f.endswith('.swift'): continue
                p=os.path.join(root,f); s=read(p)
                if pat.search(strip_comments(s)) and 'import KiteloopCore' not in s:
                    out.append(p)
    return out

def prune_layering_exemptions(cfg, moved_specs):
    """The layering.roots exemptions the move made dead: only under the app
    root, since that's the root files move out of, not into, an entry naming
    a file this run moved out of it. A moved type's exemption still names a
    real reference — the declaration relocated, the reference and the reason
    someone wrote down for it did not — so it is left in place, in every
    root. Mutates cfg's roots in place and returns (cfg, how many entries
    were dropped)."""
    roots = cfg.get('layering', {}).get('roots', [])
    moved_files = {f'{spec}.swift' for spec in moved_specs}
    app_root = os.path.relpath(APP, ROOT)
    dropped = 0
    for root in roots:
        exempt = root.get('exempt', [])
        dead_files = moved_files if root.get('root') == app_root else set()
        kept = [e for e in exempt if e['file'] not in dead_files]
        dropped += len(exempt) - len(kept)
        root['exempt'] = kept
    return cfg, dropped

def rewrite_complexity_baseline(bl, cwd):
    """Rewrite `bl` (the swiftlint complexity baseline) for paths files just
    moved to, by re-running swiftlint's own `--write-baseline` over the new
    tree from `cwd`. The baseline is keyed by path, so a straight move makes
    its entries stop matching and the gate would fail on violations nobody
    introduced; a correct rewrite holds the same count under the new paths.
    Returns True and prints the before/after count on success. Returns False
    and prints swiftlint's stderr without touching `bl` further when swiftlint
    exits non-zero — the caller must not read the unchanged-count line as a
    rewrite that ran."""
    count=lambda: len(json.load(open(bl)))   # a list of violations
    before=count()
    result=subprocess.run(['swiftlint','lint','--quiet','--config','.swiftlint.yml','--write-baseline','.swiftlint-baseline.json','Kiteloop','KiteloopCore/Sources'], cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr, end="")
        print(f"core-move: swiftlint exited {result.returncode} rewriting the complexity baseline", file=sys.stderr)
        return False
    print(f"complexity baseline rewritten for the new paths: {before} -> {count()} entries (must be equal)")
    return True

def main(argv):
    if not argv:
        print("core-move: no paths given — nothing to move", file=sys.stderr); return 1
    if not shutil.which('swiftlint'):
        print("core-move: swiftlint not found on PATH — refusing before any git mv", file=sys.stderr); return 1
    sources={}
    for spec in argv:
        src=f'{APP}/{spec}.swift'
        text=read(src)
        if not declared_types(text):
            print(f"core-move: {spec}.swift — the type regex found no declaration in it, refusing before any git mv", file=sys.stderr)
            return 1
        sources[spec]=text

    moved_types=set(); users_needing_import=set()
    for spec in argv:
        src=f'{APP}/{spec}.swift'; sub=os.path.dirname(spec); name=os.path.basename(spec)
        dst=f'{PKG}/Sources/KiteloopCore/{sub}/{name}.swift'
        text=sources[spec]
        types=declared_types(text)
        moved_types|=types
        # a file created moments ago (an extraction) may not be tracked yet; mv needs it to be
        git('add', src)
        git('mv',src,dst); write(dst, annotate(text)); print(f"moved {spec} ({', '.join(sorted(types))})")
        # its tests, wherever the split put them
        for root,_,files in os.walk(TESTS):
            for f in files:
                if f==f'{name}Tests.swift':
                    tsrc=os.path.join(root,f); tdst=f'{PKG}/Tests/KiteloopCoreTests/{sub}/{f}'
                    git('mv',tsrc,tdst); write(tdst, read(tdst).replace('@testable import Kiteloop\n','@testable import KiteloopCore\n'))
                    print(f"  test -> {os.path.relpath(tdst,R)}")
                    # docs/features.md cites the test by its path under the test target; the
                    # package's tests have no such subfolders, so the citation follows the file
                    fm=os.path.join(R,'..','docs','features.md'); old_cite='`'+os.path.relpath(tsrc,TESTS)+'`'; new_cite='`'+f'{sub}/{f}'+'`'
                    if os.path.exists(fm) and old_cite in read(fm):
                        write(fm, read(fm).replace(old_cite,new_cite)); print(f"  features.md: {old_cite} -> {new_cite}")
                    # pbxproj unregister (the test)
                    write(PBX, pr.unregister(read(PBX), os.path.relpath(tsrc, ROOT)))
        # pbxproj unregister (the source)
        write(PBX, pr.unregister(read(PBX), os.path.relpath(src, ROOT)))

    # a layering exemption naming a moved type still names a real reference —
    # only the declaration moved — so it stays; a layering exemption whose
    # referencing file this run moved out of the app root is dead there
    qj=os.path.join(R,'..','quality.json')
    if os.path.exists(qj):
        cfg, dropped = prune_layering_exemptions(json.load(open(qj)), argv)
        if dropped:
            with open(qj,'w') as fh: json.dump(cfg,fh,indent=2); fh.write('\n')
            print(f"layering exemptions dropped for moved references: {dropped}")

    # every app and test file that names a moved type imports the package
    for p in files_needing_import(moved_types, (APP,TESTS)):
        s=read(p)
        # before the first import, whichever module it names — not every file starts with Foundation
        s=re.sub(r'^(import \w+\n)', lambda m: 'import KiteloopCore\n'+m.group(1), s, count=1, flags=re.M)
        if 'import KiteloopCore' not in s: s='import KiteloopCore\n'+s
        write(p,s); users_needing_import.add(os.path.relpath(p,R))
    print("imports added in:", len(users_needing_import))

    # The check that used to arrive an hour later, at swift test: a test that
    # moved with its subject but names something only the app declares. Reported
    # now, before any build, so the operator moves it back or splits it first.
    # The complexity baseline is keyed by path, so the moved files' pre-existing
    # entries stop matching at the new path and the gate would fail on violations
    # nobody introduced. Rewrite it: same violations, new paths — the count must
    # not move, and the operator reads that line.
    bl=os.path.join(R,'.swiftlint-baseline.json')
    if not rewrite_complexity_baseline(bl, R):
        return 1
    # The CRAP baseline is keyed by path too; its entries are rekeyed in place —
    # a rewrite would re-measure, and this is a move, not a measurement.
    cb=os.path.join(R,'.crap-baseline.json')
    if os.path.exists(cb):
        entries=json.load(open(cb)); rekeyed=0
        for e in entries:
            new=e['file'].replace('Kiteloop/Kiteloop/','Kiteloop/KiteloopCore/Sources/KiteloopCore/',1)
            if not os.path.exists(os.path.join(R,'..',e['file'])) and os.path.exists(os.path.join(R,'..',new)):
                e['file']=new; rekeyed+=1
                # and the declaration the entry is keyed by gained `package` at the move
                lines={l.strip() for l in read(os.path.join(R,'..',new)).split('\n')}
                if e['text'] not in lines and 'package '+e['text'] in lines: e['text']='package '+e['text']
        with open(cb,'w') as fh: json.dump(entries,fh,indent=1); fh.write('\n')
        print(f"CRAP baseline rekeyed for the new paths: {rekeyed} entries")
    check = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'core-check.py')
    print()
    return subprocess.run([sys.executable, check]).returncode

if __name__=='__main__':
    sys.exit(main(sys.argv[1:]))
