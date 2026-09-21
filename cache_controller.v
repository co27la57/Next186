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
// ★★ 新增（2026-09-19）：整行 64B burst 完成后再切状态。
//     原代码在 s_lowaddr5 上升沿（lowaddr=16，burst 中点）就退出 STATE 011/111，但 top_zynq7010.v
//     的 AXI FSM 固定发 16 拍 burst（32 个 16bit 字=64B）。状态机提前切走会导致第二半 burst 期间
//     hiaddr 被改/新事务开始，写回/填充数据错位，表现为 0x20/0x40 偏移。现改为检测 s_lowaddr5
//     下降沿（lowaddr 从 31 回绕到 0）才退出，确保整行 64B 完成。
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
	 output reg[31:0]ddr_dout,
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
	(* mark_debug = "true" *) reg s_lowaddr5_d1 = 0;
	wire s_lowaddr5_fall = s_lowaddr5_d1 & ~s_lowaddr5; // lowaddr 从 31 回绕到 0，标志整行 64B burst 完成
	// ★ 十一次修复：flush 写回完成事件（STATE 011 且 r_flush 且整行 burst 结束，ddr_wr 此拍仍为 1）。
	//   十次修复曾把"flush 写回后清 dirty"直接写在 STATE 块里，导致 cache_dirty 同时被
	//   LRU/dirty 块和 STATE 块两个 always 写端口驱动，Vivado 无法推断 RAM ->
	//   Synth 8-2914 Unsupported RAM template [v:70] + 8-5743，综合直接失败。
	//   现将清 dirty 挪入 LRU/dirty 块（下方），cache_dirty 恢复单写端口。
	// ★ 二十一次修复（2026-09-20）：写回完成即清脏位——无论 flush 写回还是"读缺失逐出"写回。
	//   根因：VGA 每帧扫描文本缓冲，对未命中行触发读缺失 → 先把脏行(字符串)写回 DDR(STATE 011)、
	//   再填充新行(STATE 111)。原 flush_wb_done 仅当 r_flush 才清脏位；读缺失逐出写回(r_flush=0)后
	//   脏位未清 → 该 way 仍脏、且其槽位已被 DDR 旧值(=0)填充 → 随后 flush 把"0"再次写回 DDR，
	//   覆盖掉字符串 → 前段 VRAM(index0 及被 VGA 先读的行)整片变 0（本次实测 cells 0-33 全 0）。
	//   现改为：任何 STATE 011 写回完成都清对应 way 的脏位（用写回时冻结的 wb_hiaddr/wb_way，
	//   与 flush/逐出同源，两类写回均指向正确的 index/way）。
	wire flush_wb_done = (STATE == 3'b011) && ddr_wr && s_lowaddr5_fall;
	wire [31:0]cache_QA;

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
	(* mark_debug = "true" *) reg        dbg_ctl_s_lowaddr5_fall_r; // 整行 burst 完成标志（下降沿判活）
	// ---- Task #8 八次诊断探针：flush 扫描判脏链路（2026-09-19）----
	(* mark_debug = "true" *) reg        dbg_ctl_flushreq_r;   // flush 脉冲锁存
	(* mark_debug = "true" *) reg        dbg_ctl_dirtywire_r;  // dirty 组合线本体（flush 分支实际判据）
	// ★ 十四次诊断探针：VRAM 行写回事件捕获。
	//   VRAM 行 = index0 / tag=0x170 / hiaddr=0x2E00 / 物理 0x08068000 / sdraddr=0x034000。
	//   用户 message 3 看到的 sdraddr=034000-0344a8 串极可能是 VGA 持续读文本帧缓冲（ddr_rd），
	//   与 VRAM 写回（ddr_wr，同地址）难以用裸 sdraddr 区分。此探针在"STATE=011 且 ddr_wr=1 且
	//   写回地址=0x2E00(VRAM)"时置 1，可一锤定音：能触发=VRAM 写回确实发生（之前为 VGA 读误判），
	//   永不触发=VRAM 行从未成为 victim，需回头查 victim 选择 / LRU 退化。
	(* mark_debug = "true" *) reg        dbg_ctl_vram_wr_r;
	// ★ 十六次诊断探针（纯观测，不参与任何主逻辑）：把"CPU 到底有没有写 VRAM"和
	//   "VRAM 到底有没有写回 DDR"做成**粘滞标志**（置 1 后一直保持），这样上板跑一段时间后
	//   直接读这两个 bit 即可，无需触发、不受 1028 采样窗口远短于一帧(16.7ms)的限制。
	//   判读：isvwr_sticky=0 → CPU 从未写 VRAM（问题不在 cache，在 CPU/BIOS 流程）；
	//         isvwr_sticky=1 且 vram_wr_sticky=0 → VRAM 脏了却从不写回（真 cache bug）；
	//         两者都=1 → VRAM 写回已发生，转查 VGA 读地址。
	(* mark_debug = "true" *) reg        dbg_ctl_isvwr_sticky_r = 1'b0;   // CPU 曾写 VRAM（粘滞，显式上电清零防误判）
	(* mark_debug = "true" *) reg        dbg_ctl_vram_wr_sticky_r = 1'b0; // VRAM 行曾写回 DDR（粘滞，显式上电清零防误判）
	// ★ 十六次续：判别"isvwr=1 但 vram_wr=0"的三种真因（纯观测粘滞标志）
	//   A: VRAM 写全是 miss（永不 hit）→ 填充不置 dirty，VRAM 永不脏
	//   B: VRAM 曾 hit（dirty 已置 1），但 flush 扫描时 VRAM 行已不在 cache / 已不脏
	//   C: flush 扫到 VRAM 行且判为脏，却没产生带 VRAM tag 的写回 → 写回地址/way 错配
	(* mark_debug = "true" *) reg        dbg_vram_wr_hit_sticky = 1'b0;      // VRAM 写命中（命中即 dirty 被置 1）
	(* mark_debug = "true" *) reg        dbg_vram_wr_miss_sticky = 1'b0;     // VRAM 写缺失（走填充，dirty 不置 1）
	(* mark_debug = "true" *) reg        dbg_flush_vram_seen_sticky = 1'b0;  // flush 扫描时遇到过 VRAM 行（tag 0x170/0x171，不论脏否）
	(* mark_debug = "true" *) reg        dbg_flush_vram_dirty_sticky = 1'b0; // flush 扫描时遇到过 VRAM 行且判为脏
	// ★ 十七次：确认"flush 窗口里是否真有待处理 CPU 请求"（修复前会被静默丢弃的那个前提）
	(* mark_debug = "true" *) reg        dbg_miss_in_flush_sticky = 1'b0;

	// ---- Task #8 诊断探针（保留：way 选择与 LRU 轮转观测）----
	(* mark_debug = "true" *) reg [1:0]  dbg_ctl_blk_r;       // 实际写入选中 way（cache_mem port B 用 blk）
	(* mark_debug = "true" *) reg [1:0]  dbg_ctl_lru_wr_r;    // cache_lru[blk][index]：命中 way 的 LRU 当前值（十五次 LRU 轮转修复的验证依据）
	// ★ 二十三次探针（拍错方案 A，2026-09-21）：观测写回数据相对读地址 lowaddr 的滞后相位。
	//   cache_QA = BRAM q_a 输出（lag 第 1 级，1 拍）；ddr_dout = 再加 1 级寄存（lag 第 2 级）。
	//   与 top_zynq7010.v 已有的 ram_wr_valid / w_burst_cnt / state 配合：在 main_wvalid&&m_axi_wready
	//   接受第 K 字拍，比对 dbg_lowaddr_r[4:1](=K?) 与 dbg_ddr_dout_r(=word[K] or word[K-1]) 即可判定滞后级数。
	(* mark_debug = "true" *) reg [31:0] dbg_cache_QA_r;
	(* mark_debug = "true" *) reg [31:0] dbg_ddr_dout_r;
	always @(posedge ddr_clk) begin
		dbg_cache_QA_r <= cache_QA;
		dbg_ddr_dout_r <= ddr_dout;
	end
	// ★ 十五次修复探针精简：移除 dbg_ctl_mwmask_v_r / dbg_ctl_fit_wr_r / dbg_ctl_dirty_cond2_r /
	//   dbg_ctl_dirty_wr_r / dbg_ctl_dirty_wr_d1_r —— 它们分别被 dbg_ctl_wmask_r / dbg_ctl_fit_r /
	//   dbg_ctl_dirty_r 完全覆盖，或属十次"blk way 错配"专题的一次性探针（该 bug 已定案修复）。
	//   同时移除 dbg_ctl_free_r（free 自十二次修复起已退出主逻辑，仅作观测，判脏改由 dirty_word[fblk]）。

	// 视频地址判断（仅用于 ILA 探针，不参与主逻辑）
	wire is_video_mem = (maddr[`ADDR-1:12] == 9'h0B8);
	wire is_video_wr  = is_video_mem & (|mwmask);

	// ★★ 十八次修复（2026-09-20）：fit 自 generate-for 改为显式 assign。
	//   本 design 下 generate 块曾两度被 Vivado 综合错（记忆 + 八次修复注释：gen1/gen2 数组
	//   写失效、free mux 嫌疑）。fit[i] 即处在该 generate 块（gen1）内，是同一类隐患。
	//   若 fit 各位被综合成"同一 way 的比较结果"或位序错乱：
	//     - |fit（即 hit）仍成立 → vram_wr_hit_sticky 能置 1（与实测一致）；
	//     - 但 cache_dirty[index] <= cache_dirty[index] | fit（291-292）会把脏位写进"错误 way"，
	//       而 cache_addr（命中行 tag）由 miss 分支的 fblk（三级比较器，非 fit）写入，属正确 way。
	//   后果链：VRAM 行 tag 正确 resident、但脏位落在别的 way → flush 扫到正确 way 时 dirty=0
	//   → 不写回；VRAM 行很快被同索引其它访问逐出（tag 被覆盖 → flush_vram_seen=0），
	//   逐出时正确 way 的 dirty 仍为 0 → ddr_wr 不触发 → 0x034000 在 ddr_wr 下永不出现
	//   （正是用户两条决定性判据）。改显式 assign 后 fit 每位精确对应各自 way，脏位写对位置，
	//   VRAM 行必被每帧 flush 写回 → sdraddr=0x034000@ddr_wr 出现 → VGA 文本更新。
	//   原 lru[i] 线网（{WAYS{fit[i]}} & cache_lru[i][index]）自十五次修复起已无引用，一并删除。
	wire fit0 = ~r_flush && (cache_addr[0][index] == maddr[`ADDR-1:`LINE+`SETS]);
	wire fit1 = ~r_flush && (cache_addr[1][index] == maddr[`ADDR-1:`LINE+`SETS]);
	wire fit2 = ~r_flush && (cache_addr[2][index] == maddr[`ADDR-1:`LINE+`SETS]);
	wire fit3 = ~r_flush && (cache_addr[3][index] == maddr[`ADDR-1:`LINE+`SETS]);
	assign fit = {fit3, fit2, fit1, fit0};

	// ★ Task #8 八次修复（2026-09-19 波形定案）：free 判脏路径移出 generate，改显式赋值。
	//   波形矛盾：flush 脉冲后 2 拍探针仍显示 cache_dirty[0]=0001（way0 脏、tag=000 命中），
	//   但扫描到 0x80(way0/idx0) 时判 clean 直进 STATE 100，ddr_wr 全程为 0。而 2 拍内代码上
	//   不存在任何清 dirty 的路径（LRU 块被 st0&&mmreq 门控，扫描期间 mmreq=0）→ 嫌疑集中到
	//   generate 内 free 的 r_flush 二选一 mux 被综合错（与 gen2 寄存器写失效同类病）。
	//   旁证：cache_dirty 初始化 idx16-31=1111，若活到扫描，0x90-0x97 必触发写回，实测到
	//   0x97 仍无 ddr_wr → boot 期逐出已把这些位清掉（每次伴随一次垃圾写回，即之前
	//   "写事务只在 0x0815FC00 bootstrap 区出现"的来源）→ 逐出+写回机器是通的，坏的只是
	//   flush 扫描判脏这一条组合路径。
	wire [(1<<`WAYS)-1:0]free_lru;
	assign free_lru[0] = ~|cache_lru[0][index];
	assign free_lru[1] = ~|cache_lru[1][index];
	assign free_lru[2] = ~|cache_lru[2][index];
	assign free_lru[3] = ~|cache_lru[3][index];
	wire [(1<<`WAYS)-1:0]scan_free = 4'b0001 << flushcount[`WAYS+`SETS-1:`SETS];
	// ★ 十二次修复起 free 仅作 ILA 探针观测保留，主逻辑（victim 选择/dirty 判定）不再依赖它：
	//   free_lru 在 LRU 退化时会出现多 hot 甚至 4'b0000，旧判脏公式 |(free & cache_dirty)
	//   在 free=0 时恒 0，导致脏 victim 被判 clean、数据被静默覆盖（见下方 fblk/dirty 注释）。
	assign free = r_flush ? scan_free : free_lru;

	wire hit = |fit;
	wire st0 = STATE == 3'b000;

	// ★★ Task #8 十次修复（2026-09-19 20:04 波形定案）：blk 的 way 选择纠正。
	//   原表达式 blk = flushcount[6:5] | fit编码：miss 逐出写回/填充时 fit=0000，
	//   blk = flushcount[6:5] 残留值（flush 结束后恒 00=way0），而 victim 实际是 fblk
	//   （可能 way1/2/3）→ 填充数据写进 way0、tag 记在 fblk；写回把 way0 数据写到
	//   victim 地址 —— 数据/地址 way 错配，即 0x20→0x40→0x60 偏移的真正根源。
	//   原作者代码因 LRU 永不更新（victim 恒 way0）掩盖了此 bug；六次修复 LRU 生效后爆发。
	//   修复：hit（端口 B）用 fit 编码；miss 填充/逐出写回（STATE 011/111）用锁存的 vblk=fblk；
	//         flush 写回用 flushcount[6:5]（r_flush 时）。
	wire [`WAYS-1:0]fit_enc = {|fit[3:2], fit[3] | fit[1]};
	reg  [`WAYS-1:0]vblk = 0;   // miss 锁存的 victim way（填充/逐出写回共用）
	wire [`WAYS-1:0]blk = r_flush ? flushcount[`WAYS+`SETS-1:`SETS] : (st0 ? fit_enc : vblk);
	// ★★ Task #8 十三次修复（2026-09-19）：写回地址/way 冻结寄存器。
	//   根因：STATE 000 顶部 `hiaddr <= dirty ? {cache_addr[fblk][index], index} : maddr[...]`
	//   每个 STATE-000 周期都重算 hiaddr，而 fblk(=vblk_lru) 与 index 在 thrashing 连续 miss
	//   下随 LRU 更新不断变化；hiaddr 经 cache_hi_addr 跨时钟域驱动 sdraddr/awaddr，采样窗口
	//   极易抓到被改写后的瞬态值 —— 表现为 VRAM 脏行(index0,tag=0x2D0)的 dirty 被清掉、
	//   但写回地址被覆盖成别的行(0AFE00/028020)，awaddr=0x08068000 永不出现（"显存行写回地址错"）。
	//   修复：仅在"决定逐出"那一拍把 victim 旧地址与 way 锁进 wb_hiaddr/wb_way，STATE 011 全程
	//   冻结使用，地址 way 与数据 way(vblk/wb_way) 同源，杜绝 fblk/LRU 漂移导致的地址/脏位错配。
	reg [`ADDR-`LINE-1:0]wb_hiaddr;  // 写回地址锁存（STATE 000→011 全程冻结）
	reg [`WAYS-1:0]wb_way;           // 写回 victim way 锁存（地址/数据路径共用）
	// ★★ Task #8 十二次修复（2026-09-19 21:47 波形定案）：victim 选择与 dirty 判定重构。
	//   波形证据：① 触发 dbg_sys_flush_r，扫描全程 hiaddr 只有 0000（低内存）与 3ff0/3ff1
	//   （bootstrap），显存行 0x2E00（tag=0x170）从未出现、dirtywire 恒 0；
	//   ② 单独触发 hiaddr=2E00 窗口内 free_r 出现 4'b0000（无任何 free way）。
	//   根因链：bootstrap 区 4 个 way 的 tag 初值均为 511 → CPU 执行 bootstrap 时 fit 多 hot
	//   （1111）→ hit 分支把 4 个 way 的 LRU 全置 3 → LRU 排列 {0,1,2,3} 被破坏，且
	//   ">ref 才减" 的更新在全 3 态永远减不动 → free_lru=0000 → 旧 dirty=|(free&cache_dirty)
	//   恒 0 → 脏 victim 被判 clean，miss-clear 清 dirty + 直接覆盖填充 → 显存行脏数据
	//   静默丢失、永不写回（awaddr=0x08068000 抓不到的总根因）。低内存/bootstrap 行因
	//   tag 恰等于初值而永远 hit，dirty 存活——这正是它们能被 flush 写回的原因。
	//   修复：① victim 不再依赖 "LRU==0"，改比较器选 LRU 最小 way（LRU 退化仍可轮转，
	//   且 victim→MRU 的相对更新会逐渐自愈排列）；② dirty 判定改为 victim way 自己的
	//   dirty 位——脏必写回，无论 LRU 处于什么状态都杜绝静默丢脏数据。
	wire [1:0]vmin01 = (cache_lru[0][index] <= cache_lru[1][index]) ? 2'd0 : 2'd1;
	wire [1:0]vmin23 = (cache_lru[2][index] <= cache_lru[3][index]) ? 2'd2 : 2'd3;
	wire [1:0]vblk_lru = (cache_lru[vmin01][index] <= cache_lru[vmin23][index]) ? vmin01 : vmin23;
	wire [`WAYS-1:0]fblk = r_flush ? flushcount[`WAYS+`SETS-1:`SETS] : vblk_lru;

	// dirty = victim(fblk) way 自己的 dirty 位（不再经 free 向量 AND）。
	// flush 扫描时 fblk=flushcount[6:5]、index=flushcount[4:0]，即扫描行自己的 dirty，语义不变。
	wire [(1<<`WAYS)-1:0]dirty_word = cache_dirty[index];
	wire dirty = dirty_word[fblk];
	// ★ 十五次修复：csblk 已在 LRU 更新改用 fit_enc + `>=` 递减后成为死代码，删除。
	//   （原 csblk = lru[0]|lru[1]|lru[2]|lru[3] 是多 hot fit 时取命中 way 的 LRU 供 `>` 比较用。）

	always @(posedge ddr_clk) begin
		// ★ Task #8 修复：每个 cache 行事务(cache_line_start 单周期脉冲)起始强置 lowaddr=0，
		//   消除上一行残留的非 0 行内偏移污染下一行（半行/0x20 错位根因：复位 miss 的 DDR
		//   行填充若从错误行内偏移开始写 cache，CPU 会读到垃圾 → 永不到达写显存指令 → isvwr 不触发）。
		if(cache_line_start) lowaddr <= {(`LINE-2){1'b0}};
		else if(cache_write_data || cache_read_data) lowaddr <= lowaddr + 1'b1;
		// ★ 方案 A：写回直接输出整 32-bit 字（取消 lowaddr[0] 半字选择）。
		//   原 `ddr_dout <= lowaddr[0] ? [15:0] : [31:16]` 使写回按 2 拍送高低半字，
		//   而 ddr_dout 相对 lowaddr 有 2 级寄存延迟（BRAM q_a + 本寄存器），
		//   AXI 写 FSM 在 W_ISSUE/W_H 两次采样极易采到同一半字 → DDR 每 16-bit 成对重复。
		//   改整字后 FSM 单拍锁存，无配对、与 W_WAIT_W 停顿无关。
		ddr_dout <= cache_QA;
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
		// ★ 十九次修复（2026-09-20）：flush 期间挂起 CPU 端（端口 B）访问。
		//   根因：flush 写回读走端口 A(ddr_clk)，而 ce<=0 时 CPU 请求锁存在 rmreq；
		//   在 flush 扫描的 st0 周期里 `mmreq && hit && st0` 会让 held 的 VRAM 写经端口 B(clk)
		//   写入——与端口 A 同一 cache 字正处于写回读，异步时钟下读回陈旧/错乱字节 →
		//   该行写回 DDR 的该单元损坏（属性字节变 0x15/0x89 之类）→ VGA 显示旧/错字叠在新字上
		//   = 花屏 + 大量字符重叠（VRAMdump 中 0x08068048=0x1515、0x0806804C=0x8940 即此）。
		//   LRU/dirty 块（271 行）早已用 !r_flush 门控，此处漏了。flush 期间 CPU 本就 ce<=0 挂起，
		//   加 !r_flush 仅取消这一竞争窗口，请求在 flush 结束后正常服务，无功能回退。
		.enable_b(mmreq && hit && st0 && !r_flush), // input enb
		.wren_b(|mwmask),
		.byteena_b(mwmask), // input [3 : 0] web
		.address_b({blk, ~index[`SETS-1:10-`LINE], index[10-`LINE-1:0], maddr[`LINE-1:2]}), // input [10 : 0] addrb
		.data_b(mdin), // input [31 : 0] dinb
		.q_b(dout) // output [31 : 0] doutb
	);

	// ★ Task #8 修复：把 LRU/dirty 更新移出 generate-for，改成普通 always 块。
	//   波形证实：generate-for 生成的 always 块里，cache_lru/cache_dirty 的寄存器写
	//   在硬件上全部失效（条件 st0&mmreq&hit&fit[i]&|mwmask 全成立、lru_wr_r 恒 0），
	//   而普通 always 块（STATE 块写 cache_addr）有效。dirty 改整字写，绕开单 bit 写综合异常。
	integer w;
	always @(posedge clk) begin
		// ★ 二十一次修复（2026-09-20）：写回完成即清脏位——用写回时冻结的 wb_hiaddr/wb_way，
		//   对 flush 写回 与 "读缺失逐出"写回 通用且指向正确的 index/way。
		//   原实现用 flushcount 索引：flushcount 仅在 flush 扫描时推进，读缺失逐出(STATE 011,r_flush=0)
		//   期间保持上一次 flush 残留值 → 清错行的脏位（误清没写回的行、漏清真正写回的行），会造成数据丢失。
		//   现改为 wb_hiaddr[`SETS-1:0]=写回行 index、wb_way=写回 way：STATE 000 决定逐出时锁存，
		//   STATE 011 全程冻结，两类写回均精确命中。与下方 else if(!r_flush) 互斥（同拍不可能既写回又 miss）。
		if(flush_wb_done) begin
			cache_dirty[wb_hiaddr[`SETS-1:0]] <=
				cache_dirty[wb_hiaddr[`SETS-1:0]] & ~(4'b0001 << wb_way);
		// ★ 十次修复：加 ~r_flush 门控——flush 扫描期间（fit 恒 0、hit 恒 0）若残留 CPU 请求
		//   （mmreq=rmreq=1）会误入 miss 分支，用扫描 way 污染 LRU / 误清扫描行 dirty。
		end else if(st0 && mmreq && !r_flush) begin
			if(hit) begin
				// ★★ Task #8 十五次修复（2026-09-19）：LRU 轮转根治 —— 显存行永不写回的总根因。
				//   原实现两个缺陷叠加导致 victim 锁死：
				//     ① `fit[w] ? 3 : ...`：bootstrap 期 4 way 同 tag=511 → fit 多 hot(1111) →
				//        多个 way 被同时置 MRU=3（LRU 并列）；
				//     ② 递减条件用 `>`（仅严格大于才下移）：并列值永不递减，且 victim 若已是
				//        MRU(=3) 时无人可递减 → 并列永久保持。
				//   后果：victim(最小比较器 vblk_lru)永远锁死在同一两个 way，其余 way 永不成为
				//   victim → 落在这些 way 上的显存行(index0,tag=0x170)脏数据永不写回，
				//   dbg_ctl_vram_wr_r 永不触发、awaddr=0x08068000 不出现。
				//   修复：① MRU 只置 fit_enc（单 way；多 hot 时取确定 way，不再多 way 同置 3，
				//        多 hot 各行 tag 相同、数据等价，取哪个都不影响正确性）；
				//        ② 递减条件 `>` 改 `>=`（相等也下移，打破并列），并 clamp（!=0 才减）
				//        防止 2bit 的 0-1 回绕成 3。→ 4 way 严格轮转，显存行必被逐出写回。
				for(w=0; w<(1<<`WAYS); w=w+1) begin
					cache_lru[w][index] <= (w == fit_enc) ? {`WAYS{1'b1}}
						: (cache_lru[w][index] - ((cache_lru[w][index] >= cache_lru[fit_enc][index]) && (cache_lru[w][index] != {`WAYS{1'b0}})));
				end
				// 写命中：整字把命中 way 的 dirty 置 1
				if(|mwmask)
					cache_dirty[index] <= cache_dirty[index] | fit;
			end else begin
				// ★ 十次修复：miss 时 victim(fblk) 将被填充 → 设为 MRU。
				// ★ 十五次修复：同样改 `>=` 递减 + clamp，保证 victim 在 4 way 间轮转。
				for(w=0; w<(1<<`WAYS); w=w+1)
					cache_lru[w][index] <= (w == fblk) ? {`WAYS{1'b1}}
						: (cache_lru[w][index] - ((cache_lru[w][index] >= cache_lru[fblk][index]) && (cache_lru[w][index] != {`WAYS{1'b0}})));
				// ★ 十次修复：只清被替换 way(fblk) 的 dirty。
				//   原 &~free 在 free 多 hot（LRU 退化）时会静默清掉其他脏 way 的 dirty
				//   而不写回 → 显存行 dirty 就是这样丢的（用户波形：isvwr 置 1 后被清 0）。
				cache_dirty[index] <= cache_dirty[index] & ~(4'b0001 << fblk);
			end
		end
	end

		
	always @(posedge clk) begin
		s_lowaddr5 <= lowaddr[`LINE-2];
		s_lowaddr5_d1 <= s_lowaddr5;
		flushreq <= ~flushcount[`WAYS+`SETS] & (flushreq | flush);
		if(ce) begin
			raddr <= addr;
			rdin <= din;
			rwmask <= wmask;
			rmreq <= mreq;
		end
		
		case(STATE)
		3'b000: begin
			// ★ 十三次修复：不再在 STATE 000 顶部每周期重算 hiaddr（会覆盖写回地址）。
			//   改为在各分支显式赋值，并在"决定逐出"拍锁定 wb_hiaddr/wb_way。
			// ★★ Task #8 十七次修复（2026-09-20）：miss 分支补 !r_flush 门控 —— VRAM 行永不 resident 的根因。
			//   实测判据（十六次续粘滞标志）：vram_wr_miss=1 / vram_wr_hit=0 /
			//   flush_vram_seen=0 / flush_vram_dirty=0 ⇒ VRAM 访问**全是 miss**，且 VRAM 行
			//   连"干净的"都从未进过 cache（flush 全扫 128 行一次都没见过 tag 0x170/0x171）。
			//   根因：fit[i] = ~r_flush && (...)，flush 期间 hit 被强制为 0；而 miss 分支无
			//   !r_flush 门控，于是 flush 窗口里任何 CPU 请求（stall 时 mmreq 取锁存的 rmreq）
			//   都会走进 miss 分支 —— 但分支内写 tag 被 `if(!r_flush)` 挡掉、
			//   `ddr_rd <= ~dirty & ~r_flush` 也恒 0 发不出填充 ⇒ **该次访问被静默丢弃**：
			//   行永不 resident，CPU 重试仍 miss，dirty 永远置不上，VRAM 自然永不写回
			//   （这也解释了写回序列里反复出现的 0afe00/028028 都是被逐出的非 VRAM 行）。
			//   十次修复只给 LRU/dirty 块加了 ~r_flush 门控，STATE 的 miss 分支漏了，此处补齐。
			//   修复后：flush 期间 CPU 请求直接让位给 flush 扫描分支；CPU 访问只在 r_flush=0
			//   时被服务，此时 tag 正常安装、填充正常发出 → 重试必命中 → dirty 能置 1 → 可写回。
			if(mmreq && !hit && !r_flush) begin	// cache miss（flush 期间不处理，避免静默丢弃）
				if(!r_flush) begin
					cache_addr[fblk][index] <= maddr[`ADDR-1:`LINE+`SETS];
					vblk <= fblk;   // ★ 十次修复：锁存 victim way，供 STATE 011 写回/111 填充的端口 A 使用
				end
				wb_way <= fblk; // ★ 十三次修复：地址/数据路径共用同一冻结 way（无论是否 r_flush 都=本拍 fblk，与 wb_hiaddr 同源）
				wb_hiaddr <= {cache_addr[fblk][index], index}; // ★ 十三次修复：锁定 victim 旧地址
				hiaddr <= {cache_addr[fblk][index], index};    // 非阻塞，取旧 cache_addr（victim 写回地址）
				ddr_rd <= ~dirty & ~r_flush;
				ddr_wr <= dirty;
				// ★ 整行修复：脏行先写回(011)，再直接进读填充(111)；干净行直接读填充(111)。
				STATE <= dirty ? 3'b011 : 3'b111;
				ce <= 1'b0;
			end else if(r_flush) begin
				// ★ 修复(回退 af6f44b 后丢失)：flush 与 CPU 访问解耦。
				//   清屏等"全命中"写入不产生 cache miss，原 else 分支只置 r_flush 标志后即放开
				//   CPU(ce<=1)，脏行永远写不回 DDR（波形表现：isvwr 期间 awvalid/wvalid=0）。
				//   现改为：只要 r_flush 有效，无论 CPU 是否访问，都扫描当前行并写回脏行。
				flushcount[`WAYS+`SETS] <= flushcount[`WAYS+`SETS] | flushreq;
				if(dirty) begin
					wb_hiaddr <= {cache_addr[fblk][index], index}; // ★ 十三次修复：锁定扫描行地址
					wb_way <= fblk;                                // ★ 十三次修复：扫描 way
					hiaddr <= {cache_addr[fblk][index], index};
					ddr_rd <= 1'b0;
					ddr_wr <= 1'b1;
					STATE <= 3'b011;   // 写回当前脏行
				end else begin
					STATE <= 3'b100;   // 当前行干净，直接推进扫描下一行
				end
				ce <= 1'b0;            // 写回期间挂起 CPU，与正常 evict 一致，避免丢写
		end else begin
			// ★ 十三次修复：空闲/命中分支 hiaddr 携带当前访问 tag（不产生事务，仅作占位）。
			hiaddr <= maddr[`ADDR-1:`LINE];
			// ★ flush 启动时把扫描指针归位 0x80(way0/idx0)：每轮固定全扫 128 行，
			//   捕获窗口可预测，且刚标脏的显存行最早被访问到。
			if(flushreq) flushcount <= {1'b1, {(`WAYS+`SETS){1'b0}}};
			ce <= 1'b1;
		end
		end
		3'b011: begin	// write cache to ddr
			hiaddr <= wb_hiaddr;  // ★ 十三次修复：冻结写回地址，杜绝 thrashing 下被后续重算覆盖
			ddr_rd <= ~r_flush; //1'b1;
			// ★ 整行修复：必须等 lowaddr 从 31 回绕到 0（s_lowaddr5_fall）才退出。
			//   原代码在 s_lowaddr5 高电平（lowaddr=16）就退出，此时 AXI burst 还在传后半行，
			//   状态机若提前进入 111 会更新 hiaddr，导致后半行写错地址（0x20/0x40 偏移）。
			if(s_lowaddr5_fall) begin
				ddr_wr <= 1'b0;
				// ★ 十一次修复：flush 写回后清 dirty 的写已挪入 LRU/dirty 块（flush_wb_done 事件），
				//   避免 cache_dirty 双 always 写端口 → Unsupported RAM template 综合失败。
				// ★ flush 写完脏行后直接推进扫描(STATE 100)，不再进入 111 回填：
				//   否则会把刚写回 DDR 的行又用 DDR 旧数据覆盖掉，且与晚到的 CPU 写入存在回写竞态。
				STATE <= r_flush ? 3'b100 : 3'b111;
			end
		end
		3'b111: begin // read cache from ddr
			if(~r_flush) hiaddr <= maddr[`ADDR-1:`LINE]; // flush 期间不改 hiaddr（写回地址已在 STATE 000 锁定）
			// ★ 整行修复：同样等整行读填充完成（lowaddr 回绕）再返回 IDLE。
			if(s_lowaddr5_fall) begin
				ddr_rd <= 1'b0;
				STATE <= 3'b000;
			end
		end
		3'b100: begin	// flush 扫描推进
			flushcount <= flushcount + 1'b1;
			STATE <= 3'b000;
		end
		3'b101: begin
			// 保留但不再使用，防止综合器对未用状态优化产生意外行为
			STATE <= 3'b000;
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
		dbg_ctl_blk_r       <= blk;
		dbg_ctl_lru_wr_r    <= cache_lru[blk][index];
		dbg_ctl_s_lowaddr5_fall_r <= s_lowaddr5_fall;
		// ---- Task #8 八次诊断探针采样 ----
		dbg_ctl_flushreq_r  <= flushreq;
		dbg_ctl_dirtywire_r <= dirty;
		// ★ 十六次：放宽到全部 VRAM 行（tag 0x170 = n0-31，tag 0x171 = n32-62，hiaddr 0x2E00-0x2E3F），
		//   原 ==0x2E00 只匹配 index0 一条行，会漏判其余 62 行。
		dbg_ctl_vram_wr_r   <= (STATE == 3'b011) && ddr_wr &&
		                       (wb_hiaddr[14:5] == 10'h170 || wb_hiaddr[14:5] == 10'h171);
		// 粘滞标志：置 1 后保持，供上板后直接读取（不受触发窗口限制）
		if(mmreq && is_video_wr) dbg_ctl_isvwr_sticky_r <= 1'b1;
		if((STATE == 3'b011) && ddr_wr &&
		   (wb_hiaddr[14:5] == 10'h170 || wb_hiaddr[14:5] == 10'h171))
			dbg_ctl_vram_wr_sticky_r <= 1'b1;
		// ★ 十六次续：三种真因判别（VRAM tag = 0x170 / 0x171）
		if(mmreq && is_video_wr && hit)  dbg_vram_wr_hit_sticky  <= 1'b1;
		if(mmreq && is_video_wr && !hit) dbg_vram_wr_miss_sticky <= 1'b1;
		if(st0 && r_flush && (cache_addr[fblk][index] == 10'h170 || cache_addr[fblk][index] == 10'h171)) begin
			dbg_flush_vram_seen_sticky <= 1'b1;
			if(dirty) dbg_flush_vram_dirty_sticky <= 1'b1;
		end
		// ★ 十七次：flush 期间仍有 CPU 请求在等待 → 修复前会走 miss 分支被静默丢弃
		if(st0 && mmreq && r_flush) dbg_miss_in_flush_sticky <= 1'b1;
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
