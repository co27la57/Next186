# -*- coding: ascii -*-
"""v5 fill-integrity probe patch for ddr_186.v (CRLF safe, --revert supported).

What it does
------------
1. Closes the provable hole in the v4b probe: the fill-data capture was
   `dbg_fill_arm && sys_rd_data_valid`, but sys_rd_data_valid is also high for
   VGA reads (cmd 2'b10).  Gate it on the burst the DDR FSM actually took,
   exactly like the 91st RTL fix does:
       cache_write_data = (sys_cmd_ack == 2'b11) && sys_rd_data_valid
   Same for the write-back side (2'b01).

2. Replaces the three DEAD SAtURATED probes (dbg_wb_or / dbg_rd_or / dbg_vga_or
   were all saturated on the board -> zero information) with five new ones that
   measure, for buffer line 2, what has NEVER been measured:
       dbg_fill_w0  : first 16-bit word the fill's own burst delivered
       dbg_fill_wl  : last  16-bit word the fill's own burst delivered
       dbg_fill_n   : own-burst valid pulse count in the window (expect 32)
       dbg_fill_x   : FOREIGN valid pulse count in the same window
       dbg_fill_full: own-burst reached 32 pulses
   Expected for line 2 (pattern byte@m=(m>>2)&0xFF): 2020 / 2F2F / 32 / 0 / 1.

3. Freezes all five on the same CPU write to port 0x00E5 as v4b (the SD stage
   writes the same buffer later, so a "latest wins" latch would be polluted).

Usage
-----
  python patch_ddr_186_v5_fillprobe.py            # apply
  python patch_ddr_186_v5_fillprobe.py --revert   # undo
"""
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
TARGET = os.path.join(ROOT, 'ddr_186.v')
BACKUP = os.path.join(ROOT, 'sim', 'run', 'ddr_186.v.preV5')


def load(path):
    with open(path, 'r', newline='') as f:
        return f.readlines()


def save(path, lines):
    # ddr_186.v must stay pure CRLF (project rule): normalise every line ending.
    txt = ''.join(lines).replace('\r\n', '\n').replace('\n', '\r\n')
    with open(path, 'w', newline='') as f:
        f.write(txt)


def find_one(lines, needle, what):
    hits = [i for i, l in enumerate(lines) if needle in l]
    if len(hits) != 1:
        sys.exit('ANCHOR FAIL (%s): %d hits for %r' % (what, len(hits), needle))
    return hits[0]


def indent_of(line):
    return line[:len(line) - len(line.lstrip('\t'))]


