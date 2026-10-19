`timescale 1ns / 1ps
// Simulation-only expanded OPL3 monitor. Do not use in synthesis.
module opl3_dbg2(
    input wire clk, input wire cpu_clk, input wire [1:0] addr, input wire [7:0] din,
    output wire [7:0] dout, input wire ce, input wire wr,
    output wire [15:0] left, output wire [15:0] right, input wire stb44100, input wire reset,
    output wire [15:0] dbg_cpu_addr, output wire dbg_cpu_mreq, output wire dbg_cpu_iorq,
    output wire dbg_cpu_wr, output wire dbg_cpu_ce, output wire [7:0] dbg_cpu_dout,
    output wire [7:0] dbg_cpu_din, output wire dbg_qempty, output wire [15:0] dbg_qdata,
    output wire dbg_fifo_rdreq, output wire dbg_ready, output wire dbg_seq_rd,
    output wire [5:0] dbg_state, output wire [11:0] dbg_seq_addr,
    output wire [15:0] dbg_seq_wdata, output wire [15:0] dbg_seq_rdata,
    output wire dbg_seq_wr, output wire [3:0] dbg_channel_hit,
    output wire [3:0] dbg_channels
);
    opl3 u(
      .clk(clk), .cpu_clk(cpu_clk), .addr(addr), .din(din), .dout(dout),
      .ce(ce), .wr(wr), .left(left), .right(right), .stb44100(stb44100), .reset(reset),
      .channel_active(dbg_channels)
    );
    assign dbg_cpu_addr=u.CPU_ADDR;
    assign dbg_cpu_mreq=u.CPU_MREQ;
    assign dbg_cpu_iorq=u.CPU_IORQ;
    assign dbg_cpu_wr=u.CPU_WR;
    assign dbg_cpu_ce=u.CE;
    assign dbg_cpu_dout=u.CPU_DOUT;
    assign dbg_cpu_din=u.CPU_DIN;
    assign dbg_qempty=u.qempty;
    assign dbg_qdata=u.qdata;
    assign dbg_fifo_rdreq=u.CE && u.CPU_IORQ && !u.CPU_WR && u.CPU_ADDR[0];
    assign dbg_ready=u.ready;
    assign dbg_seq_rd=(u.read==2'b01);
    assign dbg_state=u.opl3seq_inst.STATE;
    assign dbg_seq_addr=u.seq_addr;
    assign dbg_seq_wdata=u.seq_wdata;
    assign dbg_seq_rdata=u.seq_rdata;
    assign dbg_seq_wr=u.seq_wr;
    assign dbg_channel_hit=u.channel_sample_hit;
endmodule
