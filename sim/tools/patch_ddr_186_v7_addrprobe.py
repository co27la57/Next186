#!/usr/bin/env python3
# -*- coding: ascii -*-
"""v7 - capture the FULL line address (tag[4:0] + index) the DDR FSM consumed.

Applies on top of the v6-patched ddr_186.v.

WHY
---
v6 (corrected d1 tap) returned on the board:
    dbg_wb_wl   = 0x2F2F   write-back carried a complete correct line-2 sequence
    dbg_fill_*  = 0x0000 / 0x0C00   fill data wrong
    fill_page = wb_page = 0x00F ,  pmis_r = pmis_w = 0
map[15] = 0x0F on the BOARD (the BIOS programs it at 0x0017: `mov al,0xf / out 0x8f,ax`),
so page 0x00F is the buffer's CORRECT page and pmis=0 means the page was never stale.
BUT dbg_pmis only compares the PAGE (sdraddr[23:15]).  If cache_hi_addr changed to a
DIFFERENT LINE OF THE SAME PAGE inside the sampling window, pmis stays 0 while the fill
reads another buffer line's address - exactly the observed "+N lines" displacement.

So capture the low 10 bits of the consumed address (sdraddr[14:5] = {tag[4:0], index})
and compare them with the gate's own cache_hi_addr[9:0].

New probes (20 bit) ; removed dbg_bufwb_a (15 bit - its value 0x3C01 is now explained:
scan256's last access is bx=0x40 = line 1, so the last evicted victim IS index 1).
Budget: 292 - 15 + 20 = 297 bit.
"""
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
TARGET = os.path.join(ROOT, 'ddr_186.v')
BACKUP = os.path.join(ROOT, 'sim', 'run', 'ddr_186.v.preV7')


def load(p):
    return open(p, 'r', newline='').readlines()


def save(p, lines):
    txt = ''.join(lines).replace('\r\n', '\n').replace('\n', '\r\n')
    open(p, 'w', newline='').write(txt)


def find_one(lines, needle, what):
    hits = [i for i, l in enumerate(lines) if needle in l]
    if len(hits) != 1:
        sys.exit('ANCHOR FAIL (%s): %d hits for %r' % (what, len(hits), needle))
    return hits[0]


def indent_of(line):
    return line[:len(line) - len(line.lstrip('\t'))]


