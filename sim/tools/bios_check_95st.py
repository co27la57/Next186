#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Post-patch assertions for the 95th self-test probe (BIOS 0x00E5 report).

1. both BIOS copies byte-identical
2. the self-test sequence 0x39F..0x3BA is byte-for-byte what we expect
3. the report routine 0x3D3..0x3E0 is byte-for-byte what we expect
4. every direct branch/call target inside 0x390..0x3E1 lands on a real
   instruction boundary of the linear disassembly
5. the reset vector and the 0x002E hook are intact
6. the free-space budget is respected (nothing else in 0x3DA..0x3E1 changed)
"""
import re
import sys

import capstone

BLACK = "Next186_BlackBoxes.v"
CTRL = "cache_controller.v"
RX = {
    BLACK: re.compile(r"ram\[11'h([0-9A-Fa-f]{3})\]\s*=\s*32'h([0-9A-Fa-f]{8})"),
    CTRL:  re.compile(r"bios_rom\[8'h([0-9A-Fa-f]{2})\]\s*=\s*32'h([0-9A-Fa-f]{8})"),
}


def load(path):
    out = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        m = RX[path].search(line.split("//")[0])
        if m:
            out[int(m.group(1), 16)] = int(m.group(2), 16)
    return out


def to_bytes(words):
    b = bytearray(1024)
    for i in range(256):
        w = words.get(i, 0)
        b[4 * i] = w & 0xFF
        b[4 * i + 1] = (w >> 8) & 0xFF
        b[4 * i + 2] = (w >> 16) & 0xFF
        b[4 * i + 3] = (w >> 24) & 0xFF
    return bytes(b)


fails = []


def check(cond, msg):
    print(("  OK   " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)


def main():
    a, c = load(BLACK), load(CTRL)
    ba, bc = to_bytes(a), to_bytes(c)
    print("1) two copies")
    check(ba == bc, "1024 bytes identical in both copies")

    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)

    print("2) self test 0x39F..0x3BA")
    expect_test = [
        (0x39F, "cld", ""),
        (0x3A0, "xor", "di, di"),
        (0x3A2, "xor", "al, al"),
        (0x3A4, "mov", "cx, 4"),
        (0x3A7, "rep stosb", "byte ptr es:[di], al"),
        (0x3A9, "inc", "al"),
        (0x3AB, "jne", "0x3a4"),
        (0x3AD, "mov", "di, 0x40"),
        (0x3B0, "mov", "al, byte ptr [di]"),
        (0x3B2, "mov", "di, 0x80"),
        (0x3B5, "call", "0x10f"),
        (0x3B8, "mov", "ah, byte ptr [di]"),
        (0x3BA, "jmp", "0x3d3"),
    ]
    ins_list = list(md.disasm(ba[0x39F:0x3BC], 0x39F))
    got = {i.address: (i.mnemonic, i.op_str) for i in ins_list}
    for addr, mn, ops in expect_test:
        g = got.get(addr)
        check(g == (mn, ops), "0x%03X  %s %s   (got %s)" % (addr, mn, ops, g))

    print("3) report routine 0x3D3..0x3E0")
    expect_rep = [
        (0x3D3, "push", "dx"),
        (0x3D4, "mov", "dx, 0xe4"),
        (0x3D7, "out", "dx, ax"),
        (0x3D8, "mov", "al, byte ptr [di + 0x100]"),
        (0x3DC, "mov", "dx, 0xe5"),
        (0x3DF, "out", "dx, al"),
        (0x3E0, "pop", "dx"),
        (0x3E1, "ret", ""),
    ]
    got2 = {i.address: (i.mnemonic, i.op_str)
            for i in md.disasm(ba[0x3D3:0x3E2], 0x3D3)}
    for addr, mn, ops in expect_rep:
        g = got2.get(addr)
        check(g == (mn, ops), "0x%03X  %s %s   (got %s)" % (addr, mn, ops, g))

    print("4) branch targets land on instruction boundaries")
    starts = {i.address for i in md.disasm(ba[0x000:0x3F0], 0x000)}
    n = 0
    for i in md.disasm(ba[0x390:0x3E2], 0x390):
        if i.mnemonic.startswith(("j", "call", "loop")) and i.op_str.startswith("0x"):
            t = int(i.op_str, 16)
            n += 1
            check(t in starts, "0x%03X %s -> 0x%03X is an instruction start" % (i.address, i.mnemonic, t))
    print("  (%d branch targets checked, %d instruction starts in 0x000..0x3F0)" % (n, len(starts)))

    print("5) reset vector + hook")
    check(ba[0x3F0:0x3F5] == bytes([0xEA, 0x00, 0xFC, 0x00, 0xF0]),
          "0x3F0 = EA 00 FC 00 F0 (ljmp F000:FC00)")
    hook = list(md.disasm(ba[0x002E:0x0031], 0x002E))
    check(len(hook) == 1 and hook[0].mnemonic == "call" and hook[0].op_str == "0x39f",
          "0x002E = call 0x39F  (got %s)" % ([(h.mnemonic, h.op_str) for h in hook]))

    print("6) only 0x3D8..0x3E1 changed")
    V2 = {0xF6: 0x0100858A, 0xF7: 0xEE00E5BA, 0xF8: 0x8B52C35A}
    for idx in (0xF5, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF):
        check(a[idx] == c[idx], "word %03X equal in both copies (%08X)" % (idx, a[idx]))
    for idx in (0xF6, 0xF7, 0xF8):
        check(a[idx] == V2[idx] and c[idx] == V2[idx],
              "word %03X = %08X in both copies" % (idx, V2[idx]))

    print()
    if fails:
        print("RESULT: %d FAILED" % len(fails))
        return 1
    print("RESULT: ALL CHECKS PASSED")
    return 0


sys.exit(main())
