#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Repair: re-insert table word 0xF6 that patch_bios_dbge5_v2.py's comment regex ate.

The v2 comment substitution matched one line too many and swallowed the
`ram[11'h0F6] = ...` / `bios_rom[8'hF6] = ...` line in both BIOS copies.
This re-inserts it (with the value v2 intended) and asserts the result.
"""
import re
import sys

JOBS = [
    ("Next186_BlackBoxes.v", "        ", r"ram\[11'h0F7\]"),
    ("cache_controller.v",   "\t\t",     r"bios_rom\[8'hF7\]"),
]
VAL = {0xF6: 0x0100858A, 0xF7: 0xEE00E5BA, 0xF8: 0x8B52C35A}


def main():
    for path, indent, anchor in JOBS:
        raw = open(path, "r", encoding="utf-8", newline="").read()
        if "\r\n" in raw:
            print("ABORT: %s is CRLF" % path)
            return 1
        lines = raw.split("\n")
        name = "ram[11'h0F6]" if "ram" in anchor else "bios_rom[8'hF6]"
        present = [i for i, l in enumerate(lines) if name in l.split("//")[0]]
        if len(present) == 1:
            print("ok  %s already has 0xF6" % path)
            continue
        if len(present) != 0:
            print("ABORT: %s has %d 0xF6 lines" % (path, len(present)))
            return 1
        a = [i for i, l in enumerate(lines) if re.search(anchor, l.split("//")[0])]
        if len(a) != 1:
            print("ABORT: %s anchor found %d times" % (path, len(a)))
            return 1
        hexfmt = "ram[11'h0F6] = 32'h%08X;" if "ram" in anchor else "bios_rom[8'hF6] = 32'h%08X;"
        lines.insert(a[0], indent + (hexfmt % VAL[0xF6]))
        open(path, "w", encoding="utf-8", newline="").write("\n".join(lines))
        print("ok  %s 0xF6 re-inserted" % path)

    # verify all three words in both copies
    ok = True
    for path, _ind, _a in JOBS:
        rx = (re.compile(r"ram\[11'h([0-9A-Fa-f]{3})\]\s*=\s*32'h([0-9A-Fa-f]{8})")
              if "BlackBoxes" in path else
              re.compile(r"bios_rom\[8'h([0-9A-Fa-f]{2})\]\s*=\s*32'h([0-9A-Fa-f]{8})"))
        w = {}
        for line in open(path, encoding="utf-8", errors="replace"):
            m = rx.search(line.split("//")[0])
            if m:
                w[int(m.group(1), 16)] = int(m.group(2), 16)
        for idx in (0xF6, 0xF7, 0xF8):
            good = w.get(idx) == VAL[idx]
            ok = ok and good
            print("  %s %s %03X = %s (want %08X)"
                  % ("OK  " if good else "FAIL", path, idx,
                     "%08X" % w.get(idx, -1) if idx in w else "MISSING", VAL[idx]))
    print("RESULT: %s" % ("ALL OK" if ok else "PROBLEM"))
    return 0 if ok else 1


sys.exit(main())
