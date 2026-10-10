// =============================================================================
// sim/tb/vga_scan.v — 聚焦的 VGA 扫描几何台架(2026-10-10)
// -----------------------------------------------------------------------------
// 目的: 把 ddr_186.v 里"扫描地址/行推进"这一段几何逻辑抽出来单独跑,
//       不依赖 DDR/cache/AXI 握手 —— 这样"每 2 字符重复"与"整体旋转 N 行"
//       都能在几秒内复现并做 A/B 对照。
//
// 忠实复刻的 RTL 片段(ddr_186.v):
//   max_read      <= (&sdraddr[7:3]) ? ~sdraddr[2:0] : 3'b111;              // :1078
//   sdraddr       <= {5'b00001, row_col + lnbytecount - 8, 1'b0};           // :1074 (VGA 分支)
//   // VGA 读被 ack:
//   col_counter   <= {1'b0, max_read, 1'b1};                                // :1117  = 2*max_read+1
//   vga_lnbytecount <= vga_lnbytecount + max_read + 1'b1;                   // :1121  = max_read+1
//   // 行结束:
//   s_vga_endscanline <= (vga_lnbytecount[7:3] == vga_lnend);               // :1160  文本 vga_lnend=6
//   if (s_vga_endscanline) begin
//       col_counter[3:1] <= col_counter[3:1] - vga_lnbytecount[2:0];        // :1128
//       vga_lnbytecount  <= 0;
//       if (row_count == lcr) vga_ddr_row_col <= VGA_TEXT_ROWCOL;           // :1140
//       else if (s_vga_endline) vga_ddr_row_col <= vga_ddr_row_col + 40;    // :1141 文本步进 40
//   end
//
// 说明: 真实 RTL 里 col_counter 由 sys_rd_data_valid 递减(每个数据字一次);
//       本台架把"一个事务交付的字数"直接取 max_read+1, 因此能复现
//       "地址推进量(max_read+1)" 与 "FIFO 扣减量(2*max_read+1)" 的比例关系。
// =============================================================================
`timescale 1ns / 1ps

module vga_scan #(
    // ★ 与 ddr_pipe.v 保持一致的变体选择, 便于交叉验证
    //   0 = {6'b000001, rowcol + lnb}                 (79b02d5)
    //   1 = {5'b00001, rowcol + lnb - 8,  1'b1}       (149th)
    //   2 = {5'b00001, rowcol + lnb - 8,  1'b0}       (当前工作区)
    //   3 = {5'b00001, rowcol + lnb - 448,1'b0}       (152nd)
    parameter integer VGA_ADDR_VAR  = 2,
    parameter [16:0]  VGA_TEXT_ROWCOL = 17'h0E000,   // 当前 RTL 值(旧值 17'h14000)
    parameter integer VGA_LNEND       = 6,           // 文本模式 vga_lnend
    parameter integer VGA_STRIDE      = 40,          // 文本模式每字符行推进 40 字
    parameter integer LINES           = 5,           // 跑几根字符行
    parameter integer MAXX            = 200          // 每行最多事务数(保险)
);
    // 运行期信号(与 RTL 同名, 便于对照)
    reg  [23:0] sdraddr          = 24'd0;
    reg  [7:0]  vga_lnbytecount  = 8'd0;
    reg  [4:0]  col_counter      = 5'd0;
    reg  [16:0] vga_ddr_row_col  = VGA_TEXT_ROWCOL;
    reg  [8:0]  vga_ddr_row_count= 9'd0;
    reg  [3:0]  vga_repln_count  = 4'd0;
    reg  [2:0]  max_read         = 3'd7;
    reg         s_vga_endline    = 1'b0;
    reg         s_vga_endscanline= 1'b0;

    integer txn_line, words_line, txn_total, line_no;
    integer i;

    // ---- 变体选择(与 ddr_pipe.v / ddr_186.v 完全同式) ----
    //   用 function 而不是 wire: Verilator 在 initial 块内不会重算连续赋值。
    function [23:0] mk_sdraddr(input [16:0] rc, input [7:0] lnb);
        begin
            case (VGA_ADDR_VAR)
                0: mk_sdraddr = {6'b000001, rc + lnb};
                1: mk_sdraddr = {5'b00001, rc + lnb - 5'd8,   1'b1};
                2: mk_sdraddr = {5'b00001, rc + lnb - 5'd8,   1'b0};
                default: mk_sdraddr = {5'b00001, rc + lnb - 9'd448, 1'b0};
            endcase
        end
    endfunction

    initial begin
        $display("=== vga_scan: VGA_ADDR_VAR=%0d base=0x%05X lnend=%0d stride=%0d ===",
                 VGA_ADDR_VAR, VGA_TEXT_ROWCOL, VGA_LNEND, VGA_STRIDE);
        $display("--- 每行事务明细(前 3 行) ---");
        txn_total = 0;
        for (line_no = 0; line_no < LINES; line_no = line_no + 1) begin
            txn_line   = 0;
            words_line = 0;
            vga_lnbytecount = 8'd0;
            vga_ddr_row_count = line_no[8:0];
            while ((vga_lnbytecount[7:3] != VGA_LNEND[2:0]) && (txn_line < MAXX)) begin
                // ---- max_read: 与 RTL :1078 同式(需先算出本事务地址) ----
                sdraddr = mk_sdraddr(vga_ddr_row_col, vga_lnbytecount);
                max_read = (&sdraddr[7:3]) ? ~sdraddr[2:0] : 3'b111;
                txn_line = txn_line + 1;
                txn_total = txn_total + 1;

                if (line_no < 3)
                    $display("  L%0d txn%2d sdr=0x%06X phys=0x%08X rowcol=0x%05X lnb=%3d max_read=%0d col_reload=%0d words=%0d",
                             line_no, txn_line, sdraddr, 32'h0800_0000 + {7'b0,sdraddr,1'b0},
                             vga_ddr_row_col, vga_lnbytecount, max_read,
                             {1'b0, max_read, 1'b1}, max_read + 1);

                // ---- 一个 VGA 读事务: RTL :1117 / :1121 ----
                col_counter       = {1'b0, max_read, 1'b1};            // 2*max_read+1
                vga_lnbytecount   = vga_lnbytecount + max_read + 1'b1; // += max_read+1
                words_line        = words_line + (max_read + 1);
                // ---- 行结束判据 RTL :1160(此处直接判, 等价于下一拍的 s_vga_endscanline) ----
            end
            $display("  >>> L%0d 结束: 事务=%0d 取字=%0d (文本行应为 40 字) 首地址=0x%06X 末地址=0x%06X",
                     line_no, txn_line, words_line,
                     mk_sdraddr(vga_ddr_row_col, 8'd0),
                     sdraddr);
            // ---- 行推进 RTL :1128/:1140/:1141 ----
            col_counter[3:1] = col_counter[3:1] - vga_lnbytecount[2:0];
            vga_lnbytecount  = 8'd0;
            if ((vga_ddr_row_count == 9'd400)) vga_ddr_row_col = VGA_TEXT_ROWCOL;
            else                               vga_ddr_row_col = vga_ddr_row_col + VGA_STRIDE[16:0];
        end
        $display("--- 汇总: 总事务=%0d, 5 行共取字=%0d ---", txn_total, txn_total*8);
        $display("=== vga_scan DONE ===");
        $finish;
    end

endmodule
