#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Apply the 95th fix to ddr_186.v, preserving CRLF line endings exactly.

95th fix: one AXI burst per cache transaction.
  `ddr_wr` / `ddr_rd` are LEVELS covering the whole cache transaction (~144 clk_sdr),
  but the AXI FSM finishes its 16-beat burst in ~80 clk_sdr and then re-samples the
  command register during its 6-cycle post-burst IDLE window.  The command register is
  derived from the 1-cycle-delayed s_ddr_wr/s_ddr_rd, so it still reads 2'b01/2'b11 and
  the FSM launches a WHOLE SECOND burst for the same line.  For a write-back the second
  burst re-transmits word 0 sixteen times (wb_pcnt is forced to 0 while ddr_wr is low)
  and destroys the line that was just written back correctly.

  Fix: `cache_cmd_done` marks the currently presented cache request as already served;
  it is cleared whenever the cache presents no request at all, so it re-arms by itself
  for the next transaction.  The command TYPE and the ADDRESS still come from the LIVE
  s_ddr_wr/s_ddr_rd and cache_hi_addr - deliberately NOT latched - so a VGA starvation
  that delays the FSM past the end of the cache pulse can never make the FSM serve a
  FILL for a WRITE-BACK request (that would dead-lock the cache in STATE 011).

Run:  python sim/tools/patch_ddr_186_95th.py [--revert]
"""
import sys

PATH = "ddr_186.v"
CRLF = "\r\n"

# ---------------------------------------------------------------- patch A
A_OLD = "\treg s_ddr_wr = 1'b0;" + CRLF

A_NEW = (
    "\treg s_ddr_wr = 1'b0;" + CRLF +
    "\t// \u2605\u2605 95th \u4fee\u590d\uff082026-09-26\uff09\uff1a\u4e00\u6761 cache \u4e8b\u52a1\u53ea\u5141\u8bb8\u4e00\u6b21 AXI burst" + CRLF +
    "\t//   \u2014\u2014 cache_cmd_done \u6807\u8bb0\u201c\u5f53\u524d\u5448\u73b0\u7684 cache \u8bf7\u6c42\u5df2\u7ecf\u88ab\u670d\u52a1\u8fc7\u4e00\u6b21 burst\u201d\uff0c" + CRLF +
    "\t//   \u5f53 cache \u5b8c\u5168\u65e0\u8bf7\u6c42\u65f6\u81ea\u52a8\u590d\u4f4d\uff0c\u4e0b\u4e00\u6761\u4e8b\u52a1\u81ea\u7136\u91cd\u65b0\u4f7f\u80fd\u3002" + CRLF +
    "\t//   \u8be6\u89c1\u4e0b\u65b9 cntrl0_user_command_register \u5904\u7684 95th \u4fee\u590d\u6ce8\u91ca\u3002" + CRLF +
    "\treg cache_cmd_done = 1'b0;" + CRLF
)

# ---------------------------------------------------------------- patch B
B_OLD = (
    "\t\tsdraddr <= s_prog_empty || !(s_ddr_wr || s_ddr_rd) ? " + CRLF +
    "\t\t    {6'b000001, vga_ddr_row_col + vga_lnbytecount} : " + CRLF +
    "\t\t    {memmap_mux[8:0], cache_hi_addr[9:0], 5'b00000};" + CRLF
)

B_NEW = (
    "\t\t// \u2605\u2605 95th \u4fee\u590d\uff1a\u8bf7\u6c42\u88ab\u670d\u52a1\u540e\u7acb\u5373\u91ca\u653e\u547d\u4ee4\u7ebf\u3002" + CRLF +
    "\t\t//   cache_line_start \u6b63\u662f\u201cFSM \u786e\u8ba4\u4e86 cache \u884c\u8bfb(2'b11)/\u5199(2'b01)\u201d\u7684\u90a3\u4e2a\u5355\u5468\u671f\u8109\u51b2" + CRLF +
    "\t\t//   \uff08\u89c1\u4e0a\u65b9 885 \u884c\uff09\uff0c\u6240\u4ee5\u5b83\u5929\u7136\u5c31\u662f\u201c\u5df2\u670d\u52a1\u201d\u4e8b\u4ef6\u3002" + CRLF +
    "\t\t//   \u6e05\u96f6\u6761\u4ef6\u53d6\u201ccache \u5b8c\u5168\u65e0\u8bf7\u6c42\u201d\uff1a\u53ea\u6709\u6b64\u65f6\u624d\u80fd\u786e\u5b9a\u4e0a\u4e00\u6761\u4e8b\u52a1\u5df2\u7ed3\u675f\u3002" + CRLF +
    "\t\t//   \uff08cache \u5728 STATE 011/111 \u91cc\u53ea\u80fd\u9760 ram_wr_valid/ram_rd_valid \u63a8\u8fdb\uff0c" + CRLF +
    "\t\t//    \u6240\u4ee5 ddr_wr/ddr_rd \u4e0d\u53ef\u80fd\u5728 FSM \u670d\u52a1\u4e4b\u524d\u81ea\u884c\u62c9\u4f4e\uff1b\u4e0d\u4f1a\u4e22\u4e8b\u52a1\u3002\uff09" + CRLF +
    "\t\tif(!ddr_wr && !ddr_rd)    cache_cmd_done <= 1'b0;" + CRLF +
    "\t\telse if(cache_line_start) cache_cmd_done <= 1'b1;" + CRLF +
    "\t\t" + CRLF +
    "\t\t// \u2605\u2605 95th \u4fee\u590d\uff1a\u5730\u5740\u4f7f\u80fd\u4e0e\u547d\u4ee4\u540c\u6e90\uff08cache_owns\uff09\uff0c" + CRLF +
    "\t\t//   \u4fdd\u8bc1 FSM \u91c7\u6837\u77ac\u95f4\u201c\u547d\u4ee4\u201d\u4e0e\u201c\u5730\u5740\u201d\u4e0d\u4f1a\u9519\u914d" + CRLF +
    "\t\t//   \uff08\u539f\u6765\u4e24\u8005\u5206\u522b\u53d6\u81ea s_ddr_wr||s_ddr_rd \u548c\u5b9e\u65f6 cache_hi_addr\uff0c\u5b58\u5728\u9519\u914d\u7a97\u53e3\uff09\u3002" + CRLF +
    "\t\tsdraddr <= s_prog_empty || !cache_owns ? " + CRLF +
    "\t\t    {6'b000001, vga_ddr_row_col + vga_lnbytecount} : " + CRLF +
    "\t\t    {memmap_mux[8:0], cache_hi_addr[9:0], 5'b00000};" + CRLF
)

# ---------------------------------------------------------------- patch C
C_OLD = (
    "\t\tif(s_prog_empty) cntrl0_user_command_register <= 2'b10;" + CRLF +
    "\t\telse if(s_ddr_wr) cntrl0_user_command_register <= 2'b01;" + CRLF +
    "\t\telse if(s_ddr_rd) cntrl0_user_command_register <= 2'b11;" + CRLF +
    "\t\telse if(~s_prog_full) cntrl0_user_command_register <= 2'b10;" + CRLF +
    "\t\telse cntrl0_user_command_register <= 2'b00;" + CRLF
)

C_NEW = (
    "\t\t// \u2605\u2605\u2605 95th \u4fee\u590d\uff082026-09-26\uff09\uff1a\u4e00\u6761 cache \u4e8b\u52a1\u53ea\u5141\u8bb8\u4e00\u6b21 AXI burst\u3002" + CRLF +
    "\t\t//" + CRLF +
    "\t\t//   \u6839\u56e0\uff08sim/tb/ddr_pipe.v \u9010\u62cd\u65e5\u5fd7\u5b9e\u6d4b\uff0cgate_fill=1\uff09\uff1a" + CRLF +
    "\t\t//     ddr_wr / ddr_rd \u662f**\u7535\u5e73**\uff0c\u8986\u76d6\u6574\u6761 cache \u4e8b\u52a1\uff08\u5b9e\u6d4b 144 \u4e2a clk_sdr\uff09\uff0c" + CRLF +
    "\t\t//     \u800c top_zynq7010 \u7684\u4e00\u6b21 16 \u62cd burst \u53ea\u8981 ~80 \u4e2a clk_sdr\uff0c\u4e4b\u540e\u8fd8\u6709 6 \u62cd IDLE \u91c7\u6837\u7a97\u53e3\u3002" + CRLF +
    "\t\t//     \u4e8e\u662f FSM \u5728**\u540c\u4e00\u6761\u4e8b\u52a1\u5185**\u5c31\u56de\u5230 IDLE\uff0c\u91cd\u65b0\u91c7\u6837\u672c\u5bc4\u5b58\u5668" + CRLF +
    "\t\t//     \uff08\u6b64\u65f6 s_ddr_wr \u4ecd\u4e3a 1\uff09\u21d2 \u518d\u53d1\u4e00\u6b21\u5b8c\u6574\u7684 16 \u62cd burst\u3002" + CRLF +
    "\t\t//   \u5bf9\u5199\u56de\u662f\u81f4\u547d\u7684\uff1aram_wdata \u53d6\u81ea cache \u7684 ddr_dout\uff0c\u800c wb_pcnt \u5728 ddr_wr=0 \u65f6\u88ab\u6e05\u96f6" + CRLF +
    "\t\t//     \uff08cache_controller.v:358\uff09\u3002\u6b64\u65f6 cache \u5df2\u79bb\u5f00 STATE 011 \u21d2 wb_pcnt==0 \u21d2" + CRLF +
    "\t\t//     16 \u62cd\u5168\u53d1 word0\uff0c\u628a\u521a\u5199\u56de\u6b63\u786e\u7684\u90a3\u4e00\u884c\u8986\u76d6\u6210\u201cword0 \u91cd\u590d\u201d\u3002" + CRLF +
    "\t\t//   \u5b9e\u6d4b\u8bc1\u636e\uff08cyc 36717 \u2192 36804\uff0cSD \u7f13\u51b2\u884c 0\uff09\uff1a" + CRLF +
    "\t\t//     36717 AW cmd=01 byte=08150000 cst=3 ddrwr=1  \u2190 \u6b63\u786e\u5199\u56de" + CRLF +
    "\t\t//     36803 IDLE ic=5 ack=00 cmd=01 dwr=0          \u2190 FSM \u91c7\u6837\u5230\u6b8b\u7559\u547d\u4ee4" + CRLF +
    "\t\t//     36804 AW cmd=10 byte=08150000 cst=7 ddrwr=0  \u2190 \u591a\u53d1\u7684\u4f2a burst\uff0c16 \u62cd\u5168 word0" + CRLF +
    "\t\t//   16 \u4e2a\u7f13\u51b2\u884c**\u884c\u884c\u5982\u6b64**\uff1a48 \u6b21 AW \u4e2d 16 \u6b21\u662f\u4f2a burst\u3002" + CRLF +
    "\t\t//   \u7aef\u5230\u7aef\u5224\u636e\uff1a\u81ea\u6d4b\u8bfb\u56de\u6574\u4e2a 1KB \u7f13\u51b2\u533a\uff0c" + CRLF +
    "\t\t//     \u65e7\u903b\u8f91 960/1024 \u5b57\u8282\u9519\uff0c95th \u4fee\u590d\u540e 0/1024\u3002" + CRLF +
    "\t\t//" + CRLF +
    "\t\t//   \u4fee\u6cd5\uff1acache \u4e00\u6761\u4e8b\u52a1\u53ea\u9700\u8981\u4e00\u6b21 burst\u3002cache_cmd_done \u5728 FSM \u786e\u8ba4\uff08cache_line_start\uff09" + CRLF +
    "\t\t//   \u540e\u7f6e\u4f4d\uff0c\u4f7f cache_owns \u62c9\u4f4e\u21d2\u547d\u4ee4\u7ebf\u7acb\u5373\u91ca\u653e\uff1b\u6b64\u65f6 FSM \u8fd8\u5728 burst \u4e2d\uff0c" + CRLF +
    "\t\t//   \u5230\u5b83\u4e0b\u4e00\u4e2a IDLE \u91c7\u6837\u7a97\u53e3\u65f6 cmd \u5df2\u7ecf\u662f 2'b10\uff08\u6216 2'b00\uff09\u3002" + CRLF +
    "\t\t//   \u547d\u4ee4\u7c7b\u578b\u4e0e\u5730\u5740\u4ecd\u53d6**\u5b9e\u65f6** s_ddr_wr/s_ddr_rd \u4e0e cache_hi_addr\uff08\u4e0d\u9501\u5b58\uff09\uff1a" + CRLF +
    "\t\t//   \u82e5\u9501\u5b58\uff0c\u5219 VGA \u62a2\u5360\u628a FSM \u62d6\u8fc7\u8bf7\u6c42\u5c3e\u5df4\u540e\u4f1a\u628a\u5199\u56de\u5f53\u6210\u586b\u5145\u53d1\uff0c" + CRLF +
    "\t\t//   cache \u4f1a\u5728 STATE 011 \u7b49\u4e00\u4e2a\u6c38\u8fdc\u4e0d\u4f1a\u6765\u7684 ram_wr_valid \u2192 \u6b7b\u9501\u3002" + CRLF +
    "\t\tif(s_prog_empty) cntrl0_user_command_register <= 2'b10;" + CRLF +
    "\t\telse if(cache_owns) cntrl0_user_command_register <= s_ddr_wr ? 2'b01 : 2'b11;" + CRLF +
    "\t\telse if(~s_prog_full) cntrl0_user_command_register <= 2'b10;" + CRLF +
    "\t\telse cntrl0_user_command_register <= 2'b00;" + CRLF
)

# ---------------------------------------------------------------- patch D
# cache_owns must be declared before it is used in the always block.
D_OLD = "\treg s_ddr_wr = 1'b0;" + CRLF

D_NEW = (
    "\treg s_ddr_wr = 1'b0;" + CRLF +
    "\t// \u2605\u2605 95th \u4fee\u590d\uff082026-09-26\uff09\uff1a\u4e00\u6761 cache \u4e8b\u52a1\u53ea\u5141\u8bb8\u4e00\u6b21 AXI burst" + CRLF +
    "\t//   \u2014\u2014 cache_cmd_done \u6807\u8bb0\u201c\u5f53\u524d\u5448\u73b0\u7684 cache \u8bf7\u6c42\u5df2\u7ecf\u88ab\u670d\u52a1\u8fc7\u4e00\u6b21 burst\u201d\uff0c" + CRLF +
    "\t//   \u5f53 cache \u5b8c\u5168\u65e0\u8bf7\u6c42\u65f6\u81ea\u52a8\u590d\u4f4d\uff0c\u4e0b\u4e00\u6761\u4e8b\u52a1\u81ea\u7136\u91cd\u65b0\u4f7f\u80fd\u3002" + CRLF +
    "\t//   cache_owns = \u672c\u62cd cache \u662f\u5426\u62e5\u6709 DDR \u603b\u7ebf\uff08\u7528\u4e8e\u547d\u4ee4\u5bc4\u5b58\u5668\u4e0e sdraddr \u540c\u6e90\uff09\u3002" + CRLF +
    "\t//   \u8be6\u89c1\u4e0b\u65b9 cntrl0_user_command_register \u5904\u7684 95th \u4fee\u590d\u6ce8\u91ca\u3002" + CRLF +
    "\treg cache_cmd_done = 1'b0;" + CRLF +
    "\twire cache_owns = (s_ddr_wr || s_ddr_rd) && !cache_cmd_done;" + CRLF
)

PATCHES = [("A: cache_cmd_done + cache_owns declaration", D_OLD, D_NEW),
           ("B: sdraddr mux + served flag", B_OLD, B_NEW),
           ("C: command mux", C_OLD, C_NEW)]


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
    print("written %s  (%s)" % (PATH, "REVERTED" if revert else "95th fix applied"))
    return 0


sys.exit(main())
