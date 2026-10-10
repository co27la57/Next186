#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""BIOS patch: report ONE MORE read-back byte through the free 0x00E5 channel.

Why: on the board the memory self test reads offset 0x80 after scan256 and gets 0x60
(expect 0x20) - i.e. the value that BELONGS at offset 0x180 (buffer line 6).  dbg_dbg4
only carries that single byte, which cannot distinguish
    (a) the whole line 2 was replaced by line 6's content   -> [0x84] = 0x61
    (b) "word 0 of line 6" was repeated over line 2         -> [0x84] = 0x60
    (c) only the first byte/word of line 2 is wrong         -> [0x84] = 0x21
so add a second byte to the free port 0x00E5 (dbg_dbg5, unused since the 87th change).

The self test currently is (capstone-verified, table offset == maddr-0xFFC00):

    03B2  BF 80 00     mov di,0x80
    03B5  E8 57 FD     call 0x10F          ; scan256 (preserves DI/DX/AX)
    03B8  8A 25        mov ah,[di]         ; AH = [0x80]
    03BA  EB 17        jmp 0x3d3
    03D3  52           push dx
    03D4  BA E4 00     mov dx,0xe4
    03D7  EF           out dx,ax           ; dbg_dbg4 = AX
    03D8  5A           pop dx
    03D9  C3           ret
    03DA..03E1         8 x nop             <- the only free space in this window

The patch replaces the tail with

    03D8  8A 45 04     mov al,[di+4]       ; AL = [0x84]  (DI is still 0x80)
    03DB  BA E5 00     mov dx,0xe5
    03DE  EE           out dx,al           ; dbg_dbg5 = [0x84]
    03DF  5A           pop dx              ; stack stays balanced (push at 0x3D3)
    03E0  C3           ret
    03E1  90           nop

Touches table words 0xF6 / 0xF7 / 0xF8 only, in BOTH copies
(Next186_BlackBoxes.v ram[] and cache_controller.v bios_rom[]).

usage: patch_bios_dbge5.py [--revert]
"""
import re
import sys

NEW = {
    0xF6: 0xBA04458A,   # was 0x9090C35A : 8A 45 04 BA
    0xF7: 0x5AEE00E5,   # was 0x90909090 : E5 00 EE 5A
    0xF8: 0x8B5290C3,   # was 0x8B529090 : C3 90 52 8B
}
OLD = {0xF6: 0x9090C35A, 0xF7: 0x90909090, 0xF8: 0x8B529090}

TARGETS = [
    ("Next186_BlackBoxes.v", r"ram\[11'h%03X\]\s*=\s*32'h([0-9A-Fa-f]{8})"),
    ("cache_controller.v",   r"bios_rom\[8'h%02X\]\s*=\s*32'h([0-9A-Fa-f]{8})"),
]

COMMENT = (
    "\t\t// \u2605 [95th self-test probe, 2026-09-26] \u81ea\u6d4b\u989d\u5916\u4e0a\u62a5 offset 0x84 \u7684\u56de\u8bfb\u5b57\u8282\u5230\n"
    "\t\t//   \u7a7a\u95f2\u7aef\u53e3 0x00E5 (dbg_dbg5)\u3002\u7528\u6765\u533a\u5206\u201c\u6574\u884c\u88ab\u6362\u6210 line 6 \u7684\u5185\u5bb9\u201d(0x61)\n"
    "\t\t//   / \u201cline 6 \u7684 word0 \u91cd\u590d\u201d(0x60) / \u201c\u53ea\u6709\u9996\u5b57\u8282\u9519\u201d(0x21)\u3002\n"
    "\t\t//   \u673a\u5668\u7801\uff1a03D8 8A 45 04 / 03DB BA E5 00 / 03DE EE / 03DF 5A / 03E0 C3\n"
)


def main():
    revert = "--revert" in sys.argv
    want = OLD if revert else NEW
    have = NEW if revert else OLD

    for path, tmpl in TARGETS:
        raw = open(path, "r", encoding="utf-8", newline="").read()
        if "\r\n" in raw:
            print("ABORT: %s is CRLF; the BIOS tables must stay LF" % path)
            return 1
        lines = raw.split("\n")
        for idx in sorted(want):
            pat = re.compile(tmpl % idx)
            hits = [i for i, l in enumerate(lines) if pat.search(l.split("//")[0])]
            if len(hits) != 1:
                print("ABORT: %s word %03X -> %d active assignments" % (path, idx, len(hits)))
                return 1
            i = hits[0]
            m = pat.search(lines[i].split("//")[0])
            cur = int(m.group(1), 16)
            if cur != have[idx]:
                print("ABORT: %s word %03X is %08X, expected %08X"
                      % (path, idx, cur, have[idx]))
                return 1
            lines[i] = pat.sub(lambda mm: mm.group(0).replace(
                mm.group(1), "%08X" % want[idx]), lines[i], count=1)
            if not revert and idx == 0xF6:
                lines.insert(i, COMMENT.rstrip("\n"))
            print("ok  %-24s word %03X  %08X -> %08X" % (path, idx, cur, want[idx]))
        open(path, "w", encoding="utf-8", newline="").write("\n".join(lines))
    print("BIOS patch %s" % ("REVERTED" if revert else "applied (both copies)"))
    return 0


sys.exit(main())
