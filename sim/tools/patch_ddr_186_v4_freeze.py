#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""95th probe v4b: FREEZE the v4 data-side latches at the self test's 0x00E5 report.

Problem found from the board reading of v4 (dbg_rd_reg=0x021, dbg_wb_reg=0x020): the
latches track the LATEST event, but the memory self test runs EARLY in the boot and the SD
driver later writes the SAME buffer (tag 0x1E0).  dbg_dbg2 = 0x8f26 proves the SD stage ran,
so the captured fill / write-back of line 2 is most likely an SD-stage one, not the self
test's.  The values (nibbles 1 and 0, expected 2) are therefore about the SD stage.

Fix: keep tracking in NON-probe scratch registers and snapshot them into the two probe
registers at the CPU write to port 0x00E5 - which is exactly the moment the self test
reports its result.  Everything captured is then guaranteed to be from the self test.

    e5_wr  : clk_cpu  level  = (IORQ & CPU_CE & WR & PORT_ADDR==0x00E5)
    e5_s1/2: clk_sdr  2-FF synchroniser; on its rising edge ->
             dbg_rd_reg <= v4_rd_live ; dbg_wb_reg <= v4_wb_live

No new probe signals (dbg_rd_reg / dbg_wb_reg already exist), so Set Up Debug does NOT need
rebuilding.  The scratch registers are not probes.

