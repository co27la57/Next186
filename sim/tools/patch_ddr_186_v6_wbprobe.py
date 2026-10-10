#!/usr/bin/env python3
# -*- coding: ascii -*-
"""v6 (rework) - WRITE-BACK integrity + the page the DDR FSM ACTUALLY USED.

Applies on top of the v5-patched ddr_186.v.

WHY THE REWORK
--------------
The first v6 used 8-bit free-running timestamps (dbg_wb_ts / dbg_fill_ts) to decide
whether the line-2 write-back landed before the line-2 fill.  That is WRONG: the
harness self-test runs 84,401 clk_sdr cycles, so an 8-bit counter wraps every 256
cycles and the two stamps carry no ordering information at all (the harness even
printed "ordering OK" on pure wrap coincidence).  Dropped.

WHAT IT MEASURES INSTEAD
------------------------
v5 convicted the DDR CONTENT at buffer line 2 (fill w0=0x0000 / wl=0x0C00 with a
complete, unpolluted own burst) while dbg_rd_reg=0x022 proves a real line-2 AXI
WRITE burst carrying line-2 data also happened.  The remaining split is
  (a) the write-back landed at a different address, or
  (b) the fill read DDR before the write-back landed.
Both show up in the ADDRESS PAGE that the DDR FSM actually consumed
(sdraddr[23:15] as seen by the FSM, i.e. sdraddr delayed 2), so measure that
directly instead of a timestamp.

New probes (42 bit)
-------------------
  dbg_wb_wl[15:0]   : last word the line-2 WRITE-BACK's own burst delivered
                      (gate sys_cmd_ack == 2'b01).  Expect 0x2F2F.
  dbg_fill_page[8:0]: page the FSM used at the line-2 FILL ack.    Expect 0x015.
  dbg_wb_page[8:0]  : page the FSM used at the line-2 WRITE-BACK ack. Expect 0x015.
  dbg_pmis_r[3:0]   : FILL acks where the used page != the page implied by the
                      current hiaddr (memmap_mux) -> stale/foreign address. Expect 0.
  dbg_pmis_w[3:0]   : same for WRITE-BACK acks. Expect 0.
"""
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
TARGET = os.path.join(ROOT, 'ddr_186.v')
BACKUP = os.path.join(ROOT, 'sim', 'run', 'ddr_186.v.preV6')


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

    # ---- 1) sdraddr page delay chain (2 stages) in the main clk_sdr block ----
    i = find_one(lines, 'sys_cmd_ack_d1 <= sys_cmd_ack;', 'ack delay')
    ind = indent_of(lines[i])
    lines[i + 1:i + 1] = [
        ind + '\n',
        ind + '// v6: page the DDR FSM actually consumed (sdraddr delayed 2 clk_sdr).\n',
        ind + "//   sdraddr(k) = f(hiaddr(k-1)); the FSM samples sdraddr(k-1) at edge k.\n",
        ind + 'dbg_pg_d1 <= sdraddr[23:15];\n',
    ]

    # ---- 2) declarations ----
    i = find_one(lines, 'reg [15:0] dbg_fw_wl', 'v5 scratch tail')
    ind = indent_of(lines[i])
    lines[i + 1:i + 1] = [
        ind + '// v6 (rework): write-back integrity + the page the DDR FSM actually used.\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg [15:0] dbg_wb_wl    = 16\'h0000;\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg [8:0]  dbg_fill_page = 9\'h000;\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg [8:0]  dbg_wb_page   = 9\'h000;\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg [5:0]  dbg_pmis_r    = 4\'h0;\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg [5:0]  dbg_pmis_w    = 4\'h0;\n',
        ind + 'reg [8:0]  dbg_pg_d1 = 9\'h000;   // sdraddr[23:15] delayed 1 clk_sdr\n',
        ind + 'reg        dbg_bw_act = 1\'b0;\n',
        ind + 'reg [5:0]  dbg_bw_n   = 6\'d0;\n',
        ind + 'reg [15:0] dbg_bw_wl  = 16\'d0;\n',
    ]

    # ---- 3) resets ----
    i = find_one(lines, "dbg_fw_wl     <= 16'd0;", 'v5 reset tail')
    ind = indent_of(lines[i])
    lines[i + 1:i + 1] = [
        ind + "dbg_wb_wl    <= 16'h0000;\n",
        ind + "dbg_fill_page <= 9'h000;\n",
        ind + "dbg_wb_page   <= 9'h000;\n",
        ind + "dbg_pmis_r    <= 6'h0;\n",
        ind + "dbg_pmis_w    <= 6'h0;\n",
        ind + "dbg_bw_act    <= 1'b0;\n",
        ind + "dbg_bw_n      <= 6'd0;\n",
        ind + "dbg_bw_wl     <= 16'd0;\n",
    ]

    # ---- 4) window + page latch + mismatch counters, before the freeze ----
    j = find_one(lines, 'CPU \u5199\u7aef\u53e3 0x00E5', 'freeze anchor')
    w = indent_of(lines[j])
    blk = [
        w + '// \u2605\u2605\u2605 [v6, 2026-09-27] write-back integrity + the page the DDR FSM used.\n',
        w + '//   v5: the line-2 fill\'s own burst is complete (n=32, full=1) and unpolluted (x=0),\n',
        w + '//   yet it returns w0=0x0000 / wl=0x0C00 - not the self-test pattern, not the BIOS.\n',
        w + '//   dbg_rd_reg=0x022 proves a real line-2 AXI write burst carrying line-2 data also\n',
        w + '//   happened.  So either that write landed elsewhere, or the fill read DDR before it\n',
        w + '//   landed.  Both show up in the PAGE the FSM actually consumed (dbg_pg_d1).\n',
        w + '//   dbg_pmis_* counts acks where the used page disagrees with the page implied by the\n',
        w + '//   CURRENT hiaddr (memmap_mux): non-zero => hiaddr was moving when the FSM sampled.\n',
        w + '//   8-bit timestamps were tried first and abandoned: the self-test spans ~84k clk_sdr\n',
        w + '//   cycles, so an 8-bit counter wraps and carries no ordering information.\n',
        w + 'if(dbg_bw_act) begin\n',
        w + '\tif(sys_wr_data_valid && (sys_cmd_ack == 2\'b01)) begin\n',
        w + '\t\tdbg_bw_wl <= cntrl0_user_input_data;\n',
        w + '\t\tif(dbg_bw_n < 6\'d63) dbg_bw_n <= dbg_bw_n + 1\'b1;\n',
        w + '\tend\n',
        w + '\tif((sys_cmd_ack != 2\'b01) && !ddr_wr) dbg_bw_act <= 1\'b0;\n',
        w + 'end else if(dbg_buf_line && (cache_hi_addr[4:0] == 5\'d2) &&\n',
        w + '            (sys_cmd_ack == 2\'b01) && (sys_cmd_ack_d1 != 2\'b01)) begin\n',
        w + '\tdbg_bw_act <= 1\'b1;\n',
        w + '\tdbg_bw_n   <= 6\'d0;\n',
        w + 'end\n',
        w + 'if((sys_cmd_ack != 2\'b00) && (sys_cmd_ack_d1 == 2\'b00)) begin\n',
        w + '\tif(sys_cmd_ack == 2\'b11) begin\n',
        w + '\t\tif(dbg_buf_line && (cache_hi_addr[4:0] == 5\'d2)) dbg_fill_page <= dbg_pg_d1;\n',
        w + '\t\tif((dbg_pg_d1 != memmap_mux) && (dbg_pmis_r != 4\'hF)) dbg_pmis_r <= dbg_pmis_r + 1\'b1;\n',
        w + '\tend\n',
        w + '\tif(sys_cmd_ack == 2\'b01) begin\n',
        w + '\t\tif(dbg_buf_line && (cache_hi_addr[4:0] == 5\'d2)) dbg_wb_page <= dbg_pg_d1;\n',
        w + '\t\tif((dbg_pg_d1 != memmap_mux) && (dbg_pmis_w != 4\'hF)) dbg_pmis_w <= dbg_pmis_w + 1\'b1;\n',
        w + '\tend\n',
        w + 'end\n',
    ]
    lines[j:j] = blk

    # ---- 5) freeze ----
    i = find_one(lines, 'dbg_fill_full <= dbg_fw_full;', 'v5 freeze tail')
    ind = indent_of(lines[i])
    lines[i + 1:i + 1] = [
        ind + 'dbg_wb_wl    <= dbg_bw_wl;\n',
        ind + 'dbg_fill_page <= dbg_fill_page_live;\n',
        ind + 'dbg_wb_page   <= dbg_wb_page_live;\n',
    ]

    # the page probes must track live and freeze on 0x00E5 (latest-wins pollution)
    i = find_one(lines, 'reg [8:0]  dbg_pg_d1', 'pg decl')
    ind = indent_of(lines[i])
    lines[i + 1:i + 1] = [
        ind + 'reg [8:0]  dbg_fill_page_live = 9\'h000;\n',
        ind + 'reg [8:0]  dbg_wb_page_live   = 9\'h000;\n',
    ]
    txt = ''.join(lines)
    txt = txt.replace('dbg_fill_page <= dbg_pg_d1;', 'dbg_fill_page_live <= dbg_pg_d1;')
    txt = txt.replace('dbg_wb_page <= dbg_pg_d1;', 'dbg_wb_page_live <= dbg_pg_d1;')
    lines = txt.splitlines(True)

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
    for n in ('dbg_wb_wl', 'dbg_fill_page', 'dbg_wb_page', 'dbg_pmis_r', 'dbg_pmis_w'):
        print('  %-14s %s' % (n, 'OK' if n in probes else 'MISSING'))
    for n in ('dbg_pg_d1', 'dbg_pg_d1', 'dbg_bw_act', 'dbg_bw_n', 'dbg_bw_wl',
              'dbg_fill_page_live', 'dbg_wb_page_live'):
        c = len(re.findall(r'\breg\s+(\[[^\]]*\]\s*)?' + n + r'\b', txt))
        print('  decl %-20s x%d %s' % (n, c, 'OK' if c == 1 else 'BAD'))
    # a probe must never be written in two places (duplicate assignment = last-wins bug)
    for n in ('dbg_fill_page_live', 'dbg_wb_page_live', 'dbg_wb_wl'):
        c = len(re.findall(r'\b' + n + r'\s*<=', txt))
        print('  assign %-18s x%d %s' % (n, c, 'OK' if c <= 2 else 'CHECK'))


if __name__ == '__main__':
    main()
