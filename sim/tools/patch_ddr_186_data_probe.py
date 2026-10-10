#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""95th probe v4: NAME the line whose data the write-back / fill actually carries (CRLF-safe).

v3 (commit 5362c54) answered the address question: on the board dbg_rd_reg == dbg_wb_reg,
i.e. sdraddr[14:5] == cache_hi_addr[9:0] at the moment the FSM took the burst.  The address
path is CLEAN, so the +0x100-byte (4 buffer line) shift must come from the DATA side.

Key trick: the self test fills byte@m = (m>>2)&0xFF, so for buffer line k EVERY word's byte
is (k*16 + w) & 0xFF with w in 0..15, and its HIGH NIBBLE is therefore (k & 0xF) for every
word of the line.  So the high nibble of the data a transfer presents NAMES its source line.

v4 latches, for the LATEST buffer-line write-back and the LATEST buffer-line fill:

    dbg_rd_reg[3:0] <= cntrl0_user_input_data[7:4]   at the 2nd data beat of the write-back
    dbg_rd_reg[8:4] <= cache_hi_addr[4:0]            the line the write-back is FOR
    dbg_wb_reg[3:0] <= ram_rdata[7:4]                at the 1st data beat of the fill
    dbg_wb_reg[8:4] <= cache_hi_addr[4:0]            the line the fill is FOR

Reading:
    low nibble == (index & 0xF)   -> that transfer carried its OWN line's data
    low nibble != (index & 0xF)   -> it carried ANOTHER line's data  <-- the bug

The write-back is sampled on its 2nd data beat because cache_QA is only guaranteed to hold
the current word from W_H onwards (30th fix); any word of a line has the same high nibble
anyway, so the only real requirement is "not the previous transaction's data".

No new probe signals: dbg_rd_reg / dbg_wb_reg already exist in the ILA, so Set Up Debug
does NOT need rebuilding.

