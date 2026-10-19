// sim/tb/opl3_ym_probe.v —— 仅仿真用：把 opl3_ym 内部关键信号引出来
// 只在 Verilator 台架里用层次引用取信号，不参与综合、不进 Vivado 工程。
module opl3_ym_probe #(
    parameter [31:0] INC_14M = 32'd1229922297
) (
    input  wire        mclk,
    input  wire        rst,
    input  wire        cpu_ce,
    input  wire        cpu_wr,
    input  wire [1:0]  cpu_addr,
    input  wire [7:0]  cpu_din,
    output wire [7:0]  cpu_dout,
    output wire [15:0] left,
    output wire [15:0] right,
    output wire [3:0]  keyon,
    // ---- 观测点 ----
    output wire        dbg_smpbd,   // 左声道采样锁存脉冲（每采样一次一个）
    output wire        dbg_smpac,   // 右声道采样锁存脉冲
    output wire        dbg_sy,      // DAC 串行帧同步
    output wire        dbg_clk14,   // 内部 14.318MHz CLK
    output wire [31:0] dbg_phase,   // 相位累加器
    output wire [10:0] dbg_wptr,    // 写 FIFO 写指针（统计实际入队字节数）
    output wire [10:0] dbg_rptr     // 写 FIFO 读指针
);

    opl3_ym #(.INC_14M(INC_14M)) u (
        .mclk(mclk), .rst(rst),
        .cpu_ce(cpu_ce), .cpu_wr(cpu_wr), .cpu_addr(cpu_addr),
        .cpu_din(cpu_din), .cpu_dout(cpu_dout),
        .left(left), .right(right), .keyon(keyon)
    );

    assign dbg_smpbd = u.ymf_smpbd;
    assign dbg_smpac = u.ymf_smpac;
    assign dbg_sy    = u.ymf_sy;
    assign dbg_clk14 = u.clk_14m;
    assign dbg_phase = u.phase_acc;
    assign dbg_wptr  = u.wptr;
    assign dbg_rptr  = u.rptr;

endmodule
