#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Swap the dead 94th probe set for the 95th "spurious burst" counters in ddr_186.v.

The 94th probe's high-nibble ORs (dbg_cpu_w2 / dbg_wb2_hi / dbg_rd2_hi) all saturate at
4'hF on the board, because the SD driver writes real SD payload (arbitrary bytes, so
including 0xF?) into the SAME F000:0000 buffer that the self test uses.  They carry no
information.  Replace them (and the two now-unused line-match wires) with two counters
that measure the bug the 95th fix removes, using ONLY cache_controller's module-boundary
ports so nothing is placed inside the cache or the CPU:

  dbg_spur_wb_n : sys_cmd_ack rose to 2'b01 while ddr_wr == 0  (write burst nobody asked for)
  dbg_spur_rd_n : sys_cmd_ack rose to 2'b11 while ddr_rd == 0  (fill  burst nobody asked for)

Measured in the harness: pre-fix WB=16 / RD=92, post-fix WB=0 / RD=0.

CRLF-safe.  Run:  python sim/tools/patch_ddr_186_95th_probe.py [--revert]
"""
import sys

PATH = "ddr_186.v"
CRLF = "\r\n"


def lines(*ls):
    return "".join(l + CRLF for l in ls)


# ---------------------------------------------------------------- P1: declarations
P1_OLD = lines(
    "\t// ** [94th probe, 2026-09-26] Name the SOURCE LINE of the buffer-line-2 data, with a",
    "\t//   statistic that a single stray word cannot saturate.  The 93rd OR pair failed: one",
    "\t//   0xFF word drives a 32-bit OR to 0xFF, and 0xFF is not in the self-test pattern at",
    "\t//   all (line 2 = 0x20..0x2F, line 5 = 0x50..0x5F), so it could not say which side or",
    "\t//   which line the data came from.  Every byte of buffer line k shares the HIGH NIBBLE",
    "\t//   (k >> 4), so the OR of just the high nibble names the source line and is immune to",
    "\t//   both word phase and single-word saturation:",
    "\t//     dbg_cpu_w2[3:0] = OR of DOUT[7:4] on every CPU store to tag 0x1E0 / index 2",
    "\t//                       -> what the CPU actually wrote        (expected 4'h2)",
    "\t//     dbg_wb2_hi[3:0] = OR of cntrl0_user_input_data[7:4] over the line-2 write-back",
    "\t//                       -> what the write-back presented       (expected 4'h2)",
    "\t//     dbg_rd2_hi[3:0] = OR of ram_rdata[7:4] while the cache owns the read, line 2",
    "\t//                       -> what the fill returned              (expected 4'h2)",
    "\t//     dbg_wb2_cnt / dbg_rd2_cnt = event counts (prove the capture happened)",
    "\t//   Reading: 4'h5 = the data of line+3 ; 4'hF = 0xFF / erased (never written)",
    "\t//     cpu=2 wb=2 rd=2 -> data path is clean throughout; the fault is elsewhere",
    "\t//     cpu=2 wb=5      -> the WRITE-BACK read the wrong line (BRAM port-A way/word)",
    "\t//     cpu=2 wb=2 rd=5 -> the FILL returned the wrong line",
    "\t//     cpu!=2          -> the CPU store to line 2 never landed",
    "\t//   Gate note: MREQ is only an implicit net in this file, so the CPU store is gated on",
    "\t//   WR && CPU_CE (both explicitly declared) plus ADDR being tag 0x1E0 / index 2.",
    "\t(* mark_debug = \"true\", keep = \"true\" *) reg [3:0] dbg_cpu_w2  = 4'h0;",
    "\t(* mark_debug = \"true\", keep = \"true\" *) reg [3:0] dbg_wb2_hi  = 4'h0;",
    "\t(* mark_debug = \"true\", keep = \"true\" *) reg [3:0] dbg_rd2_hi  = 4'h0;",
    "\t(* mark_debug = \"true\", keep = \"true\" *) reg [3:0] dbg_wb2_cnt = 4'd0;",
    "\t(* mark_debug = \"true\", keep = \"true\" *) reg [3:0] dbg_rd2_cnt = 4'd0;",
)

P1_NEW = lines(
    "\t// \u2605\u2605\u2605 [95th probe, 2026-09-26] \u76f4\u63a5\u6570\u201cFSM \u63a5\u53d7\u4e86 cache \u5e76\u6ca1\u5728\u8bf7\u6c42\u7684 burst\u201d\u3002",
    "\t//   \u5224\u636e\u53d6 sys_cmd_ack \u7684**\u4e0a\u5347\u6cbf**\uff08= FSM \u521a\u63a5\u53d7\u4e00\u6761\u547d\u4ee4\u7684\u90a3\u4e00\u523b\uff09\uff0c\u95ee\u4e00\u53e5",
    "\t//   \u201ccache \u8fd9\u4e00\u62cd\u5230\u5e95\u5728\u8bf7\u6c42\u4ec0\u4e48\uff1f\u201d\uff1a",
    "\t//     dbg_spur_wb_n : ack \u5347\u5230 2'b01\uff08\u5199 burst\uff09\u4f46 ddr_wr==0  \u2192 \u4f2a\u5199\u56de burst",
    "\t//     dbg_spur_rd_n : ack \u5347\u5230 2'b11\uff08\u586b\u5145 burst\uff09\u4f46 ddr_rd==0 \u2192 \u4f2a\u586b\u5145 burst",
    "\t//   95th \u4fee\u590d\u524d\uff1a\u6bcf\u6761 cache \u4e8b\u52a1\u5404\u591a\u4e00\u6b21\uff08\u53f0\u67b6\u5b9e\u6d4b WB=16 / RD=92\uff09\uff1b",
    "\t//   95th \u4fee\u590d\u540e\u5fc5\u987b**\u6052 0**\uff08\u53f0\u67b6\u5b9e\u6d4b WB=0 / RD=0\uff09\u3002",
    "\t//   \u53ea\u7528 cache_controller \u7684**\u6a21\u5757\u8fb9\u754c\u7aef\u53e3**\uff08sys_cmd_ack / ddr_wr / ddr_rd\uff09\uff0c",
    "\t//   \u4e0d\u5f80 cache \u6216 CPU \u5185\u90e8\u653e\u4efb\u4f55\u4e1c\u897f\u3002",
    "\t//   \u2605 94th \u7684 5 \u4e2a\u9ad8\u4f4d\u534a\u5b57\u8282 OR \u63a2\u9488\u5df2\u5220\u9664\uff1aSD \u9a71\u52a8\u4f1a\u628a\u771f\u5b9e SD \u6570\u636e",
    "\t//     \uff08\u542b 0xF? \u5b57\u8282\uff09\u5199\u8fdb**\u540c\u4e00\u4e2a** F000:0000 \u7f13\u51b2\u533a\uff0c\u6240\u4ee5 cpu/wb/rd",
    "\t//     \u4e09\u4e2a OR \u4e00\u5f8b\u9971\u548c\u5230 4'hF\uff0c\u96f6\u4fe1\u606f\u91cf\uff08\u677f\u4e0a\u5b9e\u6d4b cpu=f wb=f rd=f\uff09\u3002",
    "\t//     \u817e\u51fa\u7684 20 bit \u9884\u7b97\u7ed9\u672c\u63a2\u9488\uff0816 bit\uff09\u3002",
    "\t(* mark_debug = \"true\", keep = \"true\" *) reg [7:0] dbg_spur_wb_n = 8'h00;",
    "\t(* mark_debug = \"true\", keep = \"true\" *) reg [7:0] dbg_spur_rd_n = 8'h00;",
)

# ---------------------------------------------------------------- P2: line-match wires
P2_OLD = lines(
    "\t// [93rd probe] tag 0x1E0 (SD buffer) AND index 2 - the line the self test reads back",
    "\twire dbg_l2 = (cache_hi_addr[14:5] == 10'h1E0) && (cache_hi_addr[4:0] == 5'd2);",
    "\t// [94th probe] the same line, but on the CPU address bus (unit186's ADDR), for the",
    "\t//   \"did the CPU store to line 2 actually happen\" capture",
    "\twire dbg_cpu_l2 = (ADDR[20:11] == 10'h1E0) && (ADDR[10:6] == 5'd2);",
)
P2_NEW = ""

# ---------------------------------------------------------------- P3: reset values
P3_OLD = lines(
    "\t\t\tdbg_cpu_w2     <= 4'h0;",
    "\t\t\tdbg_wb2_hi     <= 4'h0;",
    "\t\t\tdbg_rd2_hi     <= 4'h0;",
    "\t\t\tdbg_wb2_cnt    <= 4'd0;",
    "\t\t\tdbg_rd2_cnt    <= 4'd0;",
)
P3_NEW = lines(
    "\t\t\tdbg_spur_wb_n  <= 8'h00;",
    "\t\t\tdbg_spur_rd_n  <= 8'h00;",
)

# ---------------------------------------------------------------- P4: counter logic
P4_OLD = lines(
    "\t\t\t// ** [94th probe] high-nibble source-line captures for buffer line 2",
    "\t\t\tif(WR && CPU_CE && dbg_cpu_l2) dbg_cpu_w2 <= dbg_cpu_w2 | DOUT[7:4];",
    "\t\t\tif(ddr_wr && dbg_l2) dbg_wb2_hi <= dbg_wb2_hi | cntrl0_user_input_data[7:4];",
    "\t\t\tif(ddr_rd && dbg_l2 && sys_rd_data_valid) dbg_rd2_hi <= dbg_rd2_hi | ram_rdata[7:4];",
    "\t\t\tif(ddr_wr && !s_ddr_wr && dbg_l2) begin",
    "\t\t\t\tif(dbg_wb2_cnt != 4'hF) dbg_wb2_cnt <= dbg_wb2_cnt + 1'b1;",
    "\t\t\tend",
    "\t\t\tif(ddr_rd && !s_ddr_rd && dbg_l2) begin",
    "\t\t\t\tif(dbg_rd2_cnt != 4'hF) dbg_rd2_cnt <= dbg_rd2_cnt + 1'b1;",
    "\t\t\tend",
)
P4_NEW = lines(
    "\t\t\t// \u2605\u2605\u2605 [95th probe] \u4f2a burst \u8ba1\u6570\uff08\u5224\u636e\uff1aack \u4e0a\u5347\u6cbf + cache \u5f53\u65f6\u6ca1\u5728\u8bf7\u6c42\uff09",
    "\t\t\t//   95th \u4fee\u590d\u524d WB=16 / RD=92\uff1b\u4fee\u590d\u540e\u5fc5\u987b\u6052 0\u3002",
    "\t\t\tif((sys_cmd_ack != 2'b00) && (sys_cmd_ack_d1 == 2'b00)) begin",
    "\t\t\t\tif(sys_cmd_ack == 2'b01 && !ddr_wr)",
    "\t\t\t\t\tif(dbg_spur_wb_n != 8'hFF) dbg_spur_wb_n <= dbg_spur_wb_n + 1'b1;",
    "\t\t\t\tif(sys_cmd_ack == 2'b11 && !ddr_rd)",
    "\t\t\t\t\tif(dbg_spur_rd_n != 8'hFF) dbg_spur_rd_n <= dbg_spur_rd_n + 1'b1;",
    "\t\t\tend",
)

PATCHES = [("P1: 94th decls -> 95th counters", P1_OLD, P1_NEW),
           ("P2: drop dbg_l2 / dbg_cpu_l2 wires", P2_OLD, P2_NEW),
           ("P3: reset values", P3_OLD, P3_NEW),
           ("P4: counter logic", P4_OLD, P4_NEW)]


def main():
    revert = "--revert" in sys.argv
    raw = open(PATH, "r", encoding="utf-8", newline="").read()
    if raw.count("\r\n") != raw.count("\n"):
        print("ABORT: file is not pure CRLF")
        return 1
    txt = raw
    for name, old, new in PATCHES:
        if revert:
            old, new = new, old
        n = txt.count(old)
        if n != 1:
            print("ABORT: %s -> found %d occurrences (need exactly 1)" % (name, n))
            return 1
        txt = txt.replace(old, new)
        print("ok  %s" % name)
    open(PATH, "w", encoding="utf-8", newline="").write(txt)
    print("written %s  (%s)" % (PATH, "REVERTED" if revert else "95th probe applied"))
    return 0


sys.exit(main())
