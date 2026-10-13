// sim/tb/opl3_dbg.v — opl3 调试包装层（仅离线仿真用）
// 暴露内部信号，用于定位"命令通路"与"硬削波"两类问题。
module opl3_dbg(
    input  wire        clk,
    input  wire        cpu_clk,
    input  wire [1:0]  addr,
    input  wire [7:0]  din,
    output wire [7:0]  dout,
    input  wire        ce,
    input  wire        wr,
    output wire [15:0] left,
    output wire [15:0] right,
    input  wire        stb44100,
    input  wire        reset,

    output wire [3:0]  dbg_channel_active,
    output wire [15:0] dbg_limacc,
    output wire signed [18:0] dbg_racc,
    output wire [5:0]  dbg_seq_state,
    output wire [4:0]  dbg_sample_ch,
    output wire [15:0] dbg_seq_rdata,
    // ★ 2026-10-13 槽位参数探针（opl3seq STATE 12/13 锁存）
    output wire [15:0] dbg_slot_tll,
    output wire [9:0]  dbg_slot_vol,
    output wire [5:0]  dbg_slot_id
);
    opl3 u (
        .clk(clk), .cpu_clk(cpu_clk), .addr(addr), .din(din), .dout(dout),
        .ce(ce), .wr(wr), .left(left), .right(right),
        .stb44100(stb44100), .reset(reset),
        .channel_active(dbg_channel_active)
    );

    assign dbg_limacc    = u.opl3seq_inst.limAcc;
    assign dbg_racc      = u.opl3seq_inst.rAcc;
    assign dbg_seq_state = u.opl3seq_inst.STATE;
    assign dbg_sample_ch = u.opl3seq_inst.s_ram_CHindex;
    assign dbg_seq_rdata = u.seq_rdata;
    assign dbg_slot_tll  = u.opl3seq_inst.dbg_slot_tll;
    assign dbg_slot_vol  = u.opl3seq_inst.dbg_slot_vol;
    assign dbg_slot_id   = u.opl3seq_inst.dbg_slot_id;
endmodule
