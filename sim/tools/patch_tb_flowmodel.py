"""patch_tb_flowmodel.py — 补齐 sim/tb/ddr_pipe.v 的「显示使能 + 流控」模型（102nd）

背景（为什么必须补）：
  100th-A 的"台架验证"被证明无效，因为台架缺三样东西：
    1. 完全没有 FifoStart 模型（ddr_186.v:986-990 —— 它直连 VGA_SG.ce()，是显示总开关）；
    2. FIFO 水位从 512 起步（不是从空开始），所以永远不会经历"从空爬到 64 才点亮显示"；
    3. 我说"把 s_prog_empty 阈值降到 32"，但补丁从未匹配上（台架一直是 <64）。

本补丁把台架改成对 ddr_186.v 的**忠实**建模：
  · 水位单位 = WRITE words（16-bit），与 fifo 包装里的 wrusedw 完全一致，并 511 饱和；
  · 复位时水位 = 0（空），与板上一致；
  · 排空（pop）只在 FifoStart 之后、且只在行内可见区（640/800 像素占空）发生，1 pop = 2 write words；
  · FifoStart = 水位 >= 64 时置位一次，永不清零；
  · s_prog_empty = (lvl < 64) / s_prog_full = (lvl > 350)，每 clk_sdr 更新（与 RTL 同）；
  · 统计：FifoStart 置位周期、置位后水位 min/max、s_prog_empty 高/低占空、排空饥饿次数。

验收标准（用户提供的板上实测）：**s_prog_empty 大多数时候为 0（FIFO 满），少数时候为 1**
  —— 基线（fix_100=0, fifo_drain=32）必须复现这个"大部分满"的形态，否则模型不算对。

另外把 fix_100 扩成 2 bit 选择器（不改任何作者逻辑，只用于台架 A/B）：
  fix_100 = 0 : 现状（16 半字/事务）
  fix_100 = 1 : 候选 A —— 把 FIFO 写入量限制为 max_read+1（8 半字/事务）
  fix_100 = 2 : 候选 B —— 把 VGA(cmd=10) 的 AXI 突发缩短为 4 拍（=16B=8 半字）

用法：
  python sim/tools/patch_tb_flowmodel.py            # 应用
  python sim/tools/patch_tb_flowmodel.py --revert   # 回退（用备份 .preFlowModel）
"""

import os
import re
import shutil
import sys

TB = 'sim/tb/ddr_pipe.v'
CPP = 'sim/tb/ddr_selftest_main.cpp'
BAK_TB = 'sim/run/ddr_pipe.v.preFlowModel'
BAK_CPP = 'sim/run/ddr_selftest_main.cpp.preFlowModel'


def load(path):
    raw = open(path, 'r', newline='').read()
    crlf = raw.count('\r\n')
    bare = raw.count('\n') - crlf
    return raw.replace('\r\n', '\n'), ('\r\n' if crlf >= bare else '\n')


def save(path, text, eol):
    out = text.replace('\n', eol)
    open(path, 'w', newline='').write(out)


