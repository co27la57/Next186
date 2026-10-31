`timescale 1ns/1ps
// 读数据通路 2 拍/beat 版本: 双缓冲乒乓, rready 在 PUSH_0 保持
module rd_fsm(
    input  wire        clk, rst,
    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,
    input  wire        m_rlast,
    output reg         m_rready,
    output wire [15:0] d16,
    output wire        dvalid,
    output reg         burst_done
);
    localparam W=2'd0, P0=2'd1, P1=2'd2;
    reg [1:0]  st;
    reg [31:0] cur, nxt;
    reg        cur_last, nxt_valid, nxt_last;

    assign d16    = (st==P0) ? cur[15:0] : cur[31:16];
    assign dvalid = (st==P0) || (st==P1);

    always @(posedge clk) begin
        if (rst) begin
            st<=W; m_rready<=1'b0; burst_done<=1'b0;
            nxt_valid<=1'b0; cur_last<=1'b0; nxt_last<=1'b0; cur<=32'd0; nxt<=32'd0;
        end else begin
            burst_done <= 1'b0;
            case (st)
            W: begin
                m_rready <= 1'b1;
                nxt_valid<= 1'b0;
                if (m_rvalid && m_rready) begin
                    cur      <= m_rdata;
                    cur_last <= m_rlast;
                    st       <= P0;
                end
            end
            P0: begin
                m_rready <= 1'b0;                       // 下一拍(P1)不再接收
                if (m_rvalid && m_rready) begin          // 本拍接收下一 beat
                    nxt       <= m_rdata;
                    nxt_last  <= m_rlast;
                    nxt_valid <= 1'b1;
                end
                st <= P1;
            end
            P1: begin
                if (nxt_valid) begin
                    cur       <= nxt;                    // 换缓冲
                    cur_last  <= nxt_last;
                    nxt_valid <= 1'b0;
                    m_rready  <= ~nxt_last;              // 最后一拍就别再要了
                    st        <= P0;
                end else if (cur_last) begin
                    m_rready  <= 1'b0;
                    st        <= W;
                    burst_done<= 1'b1;
                end else begin
                    m_rready  <= 1'b1;                   // 存储器没跟上, 回去等
                    st        <= W;
                end
            end
            endcase
        end
    end
endmodule