def apply():
    lines = load(TARGET)
    orig = list(lines)

    # ---- 1) close the hole on the fill data capture --------------------
    i = find_one(lines, 'dbg_fill_arm && sys_rd_data_valid) begin', 'fill gate')
    lines[i] = lines[i].rstrip('\r\n').replace(
        'end else if(dbg_fill_arm && sys_rd_data_valid) begin',
        "end else if(dbg_fill_arm && sys_rd_data_valid && (sys_cmd_ack == 2'b11)) begin"
    ) + '\r\n'

    # ---- 2) close the hole on the write-back data capture --------------
    i = find_one(lines, 'dbg_wb_arm && sys_wr_data_valid) begin', 'wb gate')
    lines[i] = lines[i].rstrip('\r\n').replace(
        'end else if(dbg_wb_arm && sys_wr_data_valid) begin',
        "end else if(dbg_wb_arm && sys_wr_data_valid && (sys_cmd_ack == 2'b01)) begin"
    ) + '\r\n'

    # ---- 3) declarations: drop the 3 dead OR probes, add the 5 new ones
    i0 = find_one(lines, 'reg [31:0] dbg_wb_or', 'wb_or decl')
    ind = indent_of(lines[i0])
    assert 'reg [15:0] dbg_rd_or' in lines[i0 + 1], 'decl order changed'
    assert 'reg [15:0] dbg_vga_or' in lines[i0 + 2], 'decl order changed'
    new_decl = [
        ind + '// \u2605\u2605\u2605 [v5 probe, 2026-09-27] fill integrity (line 2).\n',
        ind + '//   v4b captured fill data with `dbg_fill_arm && sys_rd_data_valid`, which\n',
        ind + '//   also fires for VGA reads -> the board reading nib=0 was not usable.\n',
        ind + '//   These five are gated on the fill\'s OWN burst (sys_cmd_ack == 2\'b11).\n',
        ind + '//   Expect (pattern byte@m=(m>>2)&0xFF): w0=0x2020 wl=0x2F2F n=32 x=0 full=1\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg [15:0] dbg_fill_w0   = 16\'h0000;\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg [15:0] dbg_fill_wl   = 16\'h0000;\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg [5:0]  dbg_fill_n    = 6\'d0;\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg [5:0]  dbg_fill_x    = 6\'d0;\n',
        ind + '(* mark_debug = "true", keep = "true" *) reg        dbg_fill_full = 1\'b0;\n',
        ind + '// v5 window scratch (not probes)\n',
        ind + 'reg        dbg_fw_act  = 1\'b0;\n',
        ind + 'reg [5:0]  dbg_fw_n    = 6\'d0;\n',
        ind + 'reg [5:0]  dbg_fw_x    = 6\'d0;\n',
        ind + 'reg        dbg_fw_full = 1\'b0;\n',
        ind + 'reg [15:0] dbg_fw_w0   = 16\'d0;\n',
        ind + 'reg [15:0] dbg_fw_wl   = 16\'d0;\n',
    ]
    lines[i0:i0 + 3] = new_decl

    # ---- 4) resets ------------------------------------------------------
    i = find_one(lines, "dbg_wb_or      <= 32'h00000000;", 'wb_or reset')
    assert "dbg_rd_or      <= 16'h0000;" in lines[i + 1], 'reset order changed'
    assert "dbg_vga_or     <= 16'h0000;" in lines[i + 2], 'reset order changed'
    rind = indent_of(lines[i])
    new_reset = [
        rind + "dbg_fill_w0   <= 16'h0000;\n",
        rind + "dbg_fill_wl   <= 16'h0000;\n",
        rind + "dbg_fill_n    <= 6'd0;\n",
        rind + "dbg_fill_x    <= 6'd0;\n",
        rind + "dbg_fill_full <= 1'b0;\n",
        rind + "dbg_fw_act    <= 1'b0;\n",
        rind + "dbg_fw_n      <= 6'd0;\n",
        rind + "dbg_fw_x      <= 6'd0;\n",
        rind + "dbg_fw_full   <= 1'b0;\n",
        rind + "dbg_fw_w0     <= 16'd0;\n",
        rind + "dbg_fw_wl     <= 16'd0;\n",
    ]
    lines[i:i + 3] = new_reset

    # ---- 5) delete the three dead OR accumulations ----------------------
    i = find_one(lines, 'dbg_wb_or <= dbg_wb_or | cntrl0_user_input_data', 'wb_or acc')
    del lines[i]
    i = find_one(lines, 'dbg_rd_or <= dbg_rd_or | ram_rdata', 'rd_or acc')
    del lines[i]
    i = find_one(lines, 'dbg_vga_or <= dbg_vga_or | ram_rdata', 'vga_or acc')
    del lines[i]

    # ---- 6) insert the v5 window machine before the v4b freeze ---------
    # anchor: "CPU \u5199\u7aef\u53e3 0x00E5" (CPU write to port 0x00E5) - unique
    j = find_one(lines, 'CPU \u5199\u7aef\u53e3 0x00E5', 'freeze anchor')
    wind = indent_of(lines[j])
    block = [
        wind + '// \u2605\u2605\u2605 [v5, 2026-09-27] fill-integrity window: only the fill\'s OWN burst.\n',
        wind + '//   v4b used `dbg_fill_arm && sys_rd_data_valid`, but sys_rd_data_valid is also\n',
        wind + '//   high for VGA reads (2\'b10) -> the captured nibble may have been VGA data\n',
        wind + '//   (the board reads dbg_fill_foreign = 1, so foreign data DOES arrive inside\n',
        wind + '//   the fill window).  Hence v4b\'s dbg_wb_reg[3:0] = 0 is NOT usable evidence.\n',
        wind + '//   This window reports, for buffer line 2:\n',
        wind + '//     dbg_fw_w0 / dbg_fw_wl = first / last word the OWN burst delivered\n',
        wind + '//     dbg_fw_n             = own-burst valid count   (expect 32)\n',
        wind + '//     dbg_fw_x             = foreign valid count     (expect 0)\n',
        wind + '//     dbg_fw_full          = own burst reached 32 pulses\n',
        wind + '//   n = 64 => the transaction was served TWICE (95th fix ineffective on board);\n',
        wind + '//   n < 32 => the fill never completed (data incomplete / borrowed).\n',
        wind + 'if(dbg_fw_act) begin\n',
        wind + '\tif(sys_rd_data_valid) begin\n',
        wind + '\t\tif(sys_cmd_ack == 2\'b11) begin\n',
        wind + '\t\t\tif(dbg_fw_n == 6\'d0) dbg_fw_w0 <= ram_rdata;\n',
        wind + '\t\t\tdbg_fw_wl <= ram_rdata;\n',
        wind + '\t\t\tif(dbg_fw_n < 6\'d63) dbg_fw_n <= dbg_fw_n + 1\'b1;\n',
        wind + '\t\t\tif(dbg_fw_n >= 6\'d31) dbg_fw_full <= 1\'b1;\n',
        wind + '\t\tend else if(dbg_fw_x < 6\'d63)\n',
        wind + '\t\t\tdbg_fw_x <= dbg_fw_x + 1\'b1;\n',
        wind + '\tend\n',
        wind + '\tif((sys_cmd_ack != 2\'b11) && !ddr_rd) dbg_fw_act <= 1\'b0;\n',
        wind + 'end else if(dbg_buf_line && (cache_hi_addr[4:0] == 5\'d2) &&\n',
        wind + '            (sys_cmd_ack == 2\'b11) && (sys_cmd_ack_d1 != 2\'b11)) begin\n',
        wind + '\tdbg_fw_act  <= 1\'b1;\n',
        wind + '\tdbg_fw_n    <= 6\'d0;\n',
        wind + '\tdbg_fw_x    <= 6\'d0;\n',
        wind + '\tdbg_fw_full <= 1\'b0;\n',
        wind + 'end\n',
    ]
    lines[j:j] = block

    # ---- 7) extend the 0x00E5 freeze -----------------------------------
    i = find_one(lines, 'dbg_wb_reg <= {1\'b0, dbg_v4_wb_live};', 'freeze body')
    ind = indent_of(lines[i])
    add = [
        ind + 'dbg_fill_w0   <= dbg_fw_w0;\n',
        ind + 'dbg_fill_wl   <= dbg_fw_wl;\n',
        ind + 'dbg_fill_n    <= dbg_fw_n;\n',
        ind + 'dbg_fill_x    <= dbg_fw_x;\n',
        ind + 'dbg_fill_full <= dbg_fw_full;\n',
    ]
    lines[i + 1:i + 1] = add

    save(TARGET, lines)
    print('patched: %d -> %d lines' % (len(orig), len(lines)))
    return True


