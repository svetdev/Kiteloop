#!/usr/bin/env python3
"""core-inits — a package memberwise init for every package type that lacks one.

A `package` struct's synthesised memberwise init is internal to the package, so
the app cannot construct it. This writes the init out, by the memberwise rules:
stored properties in declaration order, a `let` with a value left out, a `var`
with a value defaulted to it, an optional `var` defaulted to nil; a computed
property is skipped; a class whose stored properties lack defaults is reported
rather than guessed at. Strings and comments are masked before the brace scan,
and matches are processed last-first so offsets hold. Safe to re-run: a type
that already declares an init is left alone.

  ./scripts/core-package/core-inits.py
  ./scripts/core-package/core-inits.py --package DIR   # a test drives it over a fixture tree
"""
import argparse, os, re
R=os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), 'Kiteloop')
DEFAULT_PKG=R+'/KiteloopCore/Sources/KiteloopCore'
def files(d): return [os.path.join(dp,f) for dp,_,fs in os.walk(d) for f in fs if f.endswith('.swift')]
type_re=re.compile(r'^( *)package (?:final )?(struct|class|actor) ([A-Z]\w*)[^\n]*\{\n', re.M)
def mask(text):
    """Strings and comments replaced by spaces, newlines kept, so offsets hold."""
    def blank(m): return re.sub(r'[^\n]', ' ', m.group(0))
    text=re.sub(r'"""(?:.|\n)*?"""', blank, text)
    text=re.sub(r'"(?:\\.|[^"\\\n])*"', blank, text)
    text=re.sub(r'/\*.*?\*/', blank, text, flags=re.S)
    return re.sub(r'//[^\n]*', blank, text)
def main(PKG):
    for path in files(PKG):
        s=open(path).read(); changed=False
        for m in reversed(list(type_re.finditer(s))):   # last first, so earlier offsets stay valid
            indent,kind,name=m.group(1),m.group(2),m.group(3)
            prop_re=re.compile(r'^'+indent+r'    package (?:private\(set\) )?(let|var) (\w+): ([^=\n]+?)(?: = (.+))?\s*$', re.M)
            # every type, constructed by name or by .init(…) in a typed context
            # body: from the brace to the matching close
            i=m.end()-2; assert s[i]=='{'; depth=0; j=i; ms=mask(s)
            while True:
                c=ms[j]
                if c=='{': depth+=1
                elif c=='}':
                    depth-=1
                    if depth==0: break
                j+=1
            body=s[i:j]
            if re.search(r'^'+indent+r'    (package |public )?init\(', body, re.M): continue
            if 'package protocol' in body: continue
            props=[]; ok=True
            for pm in prop_re.finditer(body):
                kw,pname,ptype,default=pm.group(1),pm.group(2),pm.group(3).strip(),pm.group(4)
                if kw=='let' and default is not None: continue
                if '{' in ptype: continue   # a computed property
                if default is None and kw=='var' and ptype.rstrip().endswith('?'): default='nil'   # an optional var defaults to nil in the memberwise init
                props.append((pname,ptype,default.strip() if default else None))
            # computed vars look like `var x: T {`: excluded by prop_re's [^=\n] then `{`? guard:
            if re.search(r'^'+indent+r'    package (let|var) \w+\s*=', body, re.M): ok=False  # inferred type
            if not ok:
                print(f"SKIP {name} in {os.path.relpath(path,PKG)}: needs a hand-written init"); continue
            if kind=='class' and any(d is None for _,_,d in props):
                print(f"SKIP class {name}: stored properties without defaults"); continue
            params=', '.join(f"{p}: {t}" + (f" = {d}" if d is not None else '') for p,t,d in props)
            I=indent+'    '
            assigns='\n'.join(f"{I}    self.{p} = {p}" for p,_,_ in props) or I
            init=f"\n{I}/// The memberwise init, spelled out: a `package` type's synthesised one is\n{I}/// internal to the package, and the app constructs this.\n{I}package init({params}) {{\n{assigns}\n{I}}}\n"
            # insert before the closing brace of the type — back up over the brace's own
            # indentation first, so those spaces stay with the brace instead of being left
            # behind as trailing whitespace on the line above
            k=j
            while k>0 and s[k-1] in ' \t': k-=1
            s=s[:k]+init+s[k:]; changed=True
            print(f"init {name}({params}) in {os.path.relpath(path,PKG)}")
        if changed: open(path,'w').write(s)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description="a package memberwise init for every package type that lacks one")
    parser.add_argument('--package', default=DEFAULT_PKG, help="the package's Sources tree to scan")
    main(parser.parse_args().package)
