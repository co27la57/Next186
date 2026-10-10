#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""95th probe v3: measure the hiaddr -> sdraddr skew directly (CRLF-safe).

Board evidence so far:
  dbg_dbg4 = 0x6010, dbg_dbg5 = 0x61  -> [0x80] = 0x60, [0x84] = 0x61
  dbg_dbg5 (v2) = 0xA0                -> [0x180] = 0xA0
i.e. the CPU's read of buffer line k returns W(k+4): a DETERMINISTIC +0x100-byte
(4 buffer line) shift.  AL = [0x40] = 0x10 is correct, so the CPU side is fine and the
shift lives in the DDR round trip.

sdraddr is a pure function of cache_hi_addr:
    sdraddr[14:5] = cache_hi_addr[9:0]        (== {tag[4:0], index[4:0]})
so a +4 can only mean that sdraddr was latched from a cache_hi_addr belonging to a
DIFFERENT line than the one being filled.  This probe measures exactly that, at every
buffer-line FILL ack (rising edge of sys_cmd_ack == 2'b11):

    dbg_rd_reg[9:0] <= sdraddr[14:5]        <- the address the FSM was actually handed
    dbg_wb_reg[9:0] <= cache_hi_addr[9:0]   <- the address the cache presented

Both should be identical.  dbg_rd_reg == dbg_wb_reg + 4 proves the skew.

No new probe signals are added, so Set Up Debug does NOT need rebuilding; the two
registers are already in the ILA.  The old "first buffer-line fill / first buffer-line
write-back" latches are superseded (their values are already known: 0x000 and 0x00f).

usage: patch_ddr_186_skew_probe.py [--revert]
"""
import sys

PATH = "ddr_186.v"
CRLF = "\r\n"

OLD = (
    "\t\t\tif(!s_prog_empty && dbg_buf_line) begin" + CRLF +
    "\t\t\t\tif(s_ddr_wr && !dbg_wbr_seen) begin" + CRLF +
    "\t\t\t\t\tdbg_wbr_seen <= 1'b1;" + CRLF +
    "\t\t\t\t\tdbg_wb_reg   <= cache_hi_addr[9:0];" + CRLF +
    "\t\t\t\tend" + CRLF +
    "\t\t\t\tif(!s_ddr_wr && s_ddr_rd && !dbg_rdr_seen) begin" + CRLF +
    "\t\t\t\t\tdbg_rdr_seen <= 1'b1;" + CRLF +
    "\t\t\t\t\tdbg_rd_reg   <= cache_hi_addr[9:0];" + CRLF +
    "\t\t\t\tend" + CRLF +
    "\t\t\tend" + CRLF
)

NEW = (
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


def main():
    revert = "--revert" in sys.argv
    raw = open(PATH, "r", encoding="utf-8", newline="").read()
    if raw.count("\r\n") != raw.count("\n"):
        print("ABORT: not pure CRLF")
        return 1
    old, new = (NEW, OLD) if revert else (OLD, NEW)
    n = raw.count(old)
    if n != 1:
        print("ABORT: found %d occurrences (need 1)" % n)
        return 1
    open(PATH, "w", encoding="utf-8", newline="").write(raw.replace(old, new))
    print("ddr_186.v skew probe %s" % ("reverted" if revert else "applied"))
    return 0


sys.exit(main())
