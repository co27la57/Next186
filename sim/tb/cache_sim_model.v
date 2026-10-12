// ============================================================================
// sim-only behavioral cache RAM for RTL testbench. NOT part of the project.
// Reason: project cache.v instantiates altsyncram (Intel primitive) which has
//         no model outside Vivado. Vivado synthesis is unaffected.
// Behavior: 2048 x 32bit dual-port RAM, port A sync write, port B write plus
//           combinational read. The stage2 switch test only checks pure
//           predicates (stage2_ok / bios_fill), so read latency is irrelevant.
// ============================================================================
module cache (
    input  [10:0]  address_a,
    input  [10:0]  address_b,
    input  [3:0]   byteena_a,
    input  [3:0]   byteena_b,
    input           clock_a,
    input           clock_b,
    input  [31:0]  data_a,
    input  [31:0]  data_b,
    input           enable_a,
    input           enable_b,
    input           wren_a,
    input           wren_b,
    output reg [31:0] q_a,
    output reg [31:0] q_b
);
    reg [31:0] ram [0:2047];
    integer i;
    initial begin
        for (i = 0; i < 2048; i = i + 1) ram[i] = 32'hF4F4F4F4;
        for (i = 0; i < 256; i = i + 1) ram[i] = 32'hE634B08F;
    end
    always @(posedge clock_a) begin
        if (enable_a && wren_a) begin
            if (byteena_a[0]) ram[address_a][7:0]   <= data_a[7:0];
            if (byteena_a[1]) ram[address_a][15:8]  <= data_a[15:8];
            if (byteena_a[2]) ram[address_a][23:16] <= data_a[23:16];
            if (byteena_a[3]) ram[address_a][31:24] <= data_a[31:24];
        end
        q_a <= ram[address_a];
    end
    always @(posedge clock_b) begin
        if (enable_b && wren_b) begin
            if (byteena_b[0]) ram[address_b][7:0]   <= data_b[7:0];
            if (byteena_b[1]) ram[address_b][15:8]  <= data_b[15:8];
            if (byteena_b[2]) ram[address_b][23:16] <= data_b[23:16];
            if (byteena_b[3]) ram[address_b][31:24] <= data_b[31:24];
        end
    end
    always @(*) q_b = ram[address_b];
endmodule
