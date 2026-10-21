// Test-only: isolate pure OPL/mixer audio by holding the DSS FIFO empty.
// This stub does not validate DSS writes or the production FIFO width.
module sndfifo(input wrclk,rdclk,rst,input [31:0] data,input wrreq,rdreq,
    output [31:0] q,output [11:0] wrusedw,rdusedw,output rdempty);
    assign q=0;
    assign wrusedw=0;
    assign rdusedw=0;
    assign rdempty=1;
endmodule

// Cycle-equivalent translation of audio_top.vhd + dac_if.vhd for Verilator.
// The real production VHDL remains untouched. No sample-format conversion
// occurs here, exactly as in the VHDL's signed type cast and shift register.
module audio_top(input clk_50MHz,input [15:0] L_data,R_data,
    output dac_MCLK,dac_LRCK,dac_SCLK,dac_SDIN);
    reg [19:0] tcount=0;
    reg dac_load_L=0,dac_load_R=0;
    reg [15:0] sreg=0;
    assign dac_MCLK=clk_50MHz;
    assign dac_LRCK=tcount[9];
    assign dac_SCLK=tcount[4];
    assign dac_SDIN=sreg[15];
    always @(posedge clk_50MHz) begin
        dac_load_L <= tcount[9:0]>=10'h00f && tcount[9:0]<10'h02e;
        dac_load_R <= tcount[9:0]>=10'h20f && tcount[9:0]<10'h22e;
        tcount<=tcount+1'b1;
    end
    always @(negedge dac_SCLK) begin
        if(dac_load_L) sreg<=L_data;
        else if(dac_load_R) sreg<=R_data;
        else sreg<={sreg[14:0],1'b0};
    end
endmodule