def revert():
    if not os.path.exists(BACKUP):
        sys.exit('no backup at %s' % BACKUP)
    shutil.copyfile(BACKUP, TARGET)
    print('reverted from %s' % BACKUP)
    return True


def main():
    if '--revert' in sys.argv:
        revert()
        return
    if not os.path.exists(BACKUP):
        shutil.copyfile(TARGET, BACKUP)
        print('backup -> %s' % BACKUP)
    apply()
    # ---- verification --------------------------------------------------
    with open(TARGET, 'r', newline='') as f:
        txt = f.read()
    crlf = txt.count('\r\n')
    bare = len(re.findall(r'(?<!\r)\n', txt))
    print('CRLF=%d bare-LF=%d' % (crlf, bare))
    body = '\n'.join(l.split('//')[0] for l in txt.replace('\r\n', '\n').split('\n'))
    nb = len(re.findall(r'\bbegin\b', body))
    ne = len(re.findall(r'\bend\b', body))
    print('begin/end = %d/%d' % (nb, ne))

    # probe budget
    probes = []
    for m in re.finditer(r'mark_debug[^\n]*?reg\s*(\[[^\]]*\])?\s*(\w+)', txt):
        w = m.group(1)
        width = 1
        if w:
            mm = re.match(r'\[(\d+):(\d+)\]', w)
            if mm:
                width = int(mm.group(1)) - int(mm.group(2)) + 1
        probes.append((m.group(2), width))
    seen = {}
    for n, w in probes:
        seen[n] = w
    print('probes = %d signal / %d bit' % (len(seen), sum(seen.values())))
    names = sorted(seen)
    for n in ('dbg_fill_w0', 'dbg_fill_wl', 'dbg_fill_n', 'dbg_fill_x', 'dbg_fill_full'):
        print('  %-14s %s' % (n, 'OK' if n in seen else 'MISSING'))
    for n in ('dbg_wb_or', 'dbg_rd_or', 'dbg_vga_or'):
        print('  %-14s %s' % (n, 'STILL PRESENT (bad)' if n in seen else 'removed OK'))
    # every scratch name declared exactly once
    for n in ('dbg_fw_act', 'dbg_fw_n', 'dbg_fw_x', 'dbg_fw_full', 'dbg_fw_w0', 'dbg_fw_wl'):
        c = len(re.findall(r'\breg\s+(\[[^\]]*\]\s*)?' + n + r'\b', txt))
        print('  decl %-12s x%d %s' % (n, c, 'OK' if c == 1 else 'BAD'))


if __name__ == '__main__':
    main()
