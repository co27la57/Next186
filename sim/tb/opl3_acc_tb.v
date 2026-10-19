// sim/tb/opl3_acc_tb.v — 累加器观测包装层（仅离线仿真用）
// 在 opl3_led_tb 基础上额外暴露 opl3seq 内部的：
//   * rAcc    —— 各通道求和累加器（19位有符号）
//   * limAcc  —— 削波后的 16bit 输出
//   * STATE   —— 合成状态机状态（21=左混音累计完成，22=A锁存）
// 用于测量"累加器过驱动(削波)"的比例，判断嘶哑是否由削波引起。
`timescale 1ns / 1ps
module opl3_acc_tb (
    input  wire        clk,
    input  wire        cpu_clk,
    input  wire [1:0]  addr,
    input  wire [7:0]  din,
    input  wire        ce,
    input  wire        wr,
    input  wire        stb44100,
    input  wire        reset,
    output wire [15:0] left,
    output wire [15:0] right,
    output wire        ready,
    output wire        audio_tick,
    output wire        qempty,
    output wire [15:0] cpu_addr,
    output wire [5:0]  seq_state,
    output wire signed [18:0] dbg_acc,
    output wire [15:0] dbg_limacc
);
    wire [7:0] unused_dout;
    opl3 u(
        .clk(clk), .cpu_clk(cpu_clk), .addr(addr), .din(din),
        .dout(unused_dout), .ce(ce), .wr(wr), .left(left), .right(right),
        .stb44100(stb44100), .reset(reset)
    );
    assign seq_state = u.opl3seq_inst.STATE;
    assign dbg_acc   = u.opl3seq_inst.rAcc;
    assign dbg_limacc= u.opl3seq_inst.limAcc;
    assign ready     = u.ready;
    assign audio_tick= u.read == 2'b01;
    assign qempty    = u.qempty;
    assign cpu_addr  = u.CPU_ADDR;
endmodule
