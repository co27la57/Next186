// sim/tb/tb_cache.v
// Stage-1 testbench: real cache_controller + a behavioural model of the DDR side.
//
// The DDR side replicates the parts of ddr_186.v / top_zynq7010.v that matter for the
// cache<->DDR interaction:
//   * the command mux with the VGA-read priority (s_prog_empty has top priority)
//   * sdraddr = {memmap_mux, cache_hi_addr[9:0], 5'b0}  (1:1 page mapping)
//   * cache_line_start pulse on the ack edge
//   * a 16-beat (32 half-word) burst that paces cache_read_data / cache_write_data
//
// GATE_FILL selects the 91st fix so the same TB can show the bug and the fix:
//   0 = old behaviour: cache_write_data = ram_rd_valid              (VGA data can leak in)
//   1 = 91st fix:      cache_write_data = (ack==2'b11) && ram_rd_valid
`timescale 1ns / 1ps

module tb_cache #(
    parameter MEMW    = 16,          // DDR words (32-bit)
    parameter PAGE    = 9'h015       // memmap_mux value for tag 0x1E0 (SD buffer page)
) (
    // CPU side (driven from the C++ harness)
    input  wire        clk,          // clk_cpu
    input  wire        ddr_clk,      // clk_sdr
    input  wire        rst,
    input  wire        gate_fill,    // 1 = 91st fix, 0 = old (ungated) behaviour
    input  wire        flush_in,     // per-frame flush pulse (real design: auto_flush==3'b110)
    input  wire [20:0] cpu_addr,
    input  wire [31:0] cpu_din,
    input  wire        cpu_mreq,
    input  wire [3:0]  cpu_wmask,
    input  wire        vga_starving, // models s_prog_empty
    output wire        cpu_ce,
    output wire [31:0] cpu_dout,
    // observation
    output wire [2:0]  o_state,
    output wire [14:0] o_hiaddr,
    output wire [23:0] o_sdraddr,
    output wire [1:0]  o_cmd,
    output wire        o_ack_rd,
    output wire        o_ack_wr,
    output wire        o_cwr,        // cache_write_data actually presented
    output wire [31:0] o_wbdata,     // ddr_dout (write-back data)
    output wire [15:0] o_rddata,     // ram_rdata (DDR read data)
    output wire [7:0]  o_l2_fill_n,  // # fills of tag 0x1E0 / index 2
    output wire [7:0]  o_l2_wb_n,    // # write-backs of tag 0x1E0 / index 2
    output wire [7:0]  o_fill_foreign_n  // # cycles a NON-cache read burst delivered data
                                         //   while the cache wanted a fill (91st condition)
);

    // ------------------------------------------------------------------
    // cache under test
    // ------------------------------------------------------------------
    wire        ddr_rd, ddr_wr;
    wire [14:0] hiaddr;
    wire        cache_line_start;
    wire        cache_write_data;
    wire        cache_read_data;
    reg  [15:0] ddr_din;
    wire [31:0] ddr_dout;

    cache_controller u_cache (
        .addr            (cpu_addr),
        .dout            (cpu_dout),
        .din             (cpu_din),
        .clk             (clk),
        .mreq            (cpu_mreq),
        .wmask           (cpu_wmask),
        .ce              (cpu_ce),
        .ddr_din         (ddr_din),
        .ddr_dout        (ddr_dout),
        .ddr_clk         (ddr_clk),
        .cache_write_data(cache_write_data),
        .cache_read_data (cache_read_data),
        .ddr_rd          (ddr_rd),
        .ddr_wr          (ddr_wr),
        .hiaddr          (hiaddr),
        .flush           (flush_in),
        .cache_line_start(cache_line_start)
    );

    // ------------------------------------------------------------------
    // DDR side model
    // ------------------------------------------------------------------
    reg  [1:0]  s_ddr_rd = 2'b00, s_ddr_wr = 2'b00;
    reg  [1:0]  cmd_reg  = 2'b00;
    reg  [23:0] sdraddr  = 24'h0;
    reg  [1:0]  ram_cmd_ack = 2'b00;
    reg  [1:0]  ack_d1   = 2'b00;

    reg         ram_rd_valid = 1'b0;
    reg         ram_wr_valid = 1'b0;
    reg  [15:0] ram_rdata    = 16'h0;
    reg  [31:0] mem [0:(1<<MEMW)-1];

    integer i;
    initial for (i = 0; i < (1<<MEMW); i = i + 1) mem[i] = 32'hDEAD0000 + i;

    // VGA scan-out address (any address in the VGA page); the exact value is not important,
    // what matters is that it is NOT the cache line the fill wanted.
    wire [23:0] vga_addr = {6'b000001, 18'h14000};

    // ---- command mux + sdraddr (mirrors ddr_186.v) -------------------
    always @(posedge ddr_clk) begin
        s_ddr_rd <= {1'b0, ddr_rd};
        s_ddr_wr <= {1'b0, ddr_wr};

        cache_line_start_r <= (ram_cmd_ack != 2'b00) && (ack_d1 == 2'b00) &&
                              ((ram_cmd_ack == 2'b01) || (ram_cmd_ack == 2'b11));
        ack_d1 <= ram_cmd_ack;

        sdraddr <= (vga_starving || !(s_ddr_wr[0] || s_ddr_rd[0])) ?
                   vga_addr :
                   {PAGE[8:0], hiaddr[9:0], 5'b00000};

        if      (vga_starving)      cmd_reg <= 2'b10;   // VGA read has top priority
        else if (s_ddr_wr[0])       cmd_reg <= 2'b01;   // cache write-back
        else if (s_ddr_rd[0])       cmd_reg <= 2'b11;   // cache fill
        else                        cmd_reg <= 2'b10;   // keep VGA fed
    end
    reg cache_line_start_r = 1'b0;
    assign cache_line_start = cache_line_start_r;

    // ---- 16-beat burst engine (mirrors top_zynq7010.v behaviour) -----
    localparam B_IDLE = 2'd0, B_RD = 2'd1, B_WR = 2'd2;
    reg  [1:0]  bstate = B_IDLE;
    reg  [4:0]  beat   = 5'd0;
    reg         half   = 1'b0;
    reg  [23:0] addr_l = 24'h0;
    reg  [31:0] wd_lo  = 32'h0;

    always @(posedge ddr_clk) begin
        ram_rd_valid <= 1'b0;
        ram_wr_valid <= 1'b0;

        case (bstate)
        B_IDLE: begin
            if (cmd_reg != 2'b00) begin
                ram_cmd_ack <= cmd_reg;
                addr_l      <= sdraddr;
                beat        <= 5'd0;
                half        <= 1'b0;
                if (cmd_reg == 2'b10 || cmd_reg == 2'b11) bstate <= B_RD;
                else begin
                    bstate <= B_WR;
                    wd_lo  <= ddr_dout;          // first 32-bit word to write
                end
            end else begin
                ram_cmd_ack <= 2'b00;
            end
        end

        B_RD: begin
            ram_rd_valid <= 1'b1;
            ram_rdata    <= half ? mem[addr_l[MEMW-1:0]][31:16]
                                 : mem[addr_l[MEMW-1:0]][15:0];
            if (half) begin
                half  <= 1'b0;
                beat  <= beat + 5'd1;
                addr_l<= addr_l + 24'd1;
                if (beat == 5'd15) bstate <= B_IDLE;
            end else begin
                half <= 1'b1;
            end
        end

        B_WR: begin
            ram_wr_valid <= 1'b1;
            if (half) begin
                mem[addr_l[MEMW-1:0]] <= {ddr_dout[15:0], wd_lo[15:0]};
                half   <= 1'b0;
                beat   <= beat + 5'd1;
                addr_l <= addr_l + 24'd1;
                wd_lo  <= ddr_dout;
                if (beat == 5'd15) bstate <= B_IDLE;
            end else begin
                half <= 1'b1;
            end
        end
        endcase
    end

    // ---- the gate under test ----------------------------------------
    // cache_read_data (write-back side) was always gated by ram_wr_valid in the real design.
    assign cache_read_data  = ram_wr_valid;

    assign cache_write_data = gate_fill ?
        ((ram_cmd_ack == 2'b11) && ram_rd_valid) :   // 91st fix
        ram_rd_valid;                                // old, ungated

    always @(posedge ddr_clk) ddr_din <= ram_rdata;

    // ---- line-2 traffic counters: PROVE the eviction/refill path was exercised ----
    // (if these are 0 the measurement read was a plain cache hit and the test is vacuous)
    reg [7:0] l2_fill_n = 8'd0;   // fills of tag 0x1E0 / index 2
    reg [7:0] l2_wb_n   = 8'd0;   // write-backs of tag 0x1E0 / index 2
    wire l2 = (hiaddr[14:5] == 10'h1E0) && (hiaddr[4:0] == 5'd2);
    always @(posedge ddr_clk) begin
        if (!rst) begin
            if (ram_cmd_ack == 2'b11 && l2 && ram_rd_valid && !ram_rd_valid_d)
                if (l2_fill_n != 8'hFF) l2_fill_n <= l2_fill_n + 8'd1;
            if (ram_cmd_ack == 2'b01 && l2 && ram_wr_valid && !ram_wr_valid_d)
                if (l2_wb_n != 8'hFF) l2_wb_n <= l2_wb_n + 8'd1;
        end
    end
    reg ram_rd_valid_d = 1'b0, ram_wr_valid_d = 1'b0;
    always @(posedge ddr_clk) begin
        ram_rd_valid_d <= ram_rd_valid;
        ram_wr_valid_d <= ram_wr_valid;
    end

    assign o_l2_fill_n = l2_fill_n;
    assign o_l2_wb_n   = l2_wb_n;

    // ---- did a NON-cache read burst ever deliver data while the cache wanted a fill? ----
    // This is the condition the 91st fix guards. If it stays 0 the VGA contention never
    // actually overlapped a fill, and the whole comparison is meaningless.
    reg [7:0] fill_foreign_n = 8'd0;
    always @(posedge ddr_clk) begin
        if (!rst && ddr_rd && ram_rd_valid && (ram_cmd_ack != 2'b11))
            if (fill_foreign_n != 8'hFF) fill_foreign_n <= fill_foreign_n + 8'd1;
    end
    assign o_fill_foreign_n = fill_foreign_n;

    // ---- observation -------------------------------------------------
    assign o_state   = u_cache.STATE;
    assign o_hiaddr  = hiaddr;
    assign o_sdraddr = sdraddr;
    assign o_cmd     = cmd_reg;
    assign o_ack_rd  = (ram_cmd_ack == 2'b11);
    assign o_ack_wr  = (ram_cmd_ack == 2'b01);
    assign o_cwr     = cache_write_data;
    assign o_wbdata  = ddr_dout;
    assign o_rddata  = ram_rdata;

endmodule
