#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Locate the Next186 BIOS KeyIndex / KeyCode tables in a prebuilt binary and
decode the scancode -> ASCII map that the BIOS actually implements.

BIOS_Next186.asm declares two interchangeable KeyIndex tables:
  SCANCODE1 (set-1 scancodes expected on port 60h)
  SCANCODE2 (set-2 scancodes expected on port 60h)
keyed by IFDEF SCANCODE1.  The KeyCode table itself is shared and holds the
SET-1 scancode in the high byte of each entry, while its comments label the
rows with SET-2 scancodes.

Usage:  python bios_keymap.py <bios.bin> [...]
"""
import sys

KINDEX1 = bytes([0, 82, 49, 50, 52, 51, 54, 55, 56, 57, 60, 59, 65, 68, 72, 47,
                 1, 5, 9, 13, 12, 18, 21, 23, 24, 26, 67, 70, 69, 0, 4, 3])
KINDEX2 = bytes([0, 79, 0, 38, 39, 40, 41, 42, 0, 43, 44, 45, 46, 47, 48, 0,
                 0, 0, 0, 0, 0, 1, 49, 0, 0, 0, 2, 3, 4, 5, 50, 0])

# KeyCode row 0 is all zeros, row 1 is 1071h,1051h,1011h,1000h -> unique 16B sig.
KEYCODE_SIG = bytes([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                     0x71, 0x10, 0x51, 0x10, 0x11, 0x10, 0x00, 0x10])

NAMES = {
    0x02: "1", 0x03: "2", 0x04: "3", 0x05: "4", 0x06: "5", 0x07: "6",
    0x08: "7", 0x09: "8", 0x0A: "9", 0x0B: "0", 0x0C: "-", 0x0D: "=",
    0x0E: "BKSP", 0x0F: "TAB", 0x1C: "ENTER", 0x1D: "LCTRL", 0x2A: "LSHIFT",
    0x36: "RSHIFT", 0x38: "LALT", 0x39: "SPACE", 0x3A: "CAPS",
}
for i, c in enumerate("qwertyuiop"):
    NAMES[0x10 + i] = c.upper()
NAMES[0x1A], NAMES[0x1B] = "[", "]"
for i, c in enumerate("asdfghjkl"):
    NAMES[0x1E + i] = c.upper()
NAMES[0x27], NAMES[0x28], NAMES[0x29] = ";", "'", "`"
for i, c in enumerate("zxcvbnm"):
    NAMES[0x2C + i] = c.upper()
NAMES[0x33], NAMES[0x34], NAMES[0x35] = ",", ".", "/"


def pr(ch):
    return chr(ch) if 0x20 <= ch < 0x7F else ("<%02X>" % ch)


def analyse(path):
    data = open(path, "rb").read()
    print("=" * 78)
    print("%s  (%d bytes)" % (path, len(data)))

    o1 = data.find(KINDEX1)
    o2 = data.find(KINDEX2)
    print("  KeyIndex(SCANCODE1) @ %s" % ("0x%X" % o1 if o1 >= 0 else "NOT FOUND"))
    print("  KeyIndex(SCANCODE2) @ %s" % ("0x%X" % o2 if o2 >= 0 else "NOT FOUND"))

    kc = data.find(KEYCODE_SIG)
    print("  KeyCode   @ %s" % ("0x%X" % kc if kc >= 0 else "NOT FOUND"))
    if kc < 0 or (o1 < 0 and o2 < 0):
        print("  -> cannot decode")
        return

    base_ki, which = (o1, "SCANCODE1") if o1 >= 0 else (o2, "SCANCODE2")
    print("  => linkable KeyIndex = %s" % which)
    print()
    print("  sc  key        row  norm  shft   ctrl")
    for s in sorted(NAMES):
        if base_ki + s >= len(data):
            continue
        row = data[base_ki + s]
        off = kc + row * 8
        if off + 8 > len(data):
            continue
        n = int.from_bytes(data[off:off + 2], "little")
        f = int.from_bytes(data[off + 2:off + 4], "little")
        c = int.from_bytes(data[off + 4:off + 6], "little")
        print("  %02X  %-9s  %3d  %-6s %-6s %-6s   (AH=%02X)"
              % (s, NAMES[s], row, pr(n & 0xFF), pr(f & 0xFF), pr(c & 0xFF), n >> 8))


for p in sys.argv[1:]:
    try:
        analyse(p)
    except Exception as e:
        print("%s: %s" % (p, e))
