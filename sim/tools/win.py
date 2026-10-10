#!/usr/bin/env python3
"""Print a context window around every match of PAT in a trace file.

usage: win.py <logfile> <pat> [before] [after] [maxhits]
"""
import re
import sys

path = sys.argv[1]
pat = re.compile(sys.argv[2])
before = int(sys.argv[3]) if len(sys.argv) > 3 else 20
after = int(sys.argv[4]) if len(sys.argv) > 4 else 40
maxhits = int(sys.argv[5]) if len(sys.argv) > 5 else 3

lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
hits = [i for i, l in enumerate(lines) if pat.search(l)]
print("total hits = %d" % len(hits))
for h in hits[:maxhits]:
    lo = max(0, h - before)
    hi = min(len(lines), h + after)
    print("=" * 100)
    print("hit at line %d" % h)
    for i in range(lo, hi):
        mark = ">>" if i == h else "  "
        print("%s %s" % (mark, lines[i]))
