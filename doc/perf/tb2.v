`timescale 1ns/1ps
module tb2;
    reg clk=0, rst=1; always #10 clk=~clk;
    reg [31:0] mem [0:15];
    reg [4:0] idx; reg rvalid, rlast; reg [31:0] rdata;
    wire rready, dvalid, done; wire [15:0] d16;
    rd_fsm u(.clk(clk),.rst(rst),.m_rvalid(rvalid),.m_rdata(rdata),.m_rlast(rlast),
             .m_rready(rready),.d16(d16),.dvalid(dvalid),.burst_done(done));

    integer gap_before;                       // 第几个 beat 之前插入空档
    integer gap_len;
    initial begin gap_before = 6; gap_len = 10; end

    // 从机: 连续送, 但在 beat 6 之前空档 10 拍
    integer st_left = 0;
    always @(posedge clk) begin
        if (rst) begin idx<=0; rvalid<=1'b0; rlast<=1'b0; rdata<=0; st_left<=0; end
        else if (st_left > 0) begin
            st_left <= st_left-1;
            if (st_left==1) begin rvalid<=1'b1; rdata<=mem[idx]; rlast<=(idx==15); end
        end else if (!rvalid) begin
            if (idx<16) begin rvalid<=1'b1; rdata<=mem[idx]; rlast<=(idx==15); end
        end else if (rready) begin
            if (idx==15) begin rvalid<=0; rlast<=0; end
            else if (idx+1 == gap_before && gap_len>0) begin
                idx<=idx+1; rvalid<=0; rlast<=0; st_left<=gap_len;   // 插空档
            end else begin idx<=idx+1; rdata<=mem[idx+1]; rlast<=(idx+1==15); end
        end
    end

    integer nh=0, bad=0, i;
    reg [15:0] got [0:31];
    always @(posedge clk) if (!rst && dvalid) begin
        got[nh] <= d16;
        if (nh % 2 == 0 && d16 !== mem[nh/2][15:0])  bad<=bad+1;
        if (nh % 2 == 1 && d16 !== mem[nh/2][31:16]) bad<=bad+1;
        nh <= nh+1;
    end

    initial begin
        for (i=0;i<16;i=i+1) mem[i] = 32'hB000_0000 + i*32'h0001_0001;
        #45 rst=0;
        @(posedge done); #1;
        $display("半字数=%0d  错误=%0d", nh, bad);
        if (nh==32 && bad==0) $display("RESULT_OK");
        else                  $display("RESULT_BAD");
        $finish;
    end
endmodule