def sub1(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit('ANCHOR FAIL (%s): found %d occurrences' % (what, n))
    return text.replace(old, new, 1)


def main():
    if '--revert' in sys.argv:
        for b, p in ((BAK_TB, TB), (BAK_CPP, CPP)):
            if os.path.exists(b):
                shutil.copyfile(b, p)
                print('reverted %s <- %s' % (p, b))
            else:
                print('no backup for %s' % p)
        return

    tb, eol = load(TB)
    cpp, ceol = load(CPP)
    if not os.path.exists(BAK_TB):
        shutil.copyfile(TB, BAK_TB)
        shutil.copyfile(CPP, BAK_CPP)
        print('backups written: %s , %s' % (BAK_TB, BAK_CPP))

    # ---- 1) 新输出端口 -------------------------------------------------------
    tb = sub1(
        tb,
        "    output wire [5:0]  o_pmis_w\n);",
        """    output wire [5:0]  o_pmis_w,
    // ---- 102nd [flow model]: FAITHFUL display-enable / flow-control observability ----
    //   FifoStart 是作者的显示总开关 (ddr_186.v:986-990 -> VGA_SG.ce()).
    //   o_lvl   = FIFO 占用量, 单位 = WRITE words (16-bit), 与 fifo 包装的 wrusedw 一致,
    //             511 饱和.
    //   o_pe_hi/o_pe_lo = FifoStart 置位之后 s_prog_empty 为 1 / 为 0 的周期数
    //             ("大多数时候满, 偶尔拉高" = 板上实测签名).
    //   o_underr_n = 显示在空 FIFO 上排空的次数 (画面数据被重复/冻结).
    output wire        o_fstart,
    output wire [31:0] o_fstart_cyc,
    output wire [9:0]  o_lvl,
    output wire [9:0]  o_lvl_min,
    output wire [9:0]  o_lvl_max,
    output wire [31:0] o_pe_hi,
    output wire [31:0] o_pe_lo,
    output wire [31:0] o_underr_n
);""",
        'port list')

    # ---- 2) fix_100 扩为 2 bit --------------------------------------------
    tb = sub1(
        tb,
        "    input  wire        fix_100,  // 100th/A: limit VGA FIFO accepts to max_read+1 per txn (+ lower s_prog_empty to 32)",
        """    input  wire [1:0]  fix_100,  // [102nd] AXI-side candidate selector:
                                 //   0 = 现状 (16 halfwords/txn, address strides 8)
                                 //   1 = A: cap FIFO writes at max_read+1 (8 halfwords/txn)
                                 //   2 = B: shorten the VGA(cmd=10) AXI burst to 4 beats (=8 halfwords)""",
        'fix_100 port')

    # ---- 3) 声明：水位从空起步 + 显示使能/排空模型 --------------------------
    tb = sub1(
        tb,
        "    reg  [9:0] fifo_used = 10'd512;",
        """    reg  [9:0] fifo_used = 10'd0;      // [102nd] WRITE words (16-bit); starts EMPTY (board-like)
    // ---- 102nd: display enable + realistic scan-out timing ------------------
    //   ddr_186.v: displ_on = !(hblnk|vblnk|!FifoStart); vrdon = s_displ_on[~vga_hrzpan]
    //   => pops only happen after FifoStart and only inside the visible part of a line.
    localparam [10:0] LINE_LEN_M = 11'd1600;   // 800 pixel clocks * 2 clk_sdr (25 MHz dot clock)
    localparam [10:0] VIS_LEN_M  = 11'd1280;   // 640 visible pixels   * 2 clk_sdr
    reg  [10:0] line_cnt   = 11'd0;
    reg         fstart     = 1'b0;             // FifoStart: latch once at lvl>=64, never cleared
    reg  [31:0] fstart_cyc = 32'd0;
    reg  [9:0]  lvl_min = 10'd511, lvl_max = 10'd0;
    reg  [31:0] pe_hi = 32'd0, pe_lo = 32'd0, underr_n = 32'd0;
    wire [9:0]  lvl_m = (fifo_used > 10'd511) ? 10'd511 : fifo_used[9:0];  // wrapper: saturating wrusedw""",
        'fifo_used decl')

    # ---- 4) 写门：fix_100[0] = 候选 A --------------------------------------
    tb = sub1(
        tb,
        "                     (!fix_100 || vga_acc_ok);   // [100A] 每事务只接受 max_read+1 个半字",
        "                     (!fix_100[0] || vga_acc_ok);   // [102nd] A: cap accepts at max_read+1",
        'fifo_wr_m gate')

    # ---- 5) 复位：水位 0 + 新状态清零 --------------------------------------
    tb = sub1(
        tb,
        "            crw_m <= 1'b0; fifo_used <= 10'd512; drain_cnt <= 8'd0;",
        """            crw_m <= 1'b0; fifo_used <= 10'd0; drain_cnt <= 8'd0;
            line_cnt <= 11'd0; fstart <= 1'b0; fstart_cyc <= 32'd0;
            lvl_min <= 10'd511; lvl_max <= 10'd0;
            pe_hi <= 32'd0; pe_lo <= 32'd0; underr_n <= 32'd0;""",
        'reset block')

    # ---- 6) 排空 / 阈值 / FifoStart —— 忠实模型 ----------------------------
    tb = sub1(
        tb,
        """            // ---- ddr_186.v:888-895
            if (fifo_drain != 8'd0) begin
                if (drain_cnt >= fifo_drain - 1'b1) begin
                    drain_cnt <= 8'd0;
                    if (fifo_used != 10'd0) fifo_used <= fifo_used - 1'b1;
                end else drain_cnt <= drain_cnt + 1'b1;
                if (fifo_wr_m && fifo_used < 10'd1000) fifo_used <= fifo_used + 1'b1;
                s_prog_full_m  <= (fifo_used > 10'd350);
                s_prog_empty_m <= (fifo_used < 10'd64);
            end""",
        """            // ---- [102nd] FAITHFUL copy of ddr_186.v:983-990 + the fifo wrapper ----
            //   水位单位 = 16-bit WRITE words; 排空 1 次 = 1 个 32-bit read word = -2 write words.
            if (fifo_drain != 8'd0) begin
                // fills (1 per accepted halfword)
                if (fifo_wr_m && fifo_used < 10'd1023) fifo_used <= fifo_used + 1'b1;

                // pops: only while the display is ON (FifoStart) and inside the visible window
                if (fstart && (line_cnt < VIS_LEN_M)) begin
                    if (drain_cnt >= fifo_drain - 1'b1) begin
                        drain_cnt <= 8'd0;
                        if (lvl_m >= 10'd2) fifo_used <= fifo_used - 10'd2;
                        else underr_n <= underr_n + 1'b1;      // pop on empty -> display starves
                    end else drain_cnt <= drain_cnt + 1'b1;
                end else drain_cnt <= 8'd0;

                // line timing (1600 clk_sdr per scanline, 1280 of them visible)
                if (line_cnt >= LINE_LEN_M - 1'b1) line_cnt <= 11'd0;
                else                              line_cnt <= line_cnt + 1'b1;

                // thresholds -- exactly ddr_186.v:983/986
                s_prog_full_m  <= (lvl_m > 10'd350);
                s_prog_empty_m <= (lvl_m < 10'd64);

                // FifoStart -- ddr_186.v:986-990 (latch only, never cleared)
                if (!fstart && (lvl_m >= 10'd64)) begin
                    fstart     <= 1'b1;
                    fstart_cyc <= cyc_ctr;
                end

                // statistics, measured over the display-active phase only
                if (fstart) begin
                    if (lvl_m > lvl_max) lvl_max <= lvl_m;
                    if (lvl_m < lvl_min) lvl_min <= lvl_m;
                    if (lvl_m < 10'd64)  pe_hi <= pe_hi + 1'b1;
                    else                 pe_lo <= pe_lo + 1'b1;
                end
            end""",
        'drain/threshold block')

    # ---- 7) 候选 B：VGA 读突发缩短为 4 拍 --------------------------------
    tb = sub1(
        tb,
        "    assign slv_rlast = (r_cnt == 5'd15);",
        """    // [102nd] AXI-side candidate B: for VGA reads (cmd=10) shorten the burst to 4 beats
    //         = 16 bytes = 8 halfwords = exactly max_read+1, which is what the author's
    //         address stride (vga_lnbytecount += max_read+1) accounts for.
    wire [4:0] rlast_at = (fix_100[1] && (ar_cmd_l == 2'b10)) ? 5'd3 : 5'd15;
    assign slv_rlast = (r_cnt == rlast_at);""",
        'slv_rlast')

    # ---- 8) 新输出的 assign --------------------------------------------------
    tb = sub1(
        tb,
        "    assign o_pe_n = pe_n;",
        """    // [102nd] flow-model observability
    assign o_fstart     = fstart;
    assign o_fstart_cyc = fstart_cyc;
    assign o_lvl        = lvl_m;
    assign o_lvl_min    = lvl_min;
    assign o_lvl_max    = lvl_max;
    assign o_pe_hi      = pe_hi;
    assign o_pe_lo      = pe_lo;
    assign o_underr_n   = underr_n;
    assign o_pe_n = pe_n;""",
        'o_pe_n assign')

    save(TB, tb, eol)

    # ---- 9) C++ 打印 --------------------------------------------------------
    cpp = sub1(
        cpp,
        '    printf("scan256 took %lld cycles, total %lld\\n", scan_cycles, cyc);',
        """    printf("scan256 took %lld cycles, total %lld\\n", scan_cycles, cyc);
    printf("FLOW  FifoStart=%u @cyc=%u  lvl=%u  lvl min/max=%u/%u  s_prog_empty hi/lo=%u/%u  underruns=%u\\n",
           (unsigned)dut->o_fstart, (unsigned)dut->o_fstart_cyc, (unsigned)dut->o_lvl,
           (unsigned)dut->o_lvl_min, (unsigned)dut->o_lvl_max,
           (unsigned)dut->o_pe_hi, (unsigned)dut->o_pe_lo, (unsigned)dut->o_underr_n);""",
        'cpp scan256 print')
    save(CPP, cpp, ceol)

    print('patched %s and %s' % (TB, CPP))


main()
