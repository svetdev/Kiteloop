#!/usr/bin/env python3
"""Register a .swift file under Kiteloop/KiteloopTests (or Kiteloop/Kiteloop) in the pbxproj.

The counterpart of what core-move.py does when it takes a file out: a file
reference in the group matching the file's folder, and a build file in the
Sources phase of the target that folder belongs to. For the test that had to
come back, or the app-hosted half of a split one, after a move.

    scripts/core-package/pbx-register.py Kiteloop/KiteloopTests/Services/Autopilot/FooTests.swift ...
"""
import hashlib, os, re, sys

R=os.path.abspath(os.path.join(os.path.dirname(__file__),'..','..'))
PBX=os.path.join(R,'Kiteloop','Kiteloop.xcodeproj','project.pbxproj')
TARGETS={'Kiteloop':'Kiteloop','KiteloopTests':'KiteloopTests'}

def ident(seed):
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()

def groups(s):
    out={}
    for m in re.finditer(r'\t\t([0-9A-F]{24}) /\* [^*]* \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n(.*?)\t\t\t\);\n(?:\t\t\t(?:name|path) = ([^;]*);\n)?', s, re.S):
        kids=re.findall(r'([0-9A-F]{24}) /\*', m.group(2))
        out[m.group(1)]=(kids, (m.group(3) or '').strip('"'), m.start(), m.end(), m.group(2))
    return out

def group_for(g, rel):
    """The group a repo-relative path under Kiteloop/<target>/... belongs to: the
    top-level group whose path is the target folder, then down the folders.
    None if any step of that walk finds nothing — an unknown target, or a
    folder the group tree doesn't have."""
    parts=rel.split('/')
    if len(parts)<3 or parts[0]!='Kiteloop' or parts[1] not in TARGETS: return None
    cur=next((i for i,v in g.items() if v[1]==parts[1]), None)
    for folder in parts[2:-1]:
        if cur is None: return None
        cur=next((k for k in g[cur][0] if k in g and g[k][1]==folder), None)
    return cur

def ref_in_group(g, cur, name):
    """The file-reference id name is registered under in group cur, or None —
    cur may itself be None (path resolved to no group)."""
    if cur is None: return None
    m=re.search(r'([0-9A-F]{24}) /\* '+re.escape(name)+r' \*/,\n', g[cur][4])
    return m.group(1) if m else None

def register(s, rel):
    parts=rel.split('/')
    assert parts[0]=='Kiteloop' and parts[1] in TARGETS, rel
    target=TARGETS[parts[1]]; name=parts[-1]
    g=groups(s)
    cur=group_for(g, rel)
    assert cur is not None, rel
    if ref_in_group(g, cur, name):
        print(f"already registered: {rel}"); return s
    ref=ident(rel); bf=ident(rel+' in Sources')
    s=s.replace('/* End PBXBuildFile section */', f'\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n/* End PBXBuildFile section */',1)
    s=s.replace('/* End PBXFileReference section */', f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */',1)
    s=re.sub(r'(\t\t'+cur+r' /\* [^*]* \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)', lambda m: m.group(1)+f'\t\t\t\t{ref} /* {name} */,\n', s, count=1)
    tid=re.search(r'\t\t([0-9A-F]{24}) /\* '+target+r' \*/ = \{\n\t\t\tisa = PBXNativeTarget;', s).group(1)
    tblock=s[s.index(f'\t\t{tid} /* {target} */ = {{'):]
    phase=re.search(r'([0-9A-F]{24}) /\* Sources \*/', tblock).group(1)
    s=re.sub(r'(\t\t'+phase+r' /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = [^\n]*\n\t\t\tfiles = \(\n)', lambda m: m.group(1)+f'\t\t\t\t{bf} /* {name} in Sources */,\n', s, count=1)
    print(f"registered: {rel} -> {target}")
    return s

def unregister(s, rel):
    """The counterpart of register: drop rel's build-file line, file-reference line and
    both membership lines from project-file text s, returning the result. rel is the
    repo-relative path (Kiteloop/<target>/...), resolved to a group the same way
    register does, so a duplicate basename in another group is left untouched. A path
    never registered — a file the mover's own git-add hasn't caught up with yet, say,
    or one whose group the walk can't resolve — is not an error: printed and returned
    unchanged."""
    name=rel.split('/')[-1]
    g=groups(s)
    ref=ref_in_group(g, group_for(g, rel), name)
    bf=re.search(r'([0-9A-F]{24}) /\* '+re.escape(name)+r' in Sources \*/ = \{isa = PBXBuildFile; fileRef = '+re.escape(ref or '')+r' /\*',s) if ref else None
    if not ref or not bf:
        print(f'  pbxproj: {rel} was not registered'); return s
    bf=bf.group(1)
    s=re.sub(r'\t\t'+bf+r' /\* '+re.escape(name)+r' in Sources \*/ = \{isa = PBXBuildFile;[^\n]*\n','',s,count=1)
    s=re.sub(r'\t\t'+ref+r' /\* '+re.escape(name)+r' \*/ = \{isa = PBXFileReference;[^\n]*\n','',s,count=1)
    s=s.replace('\t\t\t\t'+ref+' /* '+name+' */,\n','',1).replace('\t\t\t\t'+bf+' /* '+name+' in Sources */,\n','',1)
    return s

if __name__=='__main__':
    s=open(PBX).read()
    for a in sys.argv[1:]:
        rel=os.path.relpath(os.path.abspath(a), R)
        assert os.path.exists(os.path.join(R,rel)), rel
        s=register(s, rel)
    open(PBX,'w').write(s)
