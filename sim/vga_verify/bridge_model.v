// VGA read path from top_zynq7010: ram_addr counts 16-bit halfwords.
// AXI slave delays are repeatable; each transaction returns 16x32-bit beats.
module vga_fb_model #(parameter DEPTH=1048576)(
    input clk, rst_n, short_vga, input [31:0] stall_seed, input [7:0] max_stall,
    input [1:0] ram_cmd, input [23:0] ram_addr,
    output reg [1:0] ram_cmd_ack,
    output wire [15:0] ram_rdata, output wire ram_rd_valid,
    input h_wr, input [23:0] h_addr, input [15:0] h_din,
    output wire busy, output wire [23:0] data_addr,
    output wire [3:0] state_debug
);
    localparam IDLE=0, AR_ADDR=1, R_WAIT=2, R_PUSH_0=3, R_PUSH_1=4;
    reg [15:0] mem [0:DEPTH-1];
    reg [3:0] state=0, idle_cnt=0;
    reg [31:0] random_state=1;
    reg [7:0] delay_count=0;
    reg [4:0] beat=0;
    reg [4:0] last_beat=15;
    reg [23:0] base=0;
    reg [31:0] latched_rdata=0;
    reg main_rready=0;
    wire [31:0] random_next={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
    wire [7:0] next_delay=max_stall==0 ? 0 : random_next % (max_stall+1);
    assign ram_rd_valid=state==R_PUSH_0 || state==R_PUSH_1;
    assign ram_rdata=state==R_PUSH_0 ? latched_rdata[15:0] : latched_rdata[31:16];
    assign data_addr=base+{beat,1'b0}+(state==R_PUSH_1);
    assign busy=state!=IDLE;
    assign state_debug=state;
    always @(posedge clk) begin
        if(h_wr) mem[h_addr & (DEPTH-1)]<=h_din;
        if(!rst_n) begin
            state<=IDLE; idle_cnt<=0; ram_cmd_ack<=0;
            random_state<=stall_seed==0 ? 1 : stall_seed;
            delay_count<=0; main_rready<=0; beat<=0;
        end else begin
            random_state<=random_next;
            case(state)
                IDLE: begin
                    main_rready<=0;
                    if(idle_cnt<5) begin
                        idle_cnt<=idle_cnt+1'b1;
                        ram_cmd_ack<=0;
                    end else if(ram_cmd==2'b10 || ram_cmd==2'b11) begin
                        ram_cmd_ack<=ram_cmd;
                        idle_cnt<=0;
                        base<=ram_addr;
                        beat<=0;
                        last_beat<=short_vga && ram_cmd==2 ?
                              (&ram_addr[8:4] ? {2'b0,~ram_addr[3:1]} : 5'd7) : 5'd15;
                        delay_count<=next_delay;
                        state<=AR_ADDR;
                    end
                end
                AR_ADDR: begin
                    if(delay_count!=0) delay_count<=delay_count-1'b1;
                    else begin state<=R_WAIT; delay_count<=next_delay; end
                end
                R_WAIT: begin
                    main_rready<=1;
                    if(delay_count!=0) delay_count<=delay_count-1'b1;
                    else if(main_rready) begin
                        latched_rdata<={mem[(base+2*beat+1)&(DEPTH-1)],mem[(base+2*beat)&(DEPTH-1)]};
                        main_rready<=0;
                        state<=R_PUSH_0;
                    end
                end
                R_PUSH_0: state<=R_PUSH_1;
                R_PUSH_1: begin
                    if(beat==last_beat) state<=IDLE;
                    else begin
                        beat<=beat+1'b1;
                        state<=R_WAIT;
                        delay_count<=next_delay;
                    end
                end
            endcase
        end
    end
endmodule
