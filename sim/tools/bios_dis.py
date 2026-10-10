#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Extract the 1 KB BIOS image from either of its two copies and disassemble a range.

Layout (verified against the reset vector at table offset 0x3F0 = EA 00 FC 00 F0):
    table byte 4*i+0 = word[i][ 7: 0]      table byte 4*i+2 = word[i][23:16]
    table byte 4*i+1 = word[i][15: 8]      table byte 4*i+3 = word[i][31:24]
    table byte 0  <-> maddr 0xFFC00   (segment F000, offset FC00)

Both copies are comment-aware: the value on a line is line.split('//')[0], and the LAST
assignment for an index wins.

usage: bios_dis.py [start_hex] [end_hex]      e.g. bios_dis.py 0x390 0x400
"""
import re
import sys

BLACK = "Next186_BlackBoxes.v"
CTRL = "cache_controller.v"

RX_BLACK = re.compile(r"ram\[11'h([0-9A-Fa-f]{3})\]\s*=\s*32'h([0-9A-Fa-f]{8})")
RX_CTRL = re.compile(r"bios_rom\[8'h([0-9A-Fa-f]{2})\]\s*=\s*32'h([0-9A-Fa-f]{8})")


def load(path, rx):
    out = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        m = rx.search(line.split("//")[0])
        if m:
            out[int(m.group(1), 16)] = int(m.group(2), 16)
    return out


def to_bytes(words):
    b = bytearray(1024)
    for i in range(256):
        w = words.get(i, 0)
        b[4 * i + 0] = w & 0xFF
        b[4 * i + 1] = (w >> 8) & 0xFF
        b[4 * i + 2] = (w >> 16) & 0xFF
        b[4 * i + 3] = (w >> 24) & 0xFF
    return bytes(b)


def main():
    lo = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0x000
    hi = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x400
    a = load(BLACK, RX_BLACK)
    c = load(CTRL, RX_CTRL)
    print("blackbox words=%d  controller words=%d" % (len(a), len(c)))
    ba, bc = to_bytes(a), to_bytes(c)
    if ba != bc:
        print("!! the two copies DIFFER at bytes:",
              [hex(i) for i in range(1024) if ba[i] != bc[i]][:16])
    else:
        print("both copies identical (1024 bytes)")

    try:
        import capstone
    except ImportError:
        print("capstone not installed; hex dump only")
        for off in range(lo, hi, 16):
            print("%04X  %s" % (off, " ".join("%02X" % x for x in ba[off:off + 16])))
        return 0

    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)
    md.detail = False
    code = ba[lo:hi]
    print("\n---- disassembly 0x%03X .. 0x%03X  (table offset == maddr-0xFFC00) ----" % (lo, hi))
    for ins in md.disasm(code, lo):
        raw = " ".join("%02X" % b for b in ins.bytes)
        print("%04X  %-14s %-7s %s" % (ins.address, raw, ins.mnemonic, ins.op_str))
    return 0


sys.exit(main())
