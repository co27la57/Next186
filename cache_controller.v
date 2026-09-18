//////////////////////////////////////////////////////////////////////////////////
// Next186 cache_controller.v - 原版恢复 + 4-way begin 代码冗余
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps
`define WAYS	2	// 2^ways
`define SETS	5	// 2^sets
`define LINE	6	// 2^LINE bytes / cache line
`define ADDR	21

module cache_controller(
	 input [`ADDR-1:0]addr,
     output [31:0]dout,
	 input [31:0]din,
	 input clk,	
	 input mreq,
	 input [3:0]wmask,
	 output reg ce = 1'b1,
	 input [15:0]ddr_din,
	 output reg[15:0]ddr_dout,
	 input ddr_clk,
	 input cache_write_data,
	 input cache_read_data,
	 output reg ddr_rd = 0,
	 output reg ddr_wr = 0,
	 output reg [`ADDR-`LINE-1:0]hiaddr,
	 input flush
    );
	
	initial ce = 1'b1;
	
	reg [`ADDR-1:0]raddr;
	reg [31:0]rdin;
	reg [3:0]rwmask;
	reg rmreq;
	wire [`ADDR-1:0]maddr = ce ? addr : raddr;
	wire [31:0]mdin = ce ? din : rdin;
	wire [3:0]mwmask = ce ? wmask : rwmask;
	wire mmreq = ce ? mreq : rmreq;
	
	reg flushreq = 1'b0;
	reg [`WAYS+`SETS:0]flushcount = 0;
	wire r_flush = flushcount[`WAYS+`SETS];
	wire [`SETS-1:0]index = r_flush ? flushcount[`SETS-1:0] : maddr[`LINE+`SETS-1:`LINE];
	wire [(1<<`WAYS)-1:0]fit;
	wire [(1<<`WAYS)-1:0]free;
	
	reg [(1<<`WAYS)-1:0]cache_dirty[0:(1<<`SETS)-1] = 
		'{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1};
	reg [`WAYS-1:0]cache_lru[0:(1<<`WAYS)-1][0:(1<<`SETS)-1] =
		'{'{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
		  '{1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1},
		  '{2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2},
		  '{3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3}};
	
	// ============================================================
	// ★ cache_addr：way0 index0-15=0 / 16-31=511
	//               way1/2/3 index0-15=way号 / 16-31=511
	// ============================================================
	reg [`ADDR-`SETS-`LINE-1:0]cache_addr[0:(1<<`WAYS)-1][0:(1<<`SETS)-1]=
		'{'{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511},
		  '{1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511},
		  '{2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511},
		  '{3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511}};

	reg [2:0]STATE = 0;
	(* mark_debug = "true" *) reg [`LINE-1:0]lowaddr = 0;   // 6位：64B行=32半字，需计数到 32
	(* mark_debug = "true" *) reg s_lowaddr5 = 0;
	// 跨时钟域同步：ddr_clk 的整行完成标志(lowaddr[LINE-1]) → clk 域，避免 1 拍脉冲被漏采
	reg s_lowaddr5_meta = 0, s_lowaddr5_sync = 0;
	wire [31:0]cache_QA;
	wire [`WAYS-1:0]lru[(1<<`WAYS)-1:0];
	
	// ILA 探针寄存器
	(* mark_debug = "true" *) reg        dbg_ctl_mreq_r;
	(* mark_debug = "true" *) reg [3:0]  dbg_ctl_wmask_r;
	(* mark_debug = "true" *) reg        dbg_ctl_mmreq_r;
	(* mark_debug = "true" *) reg        dbg_ctl_hit_r;
	(* mark_debug = "true" *) reg        dbg_ctl_ce_r;
	(* mark_debug = "true" *) reg        dbg_ctl_isvmem_r;
	(* mark_debug = "true" *) reg        dbg_ctl_isvwr_r;
	(* mark_debug = "true" *) reg        dbg_ctl_rflush_r;   // flush 扫描进行中(r_flush)
	(* mark_debug = "true" *) reg        dbg_ctl_ddr_wr_r;   // cache→DDR 写回脉冲(应产生 AXI awvalid/wvalid)
	
	// 视频地址判断（仅用于 ILA 探针，不参与主逻辑）
	wire is_video_mem = (maddr[`ADDR-1:12] == 9'h0B8);
	wire is_video_wr  = is_video_mem & (|mwmask);

	genvar i;
	generate
		for(i=0; i<(1<<`WAYS); i=i+1) begin: gen1
			assign fit[i] = ~r_flush && (cache_addr[i][index] == maddr[`ADDR-1:`LINE+`SETS]);
			assign free[i] = r_flush ? (flushcount[`WAYS+`SETS-1:`SETS] == i) : ~|cache_lru[i][index];
			assign lru[i] = {`WAYS{fit[i]}} & cache_lru[i][index];
		end
	endgenerate
		
	wire hit = |fit;
	wire st0 = STATE == 3'b000;
	wire dirty = |(free & cache_dirty[index]);	

	wire [`WAYS-1:0]blk = flushcount[`WAYS+`SETS-1:`SETS] | {|fit[3:2], fit[3] | fit[1]};
	wire [`WAYS-1:0]fblk = {|free[3:2], free[3] | free[1]};
	wire [`WAYS-1:0]csblk = lru[0] | lru[1] | lru[2] | lru[3];

	always @(posedge ddr_clk) begin
		if(cache_write_data || cache_read_data) begin
			// 64B 整行 = 32 半字；计满(lowaddr[5]置位)后归零，保证每行从 0 开始、行行衔接正确
			if(lowaddr[`LINE-1]) lowaddr <= {`LINE-1{1'b0}};
			else                lowaddr <= lowaddr + 1'b1;
		end
		ddr_dout <= lowaddr[0] ? cache_QA[15:0] : cache_QA[31:16];
	end
		
	cache cache_mem
	(
		.clock_a(ddr_clk),
		.enable_a(cache_write_data | cache_read_data),
	  	.byteena_a({lowaddr[0], lowaddr[0], ~lowaddr[0], ~lowaddr[0]}),
		.wren_a(cache_write_data),
		.address_a({blk, ~index[`SETS-1:10-`LINE], index[10-`LINE-1:0], lowaddr[`LINE-2:1]}),
		.data_a({ddr_din, ddr_din}),
		.q_a(cache_QA),
		.clock_b(clk),
		.enable_b(mmreq && hit && st0),
		.wren_b(|mwmask),
		.byteena_b(mwmask),
		.address_b({blk, ~index[`SETS-1:10-`LINE], index[10-`LINE-1:0], maddr[`LINE-1:2]}),
		.data_b(mdin),
		.q_b(dout)
	);

	generate
		for(i=0; i<(1<<`WAYS); i=i+1) begin: gen2
			always @(posedge clk) 
				if(st0 && mmreq)
					if(hit) begin
						cache_lru[i][index] <= fit[i] ? {`WAYS{1'b1}} : cache_lru[i][index] - (cache_lru[i][index] > csblk); 
						if(fit[i]) cache_dirty[index][i] <= cache_dirty[index][i] || (|mwmask);
					end else if(free[i]) cache_dirty[index][i] <= 1'b0;
		end
	endgenerate

	// 跨时钟域：将 ddr_clk 域的整行完成标志(lowaddr[LINE-1]) 同步到 clk 域（2 级打拍，避免 1 拍脉冲漏采）
	always @(posedge clk) begin
		s_lowaddr5_meta <= lowaddr[`LINE-1];
		s_lowaddr5_sync <= s_lowaddr5_meta;
	end

	always @(posedge clk) begin
		s_lowaddr5 <= s_lowaddr5_sync;   // 整 64B 行完成标志（原 lowaddr[LINE-2] 误在半行处置位，导致行只填一半）
		flushreq <= ~flushcount[`WAYS+`SETS] & (flushreq | flush);
		if(ce) begin
			raddr <= addr;
			rdin <= din;
			rwmask <= wmask;
			rmreq <= mreq;
		end
		
		case(STATE)
		3'b000: begin
			hiaddr <= dirty ? {cache_addr[fblk][index], index} : maddr[`ADDR-1:`LINE]; 
			if(mmreq && !hit) begin
				if(!r_flush) cache_addr[fblk][index] <= maddr[`ADDR-1:`LINE+`SETS];
				ddr_rd <= ~dirty & ~r_flush;
				ddr_wr <= dirty;
				STATE <= dirty ? 3'b011 : 3'b100;
				ce <= 1'b0;
			end else if(r_flush) begin
				// ★ 修复(commit: cache-flush-wrbk)：flush 扫描与 CPU 访问解耦。
				//   原实现把脏行写回挂在 mmreq&&!hit(缓存缺失) 分支下；清屏等"全命中"写入
				//   不产生 miss，导致 flush 永远走 else 分支、r_flush 置起后状态机卡在 000，
				//   脏行永远写不回 DDR（波形表现为 isvwr 密集脉冲时 awvalid/wvalid=0）。
				//   现改为：只要 r_flush 有效，无论 CPU 是否访问，都扫描当前行并写回脏行。
				flushcount[`WAYS+`SETS] <= flushcount[`WAYS+`SETS] | flushreq;
				if(dirty) begin
					ddr_rd <= 1'b0;
					ddr_wr <= 1'b1;
					STATE <= 3'b011;   // 写回当前脏行
				end else begin
					STATE <= 3'b100;   // 当前行干净，直接进入推进状态扫描下一行
				end
				ce <= 1'b0;            // 写回期间挂起 CPU（与正常 evict 一致，避免丢写）
			end else begin
				flushcount[`WAYS+`SETS] <= flushcount[`WAYS+`SETS] | flushreq;
				ce <= 1'b1;
			end
		end
			
		3'b011: begin	// write cache to ddr
			ddr_rd <= ~r_flush;
			if(s_lowaddr5) begin
				ddr_wr <= 1'b0;
				// ★ 修复：flush 写完脏行后直接推进扫描(STATE 100)，不再进入 111/101 回填，
				//   否则会把刚写回 DDR 的行又用 DDR 旧数据覆盖掉，且 STATE 111 无 DDR 活动时
				//   lowaddr 不推进会卡死。
				STATE <= r_flush ? 3'b100 : 3'b111;
			end
		end
			
		3'b111: begin // read cache from ddr
			if(~r_flush) hiaddr <= maddr[`ADDR-1:`LINE]; // flush 期间不改 hiaddr（写回地址已在 STATE 000 锁定）
			if(~s_lowaddr5) STATE <= 3'b100;
		end
			
		3'b100: begin
			if(r_flush) begin
				// ★ 修复：单遍扫描 4-way×32-set（共 128 行）即终止。
				//   原实现 flushcount 溢出到 256 才因 bit7 回绕归零，导致每个 (way,set)
				//   被扫描两遍、脏行写回两次（2× DDR 带宽，且与晚到的 CPU 写入存在回写竞态）。
				//   现扫描到最后一项（flushcount[6:0]==7'h7F）即清 r_flush 标志(bit7)并复位索引。
				if(flushcount[6:0] == 7'h7F) begin
					flushcount <= {1'b0, 7'h00};   // 清 r_flush(bit7) + 复位扫描索引，干净终止
					STATE <= 3'b000;
				end else begin
					flushcount <= flushcount + 1'b1;
					STATE <= 3'b000;
				end
			end else if(s_lowaddr5) begin
				ddr_rd <= 1'b0;
				STATE <= 3'b101;
			end
		end
			
			3'b101: begin
				if(~s_lowaddr5) STATE <= 3'b000;
			end
		endcase
	end

	// ============================================================
	// ILA 探针采样
	// ============================================================
	always @(posedge clk) begin
		dbg_ctl_mreq_r   <= mreq;
		dbg_ctl_wmask_r  <= wmask;
		dbg_ctl_mmreq_r  <= mmreq;
		dbg_ctl_hit_r    <= hit;
		dbg_ctl_ce_r     <= ce;
		dbg_ctl_isvmem_r <= is_video_mem;
		dbg_ctl_isvwr_r  <= is_video_wr;
		dbg_ctl_rflush_r  <= r_flush;
		dbg_ctl_ddr_wr_r  <= ddr_wr;
	end
	
endmodule

module seg_map(
	 input CLK,
	 input [3:0]cpuaddr,
	 output reg [8:0]cpurdata,
	 input [8:0]cpuwdata,
	 input [4:0]memaddr,
	 output [8:0]memdata,
	 input WE,
	 input [3:0]seg_addr,
	 output vga_planar_seg
    );

	reg [8:0]map[0:31] = '{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
									10, 10,
									18, 19, 20, 21,
									22,
									1, 2, 3, 4, 5, 6, 7, 8, 9, 
									10, 11, 12, 13, 14, 15};
	reg [15:0]vga_seg = 16'h0000;
	assign memdata = map[memaddr];
	assign vga_planar_seg = vga_seg[seg_addr];
	
	always @(posedge CLK) begin
		if(WE) begin
			map[{1'b0, cpuaddr}] <= cpuwdata;
			vga_seg[cpuaddr] <= cpuwdata == 9'ha;
		end
		cpurdata <= map[{1'b0, cpuaddr}];
	end

endmodule