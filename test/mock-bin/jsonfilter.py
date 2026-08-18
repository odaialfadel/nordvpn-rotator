"""Local-test emulation of OpenWrt's jsonfilter for the query subset this
project uses: @[N].field, @.field, and [@.key="value"] predicates.
Only for the PC harness — the router uses the real jsonfilter."""
import json
import re
import sys


def main():
    args = sys.argv[1:]
    src = None
    expr = None
    i = 0
    while i < len(args):
        if args[i] == "-i":
            i += 1
            src = args[i]
        elif args[i] == "-e":
            i += 1
            expr = args[i]
        i += 1
    if expr is None:
        sys.exit(2)
    data = json.load(open(src, encoding="utf-8")) if src else json.load(sys.stdin)
    body = expr[1:] if expr.startswith("@") else expr
    toks = re.findall(r'\[@\.\w+="[^"]*"\]|\[\d+\]|\.\w+', body)
    nodes = [data]
    for t in toks:
        out = []
        if t.startswith("[@"):
            m = re.match(r'\[@\.(\w+)="([^"]*)"\]', t)
            k, v = m.group(1), m.group(2)
            for n in nodes:
                if isinstance(n, list):
                    out.extend(x for x in n if isinstance(x, dict) and str(x.get(k)) == v)
        elif t.startswith("["):
            idx = int(t[1:-1])
            for n in nodes:
                if isinstance(n, list) and idx < len(n):
                    out.append(n[idx])
        else:
            k = t[1:]
            for n in nodes:
                if isinstance(n, dict) and k in n:
                    out.append(n[k])
        nodes = out
    printed = False
    for n in nodes:
        if isinstance(n, bool):
            print("true" if n else "false")
        elif isinstance(n, (int, float, str)):
            print(n)
        else:
            print(json.dumps(n))
        printed = True
    sys.exit(0 if printed else 1)


main()
