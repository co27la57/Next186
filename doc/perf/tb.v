`timescale 1ns/1ps
module tb;
    reg clk=0, rst=1;
    always #10 clk = ~clk;                    // 50 MHz

    reg  [31:0] mem [0:15];
    reg  [4:0]  idx;                          // 已送出的 beat 数
    reg         rvalid; reg [31:0] rdata; reg rlast;
    wire        rready, dvalid, done; wire [15:0] d16;

    rd_fsm u(.clk(clk), .rst(rst), .m_rvalid(rvalid), .m_rdata(rdata), .m_rlast(rlast),
             .m_rready(rready), .d16(d16), .dvalid(dvalid), .burst_done(done));

    // ---- 从机: 只要 rready 就交下一拍; rvalid 连续(与实测一致) ----
    integer stall;                            // 从机卡顿拍数
    always @(posedge clk) begin
        if (rst) begin idx<=0; rvalid<=1'b0; rlast<=1'b0; rdata<=32'd0; stall<=0; end
        else if (stall>0) begin
            stall<=stall-1;
            if (stall==1) begin rvalid<=1'b1; rdata<=mem[idx]; rlast<=(idx==15); end
        end else if (!rvalid) begin
            if (idx<16) begin rvalid<=1'b1; rdata<=mem[idx]; rlast<=(idx==15); end
        end else if (rready) begin
            if (idx==15) begin rvalid<=1'b0; rlast<=1'b0; end
            else begin idx<=idx+1; rdata<=mem[idx+1]; rlast<=(idx+1==15); end
            $display("  [slave] beat %0d accepted @%0t", idx, $time);
        end
    end

    // ---- 收集半字并校验顺序 ----
    integer nh=0; reg [15:0] got [0:31];
    always @(posedge clk) if (!rst && dvalid) begin
        got[nh] <= d16;
        $display("  [dut] half %0d = %04h  (state word%0d %s)", nh, d16, nh/2, (nh%2==0)?"LOW":"HIGH");
        nh <= nh+1;
    end

    integer i, errs; integer t0;
    initial begin
        for (i=0;i<16;i=i+1) mem[i] = 32'hA000_0000 + i*32'h0001_0001;
        rvalid=0; rlast=0; stall=0; errs=0;
        #45 rst=0;
        @(posedge done); #1;
        $display("\n收到半字数 = %0d (应为 32), 用时 %0t", nh, $time);
        if (nh != 32) begin $display("!! 半字数不对"); errs=errs+1; end
        for (i=0;i<16;i=i+1) begin
            if (got[2*i]   !== mem[i][15:0])  begin $display("!! half %0d 错: %04h != %04h", 2*i, got[2*i], mem[i][15:0]); errs=errs+1; end
            if (got[2*i+1] !== mem[i][31:16]) begin $display("!! half %0d 错: %04h != %04h", 2*i+1, got[2*i+1], mem[i][31:16]); errs=errs+1; end
        end
        $display(errs==0 ? "==> PASS: 32 个半字全部顺序正确" : "==> FAIL");
        $finish;
    end
endmodule
