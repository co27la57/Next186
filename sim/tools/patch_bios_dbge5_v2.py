#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""BIOS patch v2: move the 0x00E5 report from offset 0x84 to offset 0x180.

v1 answered its question: dbg_dbg5 = 0x61 together with dbg_dbg4 = 0x6010 means the byte at
0x80 is 0x60 and the byte at 0x84 is 0x61 - a CONTIGUOUS run, i.e. the whole self-test
pattern has been shifted by exactly 0x100 bytes (4 buffer lines).  So buffer line 2's slot
holds line 6's content, not a repeated word 0.

The next fork is: is the DDR itself corrupted (WRITE side), or did the FILL of line 2 read
line 6's address (READ side)?  Reading offset 0x180 (buffer line 6's own slot) answers it:

    [0x180] == 0x60   -> DDR is intact, the fill of line 2 read the wrong address (READ side)
    [0x180] != 0x60   -> line 6's write-back went somewhere else (WRITE side)

0x180 is 0x100 past DI (=0x80), which does not fit a disp8, so the instruction grows by one
byte and the trailing nop is consumed.  The window 0x3D3..0x3E1 is then filled exactly:

    03D3  52           push dx
    03D4  BA E4 00     mov dx,0xe4
    03D7  EF           out dx,ax
    03D8  8A 85 00 01  mov al,[di+0x100]   ; AL = [0x180]
    03DC  BA E5 00     mov dx,0xe5
    03DF  EE           out dx,al
    03E0  5A           pop dx
    03E1  C3           ret
    03E2  52 ...                          ; pckp, untouched

Table words 0xF6 / 0xF7 / 0xF8 in BOTH copies.

usage: patch_bios_dbge5_v2.py [--revert]
"""
import re
import sys

OLD = {0xF6: 0xBA04458A, 0xF7: 0x5AEE00E5, 0xF8: 0x8B5290C3}
NEW = {0xF6: 0x0100858A, 0xF7: 0xEE00E5BA, 0xF8: 0x8B52C35A}

TARGETS = [
    ("Next186_BlackBoxes.v", r"ram\[11'h%03X\]\s*=\s*32'h([0-9A-Fa-f]{8})"),
    ("cache_controller.v",   r"bios_rom\[8'h%02X\]\s*=\s*32'h([0-9A-Fa-f]{8})"),
]

CMT_OLD = re.compile(r"[ \t]*// \u2605 \[95th self-test probe.*?\n(?:.*?\n){4}", re.S)
CMT_NEW = (
    "\t\t// \u2605 [95th self-test probe v2, 2026-09-26] \u81ea\u6d4b\u989d\u5916\u4e0a\u62a5 offset 0x180\n"
    "\t\t//   \uff08line 6 \u81ea\u5df1\u7684\u69fd\u4f4d\uff09\u7684\u56de\u8bfb\u5b57\u8282\u5230\u7a7a\u95f2\u7aef\u53e3 0x00E5\u3002\n"
    "\t\t//   v1 \u5df2\u7ecf\u8bc1\u5b9e [0x80]=0x60 \u4e14 [0x84]=0x61 \u2014\u2014 \u81ea\u6d4b\u56fe\u6848\u6574\u4f53\u53f3\u79fb 0x100 \u5b57\u8282\uff08+4 \u884c\uff09\u3002\n"
    "\t\t//   \u672c\u8f6e\u5224\u636e\uff1a[0x180]==0x60 \u21d2 DDR \u5b8c\u597d\u3001\u662f**\u586b\u5145\u8bfb\u9519\u5730\u5740**\uff1b\n"
    "\t\t//             \u5426\u5219 \u21d2 line 6 \u7684**\u5199\u56de\u843d\u5230\u4e86\u522b\u5904**\u3002\n"
    "\t\t//   \u673a\u5668\u7801\uff1a03D8 8A 85 00 01 / 03DC BA E5 00 / 03DF EE / 03E0 5A / 03E1 C3\n"
)


def main():
    revert = "--revert" in sys.argv
    want = OLD if revert else NEW
    have = NEW if revert else OLD

    for path, tmpl in TARGETS:
        raw = open(path, "r", encoding="utf-8", newline="").read()
        if "\r\n" in raw:
            print("ABORT: %s is CRLF; BIOS tables must stay LF" % path)
            return 1
        lines = raw.split("\n")
        for idx in sorted(want):
            pat = re.compile(tmpl % idx)
            hits = [i for i, l in enumerate(lines) if pat.search(l.split("//")[0])]
            if len(hits) != 1:
                print("ABORT: %s word %03X -> %d active assignments" % (path, idx, len(hits)))
                return 1
            i = hits[0]
            cur = int(pat.search(lines[i].split("//")[0]).group(1), 16)
            if cur != have[idx]:
                print("ABORT: %s word %03X is %08X, expected %08X" % (path, idx, cur, have[idx]))
                return 1
            lines[i] = pat.sub(lambda m: m.group(0).replace(m.group(1), "%08X" % want[idx]),
                               lines[i], count=1)
            print("ok  %-24s word %03X  %08X -> %08X" % (path, idx, cur, want[idx]))
        raw2 = "\n".join(lines)
        cmt = CMT_NEW if not revert else None
        if cmt is not None:
            if not CMT_OLD.search(raw2):
                print("ABORT: %s v1 comment block not found" % path)
                return 1
            raw2 = CMT_OLD.sub(lambda m: cmt, raw2, count=1)
        open(path, "w", encoding="utf-8", newline="").write(raw2)
    print("BIOS probe v2 %s (both copies)" % ("REVERTED" if revert else "applied"))
    return 0


sys.exit(main())
