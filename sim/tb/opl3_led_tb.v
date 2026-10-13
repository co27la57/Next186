`timescale 1ns / 1ps
// Offline wrapper around the production OPL3 and its production RAM.
// xpm_fifo_async_stub.v models the explicit production READ_MODE="fwft"
// configuration. It does not model XPM CDC implementation details; passing
// this test verifies the LED/sample monitor and the intended FIFO read timing.
module opl3_led_tb #(
    parameter DIRECTED_TEST = 1
)(
    input wire clk,
    input wire cpu_clk,
    input wire [1:0] addr,
    input wire [7:0] din,
    input wire ce,
    input wire wr,
    input wire stb44100,
    input wire reset,
    input wire [63:0] test_samples,
    input wire [15:0] test_other_sample,
    input wire test_pan_enable,
    output wire directed_test,
    output wire [3:0] channel_active,
    output wire [3:0] sample_hit,
    output wire [15:0] left,
    output wire [15:0] right,
    output wire ready,
    output wire audio_tick,
    output wire qempty,
    output wire [15:0] cpu_addr,
    output wire [5:0] seq_state,
    output wire [4:0] sample_channel,
    output wire [15:0] channel_sample
);
    wire [7:0] unused_dout;
    opl3 u(
        .clk(clk), .cpu_clk(cpu_clk), .addr(addr), .din(din),
        .dout(unused_dout), .ce(ce), .wr(wr), .left(left), .right(right),
        .stb44100(stb44100), .reset(reset), .channel_active(channel_active)
    );
    assign sample_hit = u.channel_sample_hit;
    assign ready = u.ready;
    assign audio_tick = u.read == 2'b01;
    assign qempty = u.qempty;
    assign cpu_addr = u.CPU_ADDR;
    assign seq_state = u.opl3seq_inst.STATE;
    assign sample_channel = u.opl3seq_inst.s_ram_CHindex;
    assign channel_sample = u.seq_rdata;
    assign directed_test = DIRECTED_TEST != 0;

    // Focused monitor regression: real sequencer, real address generation,
    // synchronous one-cycle RAM response, and the production LED hold logic.
    // Only the RAM response is replaced; no sample-hit or LED signal is forced.
    // Other channels deliberately carry a large sample to catch channel bleed.
    generate if (DIRECTED_TEST != 0) begin : directed
        reg [15:0] read_data = 0;
        integer ch;
        always @(posedge clk) begin
            read_data <= 0;
            for (ch = 0; ch < 18; ch = ch + 1)
                if (u.seq_addr == (12'haf5 + ch * 48 + 23))
                    read_data <= ch < 4 ? test_samples[ch * 16 +: 16] : test_other_sample;
            if (u.seq_addr == (12'haf5 + 18 * 48 + 2) ||
                u.seq_addr == (12'haf5 + 18 * 48 + 4))
                read_data <= test_pan_enable ? 16'hffff : 0;
            if (u.seq_addr == (12'haf5 + 18 * 48 + 3) ||
                u.seq_addr == (12'haf5 + 18 * 48 + 5))
                read_data <= test_pan_enable ? 16'h0003 : 0;
        end
        initial force u.seq_rdata = read_data;
    end endgenerate
endmodule
