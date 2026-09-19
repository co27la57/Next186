//////////////////////////////////////////////////////////////////////////////////
// Next186 cache_controller.v
// 基于原作者版本（neptuno-fpga/Next186_SoC，Nicolae Dumitrache）+ 本项目的 4-way begin
// 冗余（cache_addr 四个 way 的 index16-31 保持 tag=511，保证复位取指命中预填 BIOS）。
//
// 保留改动：
//   1) seg_map map[11] = 6  —— 文本 VRAM 窗 0x08068000，与 VGA(scraddr=0x6000)/PS 1:1 对齐
//   2) 保留 ILA 探针（mark_debug：lowaddr / s_lowaddr5 / dbg_ctl_* / isvwr），原版无这些探针
//
// ★ 本次修复（回退 af6f44b 后的"开倒车"）：
//   - 恢复 cache_line_start 单周期脉冲：每个 cache 行事务(读填充/写回)起始把 lowaddr 强
//     制归零，避免上一行残留的非 0 行内偏移污染下一行，造成半行(0x20)错位 / CPU 跑垃圾
//     （这正是 isvwr 不触发、dbg_IP 线性遍历的根因）。
//   - 恢复 flush 与 CPU 访问解耦：flush 扫描期间无论是否命中都写回脏行，保证清屏等
//     "全命中"写入能落到 DDR（isvwr / AWADDR 触发）。
//   - 关键：lowaddr 保持 5-bit（原作者），s_lowaddr5 = lowaddr[4]（电平 16..31 高、回绕
//     到 0 变低），**不用 6-bit + lowaddr[5]**（4b797fd 曾因此导致 s_lowaddr5 恒低死锁，
//     因为 cache_line_start 在 bit5 置位前就把 lowaddr 归零了）。
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
	 output reg ce = 1'b1,	// clock enable for CPU
	 input [15:0]ddr_din,
	 output reg[15:0]ddr_dout,
	 input ddr_clk,
	 input cache_write_data, // 1 when data must be written to cache, on posedge ddr_clk
	 input cache_read_data, // 1 when data must be read from cache, on posedge ddr_clk
	 output reg ddr_rd = 0,
	 output reg ddr_wr = 0,
	 output reg [`ADDR-`LINE-1:0]hiaddr,
	 input flush,
	 input cache_line_start   // ★ Task #8：ddr_186 在每次 cache 行事务(读填充/写回)确认时给的单周期脉冲，用于把 lowaddr 强制归零
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
	reg [`ADDR-`SETS-`LINE-1:0]cache_addr[0:(1<<`WAYS)-1][0:(1<<`SETS)-1]=
		'{'{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511},
		  '{1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511},
		  '{2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511},
		  '{3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511,511}};

	reg [2:0]STATE = 0;
	(* mark_debug = "true" *) reg [`LINE-2:0]lowaddr = 0; //cache mem address
	(* mark_debug = "true" *) reg s_lowaddr5 = 0;
	wire [31:0]cache_QA;
	wire [`WAYS-1:0]lru[(1<<`WAYS)-1:0];

	// ILA 探针寄存器（保留，原版无；不参加主逻辑）
	(* mark_debug = "true" *) reg        dbg_ctl_mreq_r;
	(* mark_debug = "true" *) reg [3:0]  dbg_ctl_wmask_r;
	(* mark_debug = "true" *) reg        dbg_ctl_mmreq_r;
	(* mark_debug = "true" *) reg        dbg_ctl_hit_r;
	(* mark_debug = "true" *) reg        dbg_ctl_ce_r;
	(* mark_debug = "true" *) reg        dbg_ctl_isvwr_r;
	(* mark_debug = "true" *) reg        dbg_ctl_rflush_r;
	(* mark_debug = "true" *) reg        dbg_ctl_ddr_wr_r;
	(* mark_debug = "true" *) reg [2:0]  dbg_ctl_STATE_r;
	(* mark_debug = "true" *) reg [`WAYS+`SETS:0] dbg_ctl_flushcount_r;
	(* mark_debug = "true" *) reg [3:0]  dbg_ctl_dirty_r;      // cache_dirty[index] 当前 index 的 4 way
	(* mark_debug = "true" *) reg [3:0]  dbg_ctl_fit_r;        // 当前访问的 way 命中向量
	(* mark_debug = "true" *) reg [4:0]  dbg_ctl_index_r;       // 当前 cache index
	(* mark_debug = "true" *) reg [9:0]  dbg_ctl_tag_r;         // 当前 cache tag = maddr[20:11]

	// ---- Task #8 诊断探针（深挖 dirty 置 1 条件，2026-09-19）----
	(* mark_debug = "true" *) reg        dbg_ctl_mwmask_v_r;  // 当拍 |mwmask 是否有效（与 isvwr 锁存值对比，验证 wmask 是否滞后 mreq）
	(* mark_debug = "true" *) reg [1:0]  dbg_ctl_blk_r;       // 实际写入选中 way（cache_mem port B 用 blk）
	(* mark_debug = "true" *) reg        dbg_ctl_fit_wr_r;    // fit[blk]：选中 way 是否真的命中(tag 匹配) —— 验证 blk/fit 错位 bug
	(* mark_debug = "true" *) reg        dbg_ctl_dirty_cond_r;// 整体置 dirty 条件：st0 & hit & |mwmask & |fit（任一子条件为 0 即不成立）
	(* mark_debug = "true" *) reg        dbg_ctl_dirty_wr_r;  // cache_dirty[index][blk]：实际写 way 的 dirty 当前值（1 拍延迟，写后次拍可见）

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
		// ★ Task #8 修复：每个 cache 行事务(cache_line_start 单周期脉冲)起始强置 lowaddr=0，
		//   消除上一行残留的非 0 行内偏移污染下一行（半行/0x20 错位根因：复位 miss 的 DDR
		//   行填充若从错误行内偏移开始写 cache，CPU 会读到垃圾 → 永不到达写显存指令 → isvwr 不触发）。
		if(cache_line_start) lowaddr <= {(`LINE-2){1'b0}};
		else if(cache_write_data || cache_read_data) lowaddr <= lowaddr + 1'b1;
		ddr_dout <= lowaddr[0] ? cache_QA[15:0] : cache_QA[31:16];
	end
		
	cache cache_mem
	(
		.clock_a(ddr_clk), // input clka
		.enable_a(cache_write_data | cache_read_data), // input ena
	  	.byteena_a({lowaddr[0], lowaddr[0], ~lowaddr[0], ~lowaddr[0]}),
		.wren_a(cache_write_data), // input [0 : 0] wea
		.address_a({blk, ~index[`SETS-1:10-`LINE], index[10-`LINE-1:0], lowaddr[`LINE-2:1]}), // input [10 : 0] addra
		.data_a({ddr_din, ddr_din}), // input [31 : 0] dina
		.q_a(cache_QA), // output [31 : 0] douta
		.clock_b(clk), // input clkb
		.enable_b(mmreq && hit && st0), // input enb
		.wren_b(|mwmask),
		.byteena_b(mwmask), // input [3 : 0] web
		.address_b({blk, ~index[`SETS-1:10-`LINE], index[10-`LINE-1:0], maddr[`LINE-1:2]}), // input [10 : 0] addrb
		.data_b(mdin), // input [31 : 0] dinb
		.q_b(dout) // output [31 : 0] doutb
	);

	generate
		for(i=0; i<(1<<`WAYS); i=i+1) begin: gen2
			always @(posedge clk) begin
				if(st0 && mmreq)
					if(hit) begin
						cache_lru[i][index] <= fit[i] ? {`WAYS{1'b1}} : cache_lru[i][index] - (cache_lru[i][index] > csblk); 
					end else if(free[i]) cache_dirty[index][i] <= 1'b0;
				// ★ Task #8 继续修复：BIU 2T 工作时 `RAM_MREQ` 与 `RAM_WMASK` 可能存在对齐/采样
				//   偏差，导致写命中那拍 `st0 && mmreq && hit && fit[i] && |mwmask` 漏采样，
				//   dirty bit 始终为 0，flush 跳过该行，`awaddr=0x08068000` 永不出现。
				//   这里加一条独立路径：只要 STATE=0、命中、且 wmask 非 0，就把 dirty 置 1。
				//   对读命中（|mwmask=0）无影响；对 miss/flush（hit=0 或 fit=0）无影响。
				if(st0 && hit && fit[i] && |mwmask)
					cache_dirty[index][i] <= 1'b1;
			end
		end
	endgenerate

		
	always @(posedge clk) begin
		s_lowaddr5 <= lowaddr[`LINE-2];
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
			if(mmreq && !hit) begin	// cache miss
				if(!r_flush) cache_addr[fblk][index] <= maddr[`ADDR-1:`LINE+`SETS];
				ddr_rd <= ~dirty & ~r_flush;
				ddr_wr <= dirty;
				STATE <= dirty ? 3'b011 : 3'b100;
				ce <= 1'b0;
			end else if(r_flush) begin
				// ★ 修复(回退 af6f44b 后丢失)：flush 与 CPU 访问解耦。
				//   清屏等"全命中"写入不产生 cache miss，原 else 分支只置 r_flush 标志后即放开
				//   CPU(ce<=1)，脏行永远写不回 DDR（波形表现：isvwr 期间 awvalid/wvalid=0）。
				//   现改为：只要 r_flush 有效，无论 CPU 是否访问，都扫描当前行并写回脏行。
				flushcount[`WAYS+`SETS] <= flushcount[`WAYS+`SETS] | flushreq;
				if(dirty) begin
					ddr_rd <= 1'b0;
					ddr_wr <= 1'b1;
					STATE <= 3'b011;   // 写回当前脏行
				end else begin
					STATE <= 3'b100;   // 当前行干净，直接推进扫描下一行
				end
				ce <= 1'b0;            // 写回期间挂起 CPU，与正常 evict 一致，避免丢写
			end else begin
				flushcount[`WAYS+`SETS] <= flushcount[`WAYS+`SETS] | flushreq;
				ce <= 1'b1;
			end
		end
		3'b011: begin	// write cache to ddr
			ddr_rd <= ~r_flush; //1'b1;
			if(s_lowaddr5) begin
				ddr_wr <= 1'b0;
				// ★ flush 写完脏行后直接推进扫描(STATE 100)，不再进入 111 回填：
				//   否则会把刚写回 DDR 的行又用 DDR 旧数据覆盖掉，且与晚到的 CPU 写入存在回写竞态。
				STATE <= r_flush ? 3'b100 : 3'b111;
			end
		end
		3'b111: begin // read cache from ddr
			if(~r_flush) hiaddr <= maddr[`ADDR-1:`LINE]; // flush 期间不改 hiaddr（写回地址已在 STATE 000 锁定）
			if(~s_lowaddr5) STATE <= 3'b100;
		end
			3'b100: begin	
				if(r_flush) begin
					flushcount <= flushcount + 1'b1;
					STATE <= 3'b000;
				end else if(s_lowaddr5) begin
					ddr_rd <= 1'b0;
					STATE <= 3'b101;
				end else begin
					// ★ 防止 STATE 111 退出时 s_lowaddr5 已被采样为低（CDC/相位导致错过高电平），
					//   否则 STATE 100 在 r_flush=0/s_lowaddr5=0 时无分支，会卡死。
					ddr_rd <= 1'b0;
					STATE <= 3'b000;
				end
			end
			3'b101: begin
				if(~s_lowaddr5) STATE <= 3'b000;
			end
		endcase
	end

	// ILA 探针采样
	always @(posedge clk) begin
		dbg_ctl_mreq_r   <= mreq;
		dbg_ctl_wmask_r  <= wmask;
		dbg_ctl_mmreq_r  <= mmreq;
		dbg_ctl_hit_r    <= hit;
		dbg_ctl_ce_r     <= ce;
		dbg_ctl_isvwr_r  <= is_video_wr;
		dbg_ctl_rflush_r  <= r_flush;
		dbg_ctl_ddr_wr_r  <= ddr_wr;
		dbg_ctl_STATE_r   <= STATE;
		dbg_ctl_flushcount_r <= flushcount;
		dbg_ctl_dirty_r    <= cache_dirty[index];
		dbg_ctl_fit_r      <= fit;
		dbg_ctl_index_r    <= index;
		dbg_ctl_tag_r      <= maddr[`ADDR-1:`LINE+`SETS];
		// ---- Task #8 诊断探针采样 ----
		dbg_ctl_mwmask_v_r  <= |mwmask;
		dbg_ctl_blk_r       <= blk;
		dbg_ctl_fit_wr_r    <= fit[blk];
		dbg_ctl_dirty_cond_r <= st0 && hit && |mwmask && |fit;
		dbg_ctl_dirty_wr_r   <= cache_dirty[index][blk];
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
									10, 6,	// 文本 VRAM 窗对齐到 0x08068000（map[11]=6），与 VGA scraddr/PS 1:1；原版为 11
									18, 19, 20, 21,
									22,	// HMA
									1, 2, 3, 4, 5, 6, 7, 8, 9, 
									10, 11, 12, 13, 14, 15}; // VGA seg 1..6			
	reg [15:0]vga_seg = 16'h0000;
	assign memdata = map[memaddr];
	assign vga_planar_seg = vga_seg[seg_addr];
	
	always @(posedge CLK) begin
		if(WE) begin
			map[{1'b0, cpuaddr}] <= cpuwdata;
			vga_seg[cpuaddr] <= cpuwdata == 9'ha;
		end
		cpurdata <= map[{1'b0, cpuaddr}]; // cpuaddr is constrained at 2T multicycle, but here it should be ready after 1T!!!
	end

endmodule