usage: patch_ddr_186_data_probe.py [--revert]
"""
import sys

PATH = "ddr_186.v"
CRLF = "\r\n"

OLD = (
    "\t\t\t// \u2605\u2605 [95th probe v3] \u76f4\u63a5\u91cf hiaddr -> sdraddr \u7684\u9519\u4f4d\u3002" + CRLF +
    "\t\t\t//   \u677f\u4e0a\u5df2\u77e5\uff1aCPU \u8bfb\u7f13\u51b2\u884c k \u8fd4\u56de W(k+4)\uff08\u786e\u5b9a\u6027 +0x100 \u5b57\u8282 = 4 \u884c\uff09\uff0c" + CRLF +
    "\t\t\t//   \u800c AL=[0x40]=0x10 \u6b63\u786e \u21d2 \u9519\u4f4d\u5728 DDR \u5f80\u8fd4\u3002" + CRLF +
    "\t\t\t//   sdraddr[14:5] \u6052\u7b49\u4e8e cache_hi_addr[9:0]\uff0c\u6240\u4ee5 +4 \u53ea\u80fd\u662f" + CRLF +
    "\t\t\t//   \u201csdraddr \u9501\u5b58\u5230\u7684 hiaddr \u4e0d\u662f\u88ab\u586b\u5145\u7684\u90a3\u4e00\u884c\u201d\u3002" + CRLF +
    "\t\t\t//   \u5728\u6bcf\u4e2a\u7f13\u51b2\u884c FILL \u7684 ack \u4e0a\u5347\u6cbf\u540c\u65f6\u9501\u4e24\u8005\uff1a" + CRLF +
    "\t\t\t//     dbg_rd_reg = sdraddr[14:5]      \uff08FSM \u5b9e\u9645\u62ff\u5230\u7684\u5730\u5740\uff09" + CRLF +
    "\t\t\t//     dbg_wb_reg = cache_hi_addr[9:0] \uff08cache \u5448\u73b0\u7684\u5730\u5740\uff09" + CRLF +
    "\t\t\t//   \u4e24\u8005\u5e94\u76f8\u7b49\uff1b\u82e5 dbg_rd_reg == dbg_wb_reg + 4 \u5219\u9519\u4f4d\u5f97\u8bc1\u3002" + CRLF +
    "\t\t\t//   \uff08\u672a\u65b0\u589e\u63a2\u9488\u4fe1\u53f7 \u21d2 \u4e0d\u7528\u91cd\u5efa Set Up Debug\u3002\u65e7\u7684\u201c\u9996\u4e2a\u201d\u9501\u5b58\u5df2\u77e5 0x000/0x00f\uff0c\u5df2\u5e9f\u3002\uff09" + CRLF +
    "\t\t\tif(dbg_buf_line && (sys_cmd_ack == 2'b11) && (sys_cmd_ack_d1 != 2'b11)) begin" + CRLF +
    "\t\t\t\tdbg_rd_reg   <= sdraddr[14:5];" + CRLF +
    "\t\t\t\tdbg_wb_reg   <= cache_hi_addr[9:0];" + CRLF +
    "\t\t\t\tdbg_rdr_seen <= 1'b1;" + CRLF +
    "\t\t\tend" + CRLF +
    "\t\t\tif(dbg_buf_line && (sys_cmd_ack == 2'b01) && (sys_cmd_ack_d1 != 2'b01))" + CRLF +
    "\t\t\t\tdbg_wbr_seen <= 1'b1;" + CRLF
)

NEW = (
    "\t\t\t// \u2605\u2605\u2605 [95th probe v4] \u7ed9\u201c\u5199\u56de / \u586b\u5145\u9001\u51fa\u7684\u6570\u636e\u201d\u6307\u8ba4\u5b83\u5c5e\u4e8e\u54ea\u4e00\u884c\u3002" + CRLF +
    "\t\t\t//   v3 \u5df2\u7ecf\u8bc1\u660e\u5730\u5740\u901a\u8def\u5e72\u51c0\uff08\u677f\u4e0a dbg_rd_reg == dbg_wb_reg\uff09" + CRLF +
    "\t\t\t//   \u21d2 \u90a3\u4e2a +0x100 \u5b57\u8282\uff08+4 \u884c\uff09\u4f4d\u79fb\u5728**\u6570\u636e\u4fa7**\u3002" + CRLF +
    "\t\t\t//   \u81ea\u6d4b\u56fe\u6848 byte@m=(m>>2)&0xFF \u21d2 \u7f13\u51b2\u884c k \u7684**\u4efb\u4f55\u5b57**\u9ad8\u534a\u5b57\u8282\u90fd = (k & 0xF)" + CRLF +
    "\t\t\t//   \u21d2 \u7528\u9ad8\u534a\u5b57\u8282\u5c31\u80fd\u76f4\u63a5\u6307\u8ba4\u6570\u636e\u6765\u81ea\u54ea\u4e00\u884c\u3002" + CRLF +
    "\t\t\t//   \u9501\u6700\u8fd1\u4e00\u6b21\u7f13\u51b2\u884c\u5199\u56de / \u586b\u5145\uff1a" + CRLF +
    "\t\t\t//     dbg_rd_reg[3:0] = \u5199\u56de\u7b2c 2 \u62cd\u6570\u636e\u7684\u9ad8\u534a\u5b57\u8282\uff1b[8:4] = \u8be5\u5199\u56de**\u5c5e\u4e8e**\u7684\u884c" + CRLF +
    "\t\t\t//     dbg_wb_reg[3:0] = \u586b\u5145\u7b2c 1 \u62cd\u6570\u636e\u7684\u9ad8\u534a\u5b57\u8282\uff1b[8:4] = \u8be5\u586b\u5145**\u5c5e\u4e8e**\u7684\u884c" + CRLF +
    "\t\t\t//   \u5224\u8bfb\uff1a\u4f4e\u534a\u5b57\u8282 == (\u884c\u53f7 & 0xF) \u21d2 \u81ea\u5df1\u7684\u6570\u636e\uff1b" + CRLF +
    "\t\t\t//         \u4e0d\u7b49 \u21d2 \u62ff\u5230\u4e86**\u522b\u7684\u884c**\u7684\u6570\u636e\u3002" + CRLF +
    "\t\t\t//   \uff08\u672a\u65b0\u589e\u63a2\u9488\u4fe1\u53f7 \u21d2 \u4e0d\u7528\u91cd\u5efa Set Up Debug\u3002\uff09" + CRLF +
    "\t\t\tif(dbg_buf_line && (sys_cmd_ack == 2'b11) && (sys_cmd_ack_d1 != 2'b11)) begin" + CRLF +
    "\t\t\t\tdbg_fill_arm <= 1'b1;" + CRLF +
    "\t\t\t\tdbg_fill_idx <= cache_hi_addr[4:0];" + CRLF +
    "\t\t\t\tdbg_rdr_seen <= 1'b1;" + CRLF +
    "\t\t\tend else if(dbg_fill_arm && sys_rd_data_valid) begin" + CRLF +
    "\t\t\t\tdbg_fill_arm <= 1'b0;" + CRLF +
    "\t\t\t\tdbg_wb_reg   <= {1'b0, dbg_fill_idx, ram_rdata[7:4]};" + CRLF +
    "\t\t\tend" + CRLF +
    "\t\t\tif(dbg_buf_line && (sys_cmd_ack == 2'b01) && (sys_cmd_ack_d1 != 2'b01)) begin" + CRLF +
    "\t\t\t\tdbg_wb_arm  <= 1'b1;" + CRLF +
    "\t\t\t\tdbg_wb_idx  <= cache_hi_addr[4:0];" + CRLF +
    "\t\t\t\tdbg_wbr_seen <= 1'b1;" + CRLF +
    "\t\t\tend else if(dbg_wb_arm && sys_wr_data_valid) begin" + CRLF +
    "\t\t\t\tif(dbg_wb_pcnt == 1'b0) dbg_wb_pcnt <= 1'b1;" + CRLF +
    "\t\t\t\telse begin" + CRLF +
    "\t\t\t\t\tdbg_wb_pcnt <= 1'b0;" + CRLF +
    "\t\t\t\t\tdbg_wb_arm  <= 1'b0;" + CRLF +
    "\t\t\t\t\tdbg_rd_reg  <= {1'b0, dbg_wb_idx, cntrl0_user_input_data[7:4]};" + CRLF +
    "\t\t\t\tend" + CRLF +
    "\t\t\tend" + CRLF
)

# extra state registers (not probes - they only feed the two probe registers)
DECL_ANCHOR = "\t(* mark_debug = \"true\", keep = \"true\" *) reg [7:0] dbg_spur_wb_n = 8'h00;"
DECL_NEW = (
    "\t// 95th probe v4 scratch (not probes themselves)\n"
    "\treg        dbg_fill_arm = 1'b0;\n"
    "\treg        dbg_wb_arm   = 1'b0;\n"
    "\treg        dbg_wb_pcnt  = 1'b0;\n"
    "\treg [4:0]  dbg_fill_idx = 5'd0;\n"
    "\treg [4:0]  dbg_wb_idx   = 5'd0;\n"
    + DECL_ANCHOR
)
# normalise the anchor to CRLF form
DECL_ANCHOR_CRLF = DECL_ANCHOR.replace("\n", CRLF)
DECL_NEW = DECL_NEW.replace("\n", CRLF)


def main():
    revert = "--revert" in sys.argv
    raw = open(PATH, "r", encoding="utf-8", newline="").read()
    if raw.count("\r\n") != raw.count("\n"):
        print("ABORT: not pure CRLF")
        return 1
    for name, old, new in (("probe block", OLD, NEW), ("decls", DECL_ANCHOR_CRLF, DECL_NEW)):
        if revert:
            old, new = new, old
        n = raw.count(old)
        if n != 1:
            print("ABORT: %s -> %d occurrences (need 1)" % (name, n))
            return 1
        raw = raw.replace(old, new)
        print("ok  %s" % name)
    open(PATH, "w", encoding="utf-8", newline="").write(raw)
    print("ddr_186.v data probe %s" % ("reverted" if revert else "applied"))
    return 0


sys.exit(main())
