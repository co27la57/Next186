#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Run the stage-2b harness over a parameter matrix and print a compact table.

Usage examples
--------------
  # every knob at its default, both fix settings
  sweep.py

  # the VGA / FIFO regime sweep
  sweep.py --fifo_drain 4,6,8,12,20 --vga_lnend 6,11,21 --vga_stride 40,80

  # clock-domain sweep
  sweep.py --sdr_per_cpu 2,4 --cpu_phase 0-7

  # only show the runs that FAIL the 1 KB read-back
  sweep.py --fifo_drain 4-20 --only_fail

Argument syntax: comma lists ("4,8") or ranges ("0-7", step 1).  `--fix_re` defaults to
0,1 so every configuration is run both with and without the 95th fix.

Positional order of the harness arguments (sim/run/stage2b/ddr_pipe.exe):
  gate_fill vga_model tr_on fix_re sdr_per_cpu cpu_phase frame_period vblnk_len
  fifo_drain cpu_gap vga_lnend vga_stride vga_lcr
"""
import argparse
import itertools
import os
import re
import subprocess
import sys

EXE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "run", "stage2b", "ddr_pipe.exe")

DEFAULTS = dict(gate_fill=[1], vga_model=[0], tr_on=[0], fix_re=[0, 1],
                sdr_per_cpu=[2], cpu_phase=[1], frame_period=[0], vblnk_len=[3],
                fifo_drain=[4], cpu_gap=[0], vga_lnend=[6], vga_stride=[40],
                vga_lcr=[400])

ORDER = ["gate_fill", "vga_model", "tr_on", "fix_re", "sdr_per_cpu", "cpu_phase",
         "frame_period", "vblnk_len", "fifo_drain", "cpu_gap",
         "vga_lnend", "vga_stride", "vga_lcr"]

RE_MIS = re.compile(r"mismatched bytes: (\d+) / (\d+)")
RE_DDR = re.compile(r"buffer lines mismatching in DDR: (\d+) / 16")
RE_SPUR = re.compile(r"WB=(\d+)\s+RD=(\d+)")
RE_VGA = re.compile(r"bursts=(\d+)\s+last row-col base=([0-9a-f]+)\s+"
                    r"s_prog_empty cycles=(\d+)\s+s_prog_full cycles=(\d+)")


def parse(spec):
    out = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part[1:]:
            a, b = part.split("-", 1)
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return out


def main():
    ap = argparse.ArgumentParser()
    for k in ORDER:
        ap.add_argument("--" + k, default=",".join(str(v) for v in DEFAULTS[k]))
    ap.add_argument("--only_fail", action="store_true")
    ap.add_argument("--timeout", type=int, default=120)
    args = ap.parse_args()

    grid = {k: parse(getattr(args, k)) for k in ORDER}
    combos = list(itertools.product(*[grid[k] for k in ORDER]))
    exe = os.path.normpath(EXE)
    if not os.path.exists(exe):
        print("harness not built: %s" % exe)
        return 1

    hdr = ["fix", "s/c", "ph", "drain", "lnend", "str", "gap", "frame",
           "mis", "ddr", "spurWB", "spurRD", "pe", "pf", "vgaB"]
    print(("  ".join("%-6s" % h for h in hdr)))
    nfail = 0
    for c in combos:
        argv = [exe] + [str(v) for v in c]
        try:
            out = subprocess.run(argv, capture_output=True, text=True,
                                 timeout=args.timeout).stdout
        except subprocess.TimeoutExpired:
            print("  ".join("%-6s" % x for x in
                            [c[3], c[4], c[5], c[8], c[10], c[11], c[9], c[6],
                             "TIMEOUT"]) + "   <-- too slow / starved")
            continue
        m = RE_MIS.search(out)
        mis = int(m.group(1)) if m else -1
        d = RE_DDR.search(out)
        ddr = int(d.group(1)) if d else -1
        s = RE_SPUR.search(out)
        swb, srd = (s.group(1), s.group(2)) if s else ("?", "?")
        v = RE_VGA.search(out)
        pe, pf, vb = (v.group(3), v.group(4), v.group(1)) if v else ("?", "?", "?")
        fail = (mis != 0)
        if fail:
            nfail += 1
        if args.only_fail and not fail:
            continue
        row = [c[3], c[4], c[5], c[8], c[10], c[11], c[9], c[6],
               mis, ddr, swb, srd, pe, pf, vb]
        print("  ".join("%-6s" % x for x in row) + ("   <-- FAIL" if fail else ""))
    print("\n%d/%d configurations FAIL the 1 KB read-back" % (nfail, len(combos)))
    return 0


sys.exit(main())
