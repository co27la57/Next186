#!/usr/bin/env python3
"""List ddr_wr / ddr_rd pulse widths and the AXI burst timing from a tr_on=2 log."""
import re
import sys

path = sys.argv[1]
rx = re.compile(
    r"^C (\d+) st=(\d+) ic=(\d+) ack=(\d+) cmd=(\d+) dwr=(\d) sdwr=(\d) "
    r"drd=(\d) sdrd=(\d) cst=(\d+) wbc=(\d+) hi=([0-9a-f]+) sdr=([0-9a-f]+) "
    r"arv=(\d) awv=(\d) aw=([0-9a-f]+)")

rows = []
for line in open(path, encoding="utf-8", errors="replace"):
    m = rx.match(line)
    if m:
        rows.append(dict(zip(
            ["cyc", "st", "ic", "ack", "cmd", "dwr", "sdwr", "drd", "sdrd",
             "cst", "wbc", "hi", "sdr", "arv", "awv", "aw"],
            [int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)),
             int(m.group(5)), int(m.group(6)), int(m.group(7)), int(m.group(8)),
             int(m.group(9)), int(m.group(10)), int(m.group(11)), m.group(12),
             m.group(13), int(m.group(14)), int(m.group(15)), m.group(16)])))
print("parsed %d cycles" % len(rows))

def pulses(key, name):
    print("\n---- %s pulses (first 24) ----" % name)
    prev = 0
    start = None
    n = 0
    for r in rows:
        v = r[key]
        if v and not prev:
            start = r["cyc"]
            s0 = r
        if prev and not v:
            print("  %s: cyc %d..%d  width=%d  at-rise: cst=%d cmd=%d ack=%d hi=%s sdr=%s"
                  % (name, start, r["cyc"] - 1, r["cyc"] - start, s0["cst"],
                     s0["cmd"], s0["ack"], s0["hi"], s0["sdr"]))
            n += 1
            if n >= 24:
                return
        prev = v

pulses("dwr", "ddr_wr")
pulses("drd", "ddr_rd")

# AXI burst launch events: transitions of state into AR_ADDR(1)/W_ISSUE(5)
print("\n---- AXI burst launches (first 30) ----")
n = 0
prev_st = None
for r in rows:
    st = r["st"]
    if prev_st is not None and st != prev_st and st in (1, 5):
        print("  cyc %d  %s  ack=%d cmd=%d dwr=%d drd=%d cst=%d hi=%s sdr=%s aw=%s"
              % (r["cyc"], "AR" if st == 1 else "AW", r["ack"], r["cmd"],
                 r["dwr"], r["drd"], r["cst"], r["hi"], r["sdr"], r["aw"]))
        n += 1
        if n >= 30:
            break
    prev_st = st