def apply():
    lines = load(TARGET)

    # ---- 1) address delay chain (sdraddr[14:5], 1 stage) in the main block ----
    i = find_one(lines, 'dbg_pg_d1 <= sdraddr[23:15];', 'page delay')
    ind = indent_of(lines[i])
    lines[i + 1:i + 1] = [
        ind + 'dbg_ad_d1 <= sdraddr[14:5];\n',
    ]

    # ---- 2) declarations: drop dbg_bufwb_a, add the two address probes ----
    i = find_one(lines, 'reg [14:0] dbg_bufwb_a  = 15\'h0000;', 'bufwb_a decl')
    ind = indent_of(lines[i])
    lines[i:i + 1] = [
        ind + '// v7: the FULL line address ({tag[4:0], index}) the DDR FSM consumed.\n',
        ind + '//   v6 proved the PAGE is never stale (pmis=0), but pmis only sees bits [23:15].\n',
        ind + '//   A hiaddr change inside the sampling window that stays within the SAME page\n',
        ind + '//   (buffer lines thrashing among themselves) is invisible to pmis yet makes the\n',
        ind + '//   fill read another buffer line\'s address = the observed "+N lines" shift.\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg [9:0] dbg_fill_addr = 10\'h000;\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg [9:0] dbg_wb_addr   = 10\'h000;\n',
    ]
    i = find_one(lines, 'reg [14:0] dbg_bufwb_a_live = 15\'d0;', 'bufwb_a_live decl')
    ind = indent_of(lines[i])
    lines[i + 1:i + 1] = [
        ind + 'reg [9:0]  dbg_ad_d1 = 10\'d0;   // sdraddr[14:5] delayed 1 clk_sdr\n',
        ind + 'reg [9:0]  dbg_fill_addr_live = 10\'d0;\n',
        ind + 'reg [9:0]  dbg_wb_addr_live   = 10\'d0;\n',
    ]

    # ---- 3) reset line for dbg_bufwb_a: none exists (it is only assigned in the
    #         0x00E5 freeze), so nothing to remove here. ----

    # ---- 4) latch at the ack ----
    i = find_one(lines, 'dbg_fill_page_live <= dbg_pg_d1;', 'page latch (fill)')
    ind = indent_of(lines[i])
    lines[i + 1:i + 1] = [
        ind + 'dbg_fill_addr_live <= dbg_ad_d1;\n',
    ]
    i = find_one(lines, 'dbg_wb_page_live <= dbg_pg_d1;', 'page latch (wb)')
    ind = indent_of(lines[i])
    lines[i + 1:i + 1] = [
        ind + 'dbg_wb_addr_live <= dbg_ad_d1;\n',
    ]

    # ---- 5) freeze ----
    i = find_one(lines, 'dbg_fill_page <= dbg_fill_page_live;', 'freeze page (fill)')
    ind = indent_of(lines[i])
    lines[i + 1:i + 1] = [
        ind + 'dbg_fill_addr <= dbg_fill_addr_live;\n',
    ]
    i = find_one(lines, 'dbg_wb_page   <= dbg_wb_page_live;', 'freeze page (wb)')
    ind = indent_of(lines[i])
    lines[i + 1:i + 1] = [
        ind + 'dbg_wb_addr   <= dbg_wb_addr_live;\n',
    ]

    save(TARGET, lines)


def main():
    if '--revert' in sys.argv:
        if not os.path.exists(BACKUP):
            sys.exit('no backup at %s' % BACKUP)
        shutil.copyfile(BACKUP, TARGET)
        print('reverted from %s' % BACKUP)
        return
    if not os.path.exists(BACKUP):
        shutil.copyfile(TARGET, BACKUP)
        print('backup -> %s' % BACKUP)
    apply()
    txt = open(TARGET, 'r', newline='').read()
    print('CRLF=%d bare-LF=%d' % (txt.count('\r\n'),
                                  len(re.findall(r'(?<!\r)\n', txt))))
    body = '\n'.join(l.split('//')[0] for l in txt.replace('\r\n', '\n').split('\n'))
    print('begin/end = %d/%d' % (len(re.findall(r'\bbegin\b', body)),
                                 len(re.findall(r'\bend\b', body))))
    probes = {}
    for m in re.finditer(r'mark_debug[^\n]*?reg\s*(\[[^\]]*\])?\s*(\w+)', txt):
        wd = 1
        if m.group(1):
            mm = re.match(r'\[(\d+):(\d+)\]', m.group(1))
            if mm:
                wd = int(mm.group(1)) - int(mm.group(2)) + 1
        probes[m.group(2)] = wd
    print('probes = %d signal / %d bit' % (len(probes), sum(probes.values())))
    for n in ('dbg_fill_addr', 'dbg_wb_addr', 'dbg_fill_page', 'dbg_wb_page',
              'dbg_pmis_r', 'dbg_pmis_w', 'dbg_wb_wl'):
        print('  %-15s %s' % (n, 'OK' if n in probes else 'MISSING'))
    print('  dbg_bufwb_a     %s' % ('STILL PRESENT (bad)' if 'dbg_bufwb_a' in probes
                                    else 'removed OK'))
    for n in ('dbg_ad_d1', 'dbg_fill_addr_live', 'dbg_wb_addr_live'):
        c = len(re.findall(r'\breg\s+(\[[^\]]*\]\s*)?' + n + r'\b', txt))
        print('  decl %-20s x%d %s' % (n, c, 'OK' if c == 1 else 'BAD'))


if __name__ == '__main__':
    main()