usage: patch_ddr_186_v4_freeze.py [--revert]
"""
import sys

PATH = "ddr_186.v"
CRLF = "\r\n"

# ---- replace the v4 probe block ----
OLD = (
    "\t\t\tif(dbg_buf_line && (cache_hi_addr[4:0] == 5'd2) && (sys_cmd_ack == 2'b11) && (sys_cmd_ack_d1 != 2'b11)) begin" + CRLF +
    "\t\t\t\tdbg_fill_arm <= 1'b1;" + CRLF +
    "\t\t\t\tdbg_fill_idx <= cache_hi_addr[4:0];" + CRLF +
    "\t\t\t\tdbg_rdr_seen <= 1'b1;" + CRLF +
    "\t\t\tend else if(dbg_fill_arm && sys_rd_data_valid) begin" + CRLF +
    "\t\t\t\tdbg_fill_arm <= 1'b0;" + CRLF +
    "\t\t\t\tdbg_wb_reg   <= {1'b0, dbg_fill_idx, ram_rdata[7:4]};" + CRLF +
    "\t\t\tend" + CRLF +
    "\t\t\tif(dbg_buf_line && (cache_hi_addr[4:0] == 5'd2) && (sys_cmd_ack == 2'b01) && (sys_cmd_ack_d1 != 2'b01)) begin" + CRLF +
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

NEW = (
    "\t\t\tif(dbg_buf_line && (cache_hi_addr[4:0] == 5'd2) && (sys_cmd_ack == 2'b11) && (sys_cmd_ack_d1 != 2'b11)) begin" + CRLF +
    "\t\t\t\tdbg_fill_arm <= 1'b1;" + CRLF +
    "\t\t\t\tdbg_fill_idx <= cache_hi_addr[4:0];" + CRLF +
    "\t\t\t\tdbg_rdr_seen <= 1'b1;" + CRLF +
    "\t\t\tend else if(dbg_fill_arm && sys_rd_data_valid) begin" + CRLF +
    "\t\t\t\tdbg_fill_arm <= 1'b0;" + CRLF +
    "\t\t\t\tdbg_v4_wb_live <= {dbg_fill_idx, ram_rdata[7:4]};" + CRLF +
    "\t\t\tend" + CRLF +
    "\t\t\tif(dbg_buf_line && (cache_hi_addr[4:0] == 5'd2) && (sys_cmd_ack == 2'b01) && (sys_cmd_ack_d1 != 2'b01)) begin" + CRLF +
    "\t\t\t\tdbg_wb_arm  <= 1'b1;" + CRLF +
    "\t\t\t\tdbg_wb_idx  <= cache_hi_addr[4:0];" + CRLF +
    "\t\t\t\tdbg_wbr_seen <= 1'b1;" + CRLF +
    "\t\t\tend else if(dbg_wb_arm && sys_wr_data_valid) begin" + CRLF +
    "\t\t\t\tif(dbg_wb_pcnt == 1'b0) dbg_wb_pcnt <= 1'b1;" + CRLF +
    "\t\t\t\telse begin" + CRLF +
    "\t\t\t\t\tdbg_wb_pcnt <= 1'b0;" + CRLF +
    "\t\t\t\t\tdbg_wb_arm  <= 1'b0;" + CRLF +
    "\t\t\t\t\tdbg_v4_rd_live <= {dbg_wb_idx, cntrl0_user_input_data[7:4]};" + CRLF +
    "\t\t\t\tend" + CRLF +
    "\t\t\tend" + CRLF +
    "\t\t\t// \u2605\u2605 \u51bb\u7ed3\uff1aCPU \u5199\u7aef\u53e3 0x00E5\uff08\u81ea\u6d4b\u4e0a\u62a5\u90a3\u4e00\u523b\uff09\u65f6\u5feb\u7167\u3002" + CRLF +
    "\t\t\t//   \u81ea\u6d4b\u5728\u542f\u52a8\u65e9\u671f\u8dd1\uff0c\u800c SD \u9636\u6bb5\u4f1a\u5199**\u540c\u4e00\u4e2a**\u7f13\u51b2\u533a\uff08tag 0x1E0\uff09\u21d2" + CRLF +
    "\t\t\t//   \u4e0d\u51bb\u7ed3\u5c31\u4f1a\u62ff\u5230 SD \u9636\u6bb5\u7684\u4e8b\u4ef6\uff08v4 \u677f\u4e0a\u8bfb\u6570 0x021/0x020 \u5c31\u662f\u8fd9\u4e2a\u539f\u56e0\uff09\u3002" + CRLF +
    "\t\t\te5_s1 <= e5_wr; e5_s2 <= e5_s1;" + CRLF +
    "\t\t\tif(e5_s1 && !e5_s2) begin" + CRLF +
    "\t\t\t\tdbg_rd_reg <= {1'b0, dbg_v4_rd_live};" + CRLF +
    "\t\t\t\tdbg_wb_reg <= {1'b0, dbg_v4_wb_live};" + CRLF +
    "\t\t\tend" + CRLF
)

# ---- extra declarations (not probes) ----
DECL_OLD = (
    "\t// 95th probe v4 scratch (not probes themselves)" + CRLF +
    "\treg        dbg_fill_arm = 1'b0;" + CRLF +
    "\treg        dbg_wb_arm   = 1'b0;" + CRLF +
    "\treg        dbg_wb_pcnt  = 1'b0;" + CRLF +
    "\treg [4:0]  dbg_fill_idx = 5'd0;" + CRLF +
    "\treg [4:0]  dbg_wb_idx   = 5'd0;" + CRLF
)
DECL_NEW = (
    "\t// 95th probe v4 scratch (not probes themselves)" + CRLF +
    "\treg        dbg_fill_arm = 1'b0;" + CRLF +
    "\treg        dbg_wb_arm   = 1'b0;" + CRLF +
    "\treg        dbg_wb_pcnt  = 1'b0;" + CRLF +
    "\treg [4:0]  dbg_fill_idx = 5'd0;" + CRLF +
    "\treg [4:0]  dbg_wb_idx   = 5'd0;" + CRLF +
    "\treg [8:0]  dbg_v4_wb_live = 9'd0;" + CRLF +
    "\treg [8:0]  dbg_v4_rd_live = 9'd0;" + CRLF +
    "\t// 0x00E5 write detect + 2-FF sync into clk_sdr (see the freeze comment below)" + CRLF +
    "\treg        e5_wr = 1'b0, e5_s1 = 1'b0, e5_s2 = 1'b0;" + CRLF +
    "\talways @(posedge clk_cpu) e5_wr <= IORQ & CPU_CE & WR & (PORT_ADDR[15:0] == 16'h00E5);" + CRLF
)


def main():
    revert = "--revert" in sys.argv
    raw = open(PATH, "r", encoding="utf-8", newline="").read()
    if raw.count("\r\n") != raw.count("\n"):
        print("ABORT: not pure CRLF")
        return 1
    for name, old, new in (("probe block", OLD, NEW), ("decls", DECL_OLD, DECL_NEW)):
        if revert:
            old, new = new, old
        n = raw.count(old)
        if n != 1:
            print("ABORT: %s -> %d occurrences (need 1)" % (name, n))
            return 1
        raw = raw.replace(old, new)
        print("ok  %s" % name)
    open(PATH, "w", encoding="utf-8", newline="").write(raw)
    print("ddr_186.v v4 freeze %s" % ("reverted" if revert else "applied"))
    return 0


sys.exit(main())
