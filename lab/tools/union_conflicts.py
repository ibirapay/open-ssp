"""Resolve conflict hunks that are plain comma-separated identifier lists by taking the union.
usage: union_conflicts.py FILE [HUNK_INDEX ...]  (1-based; default all). Refuses hunks with code."""
import re, sys
path = sys.argv[1]; want = {int(x) for x in sys.argv[2:]}
s = open(path).read()
pat = re.compile(r'<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n', re.S)
n = 0
def fix(m):
    global n; n += 1
    if want and n not in want: return m.group(0)
    a, b = m.group(1), m.group(2)
    items = []
    for side in (a, b):
        for tok in side.replace('\n', ' ').split(','):
            tok = tok.strip()
            if not tok: continue
            if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', tok):
                sys.exit(f"hunk {n}: not a plain identifier list ({tok!r}); resolve by hand")
            if tok not in items: items.append(tok)
    indent = re.match(r'\s*', a).group(0)
    return indent + ', '.join(items) + ',\n'
s = pat.sub(fix, s)
open(path, 'w').write(s)
print(f"{path}: {n} hunk(s) seen")
