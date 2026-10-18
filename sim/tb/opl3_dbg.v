// sim/tb/opl3_dbg.v — opl3 调试包装层（仅离线仿真用）
// 把 opl3 内部关键信号暴露出来，用于定位"186 侧命令没进去"断在哪一环：
//   * Z80 总线活动(CPU_ADDR / MREQ / IORQ / WR)  -> Z80 有没有在跑
//   * 命令 FIFO 状态(qempty / qdata)             -> 我的写入有没有进队列、Z80 有没有取走
//   * opl3seq ready                              -> 合成引擎状态
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

    output wire [15:0] dbg_cpu_addr,
    output wire        dbg_cpu_mreq,
    output wire        dbg_cpu_iorq,
    output wire        dbg_cpu_wr,
    output wire        dbg_qempty,
    output wire [15:0] dbg_qdata,
    output wire        dbg_ready
);
    opl3 u (
        .clk(clk), .cpu_clk(cpu_clk), .addr(addr), .din(din), .dout(dout),
        .ce(ce), .wr(wr), .left(left), .right(right),
        .stb44100(stb44100), .reset(reset)
    );

    assign dbg_cpu_addr = u.CPU_ADDR;
    assign dbg_cpu_mreq = u.CPU_MREQ;
    assign dbg_cpu_iorq = u.CPU_IORQ;
    assign dbg_cpu_wr   = u.CPU_WR;
    assign dbg_qempty   = u.qempty;
    assign dbg_qdata    = u.qdata;
    assign dbg_ready    = u.ready;
endmodule
