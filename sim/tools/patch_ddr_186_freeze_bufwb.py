#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Extend the v4b freeze to dbg_bufwb_a / dbg_bufwb_n (CRLF-safe).

These two are also "latest wins" latches, so the SD stage (which writes the same buffer,
tag 0x1E0) overwrites them: the board read dbg_bufwb_a = 0x3c06 / dbg_bufwb_n = 0xFF, which
is an SD-stage value, not the self test's.

dbg_bufwb_a is a key clue: it is the hiaddr of the LAST buffer-line write-back.  If the self
test's last buffer-line write-back is index 6 and the read of offset 0x80 (line 2) shows
W(6), then "the write-back of line 6 wrote to line 2's address" is confirmed.

So track them in scratch registers and snapshot them at the same CPU write to port 0x00E5
that already freezes the v4 data latches:

    dbg_bufwb_a <= dbg_bufwb_a_live ;  dbg_bufwb_n <= dbg_bufwb_n_live

No new probe signals; Set Up Debug does not need rebuilding.

usage: patch_ddr_186_freeze_bufwb.py [--revert]
"""
import sys

PATH = "ddr_186.v"
CRLF = "\r\n"

OLD = (
    "\t\t\tif(ddr_wr && !s_ddr_wr && dbg_buf_line) begin" + CRLF +
    "\t\t\t\tif(dbg_bufwb_n != 8'hFF) dbg_bufwb_n <= dbg_bufwb_n + 1'b1;" + CRLF +
    "\t\t\t\tdbg_bufwb_a <= cache_hi_addr;" + CRLF +
    "\t\t\tend" + CRLF
)

NEW = (
    "\t\t\tif(ddr_wr && !s_ddr_wr && dbg_buf_line) begin" + CRLF +
    "\t\t\t\tif(dbg_bufwb_n_live != 8'hFF) dbg_bufwb_n_live <= dbg_bufwb_n_live + 1'b1;" + CRLF +
    "\t\t\t\tdbg_bufwb_a_live <= cache_hi_addr;" + CRLF +
    "\t\t\tend" + CRLF
)

# add the freeze lines inside the existing 0xE5 snapshot
FREEZE_OLD = (
    "\t\t\tif(e5_s1 && !e5_s2) begin" + CRLF +
    "\t\t\t\tdbg_rd_reg <= {1'b0, dbg_v4_rd_live};" + CRLF +
    "\t\t\t\tdbg_wb_reg <= {1'b0, dbg_v4_wb_live};" + CRLF +
    "\t\t\tend" + CRLF
)
FREEZE_NEW = (
    "\t\t\tif(e5_s1 && !e5_s2) begin" + CRLF +
    "\t\t\t\tdbg_rd_reg <= {1'b0, dbg_v4_rd_live};" + CRLF +
    "\t\t\t\tdbg_wb_reg <= {1'b0, dbg_v4_wb_live};" + CRLF +
    "\t\t\t\t// \u2605 \u540c\u4e00\u4e8b\u4ef6\u4e0b\u540c\u6b65\u51bb\u7ed3\u8fd9\u4e24\u4e2a\uff08\u5b83\u4eec\u4e5f\u662f\u201c\u6700\u65b0\u8986\u76d6\u201d\u578b\uff0c" + CRLF +
    "\t\t\t\t//   SD \u9636\u6bb5\u4f1a\u8986\u76d6\uff09\u3002dbg_bufwb_a = \u81ea\u6d4b\u671f\u95f4\u6700\u540e\u4e00\u6b21\u7f13\u51b2\u884c\u5199\u56de\u7684 hiaddr\u3002" + CRLF +
    "\t\t\t\tdbg_bufwb_a <= dbg_bufwb_a_live;" + CRLF +
    "\t\t\t\tdbg_bufwb_n <= dbg_bufwb_n_live;" + CRLF +
    "\t\t\tend" + CRLF
)

DECL_OLD = "\treg [8:0]  dbg_v4_wb_live = 9'd0;" + CRLF
DECL_NEW = (
    "\treg [14:0] dbg_bufwb_a_live = 15'd0;" + CRLF +
    "\treg [7:0]  dbg_bufwb_n_live = 8'd0;" + CRLF +
    "\treg [8:0]  dbg_v4_wb_live = 9'd0;" + CRLF
)


def main():
    revert = "--revert" in sys.argv
    raw = open(PATH, "r", encoding="utf-8", newline="").read()
    if raw.count("\r\n") != raw.count("\n"):
        print("ABORT: not pure CRLF")
        return 1
    for name, old, new in (("bufwb latch", OLD, NEW), ("freeze", FREEZE_OLD, FREEZE_NEW),
                           ("decls", DECL_OLD, DECL_NEW)):
        if revert:
            old, new = new, old
        n = raw.count(old)
        if n != 1:
            print("ABORT: %s -> %d occurrences (need 1)" % (name, n))
            return 1
        raw = raw.replace(old, new)
        print("ok  %s" % name)
    open(PATH, "w", encoding="utf-8", newline="").write(raw)
    print("ddr_186.v bufwb freeze %s" % ("reverted" if revert else "applied"))
    return 0


sys.exit(main())
