#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Comment-aware byte-for-byte comparison of the two 1 KB BIOS tables.

  Next186_BlackBoxes.v : ram[11'h000] .. ram[11'h0FF]     (the cache BRAM preset)
  cache_controller.v   : bios_rom[8'h00] .. bios_rom[8'hFF]

Old values are left in comments, so the value on every line is taken as
split('//')[0] and only the last assignment per index is kept.
"""
import re
import sys

BLACK = "Next186_BlackBoxes.v"
CTRL = "cache_controller.v"

RX_BLACK = re.compile(r"ram\[11'h([0-9A-Fa-f]{3})\]\s*=\s*32'h([0-9A-Fa-f]{8})")
RX_CTRL = re.compile(r"bios_rom\[8'h([0-9A-Fa-f]{2})\]\s*=\s*32'h([0-9A-Fa-f]{8})")


def load(path, rx, hi):
    out = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        code = line.split("//")[0]
        m = rx.search(code)
        if m:
            out[int(m.group(1), 16)] = m.group(2).upper()
    return out


def main():
    a = load(BLACK, RX_BLACK, 0xFF)
    b = load(CTRL, RX_CTRL, 0xFF)
    print("blackbox entries: %d   controller entries: %d" % (len(a), len(b)))
    if len(a) != 256 or len(b) != 256:
        print("WARN: expected 256 entries each")
    bad = []
    for i in range(256):
        va = a.get(i)
        vb = b.get(i)
        if va != vb:
            bad.append((i, va, vb))
    if not bad:
        print("OK: all 256 words identical")
        return 0
    print("MISMATCH on %d words:" % len(bad))
    for i, va, vb in bad[:20]:
        print("  [0x%02X] blackbox=%s  controller=%s" % (i, va, vb))
    return 1


sys.exit(main())
