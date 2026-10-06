//////////////////////////////////////////////////////////////////////////////////
// Next186 cache_controller.v
// 基于原作者版本（neptuno-fpga/Next186_SoC，Nicolae Dumitrache）+ 本项目的 4-way begin
// 冗余（cache_addr 四个 way 的 index16-31 保持 tag=511，保证复位取指命中预填 BIOS）。

// 保留改动：
//   1) seg_map map[11] = 6  —— 文本 VRAM 窗 0x08068000，与 VGA(scraddr=0x6000)/PS 1:1 对齐
//   2) 保留 ILA 探针（mark_debug：lowaddr / s_lowaddr5 / dbg_ctl_* / isvwr），原版无这些探针

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
	reg [`LINE-2:0]lowaddr = 0; //cache mem address
	reg s_lowaddr5 = 0;
	reg        s111_d = 1'b0;
	reg s_lowaddr5_d1 = 0;
	wire s_lowaddr5_fall = s_lowaddr5_d1 & ~s_lowaddr5; // lowaddr 从 31 回绕到 0，标志整行 64B burst 完成
	// ★ 三十三次修复引入的写回内自持计数（声明提前，供 flush_wb_done 使用）
	reg  [5:0] wb_pcnt    = 6'd0;   // 本次写回内 cache_read_data 脉冲数（每字 2 拍）
	reg        ddr_wr_d   = 1'b0;   // ddr_wr 延迟一拍，用于取上升沿
	reg        wb_started = 1'b0;   // 本行写回已收到第一个读脉冲（之后禁止再复位计数）
	// ★ 三十五次修复：本次写回的数据相是否**真的跑完**（脉冲 ≥31 ≈ 16 字×2 拍）。
	//   只有它为 1 才允许清脏位 —— 否则写回没读出行数据也会清脏 ⇒ 脏数据静默丢弃。
	reg        wb_full    = 1'b0;
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
	// ★ 三十五次修复（2026-09-23）：清脏位必须**确认整行数据相真的跑完**（wb_full）。
	//   实测（dbg_wr0_seen=0）：VRAM row0 的写回被"启动"（STATE011 & ddr_wr=1 & hiaddr=0x2E00，
	//   ddr_186 侧 memmap 也已锁存=6），但该窗口内 cache_read_data 脉冲数为 **0**；
	//   而 state 机仍在 s_lowaddr5_fall 上退出、旧逻辑照样清了脏位 ⇒ 脏数据被静默丢弃、
	//   该行永远到不了 DDR（= index0 内容一直是旧 bitstream 化石的直接原因）。
	//   现要求 wb_full（本次写回读脉冲 ≥31）为必要条件：没真读出行数据就不清脏位，
	//   数据留待下一次写回。最坏后果只是"多写回一次"，绝不丢数据。
	wire flush_wb_done_old = (STATE == 3'b011) && ddr_wr && s_lowaddr5_fall; // 旧判据（仅探针观测用）
	wire flush_wb_done     = flush_wb_done_old && wb_full;
	wire [31:0]cache_QA;

	// ILA 探针寄存器（保留，原版无；不参加主逻辑）
	reg        dbg_ctl_mreq_r;
	reg [3:0]  dbg_ctl_wmask_r;
	reg        dbg_ctl_mmreq_r;
	reg        dbg_ctl_hit_r;
	reg        dbg_ctl_ce_r;
	reg        dbg_ctl_isvwr_r;
	reg        dbg_ctl_rflush_r;
	reg        dbg_ctl_ddr_wr_r;
	reg [2:0]  dbg_ctl_STATE_r;
	reg [`WAYS+`SETS:0] dbg_ctl_flushcount_r;
	reg [3:0]  dbg_ctl_dirty_r;      // cache_dirty[index] 当前 index 的 4 way
	reg [3:0]  dbg_ctl_fit_r;        // 当前访问的 way 命中向量
	reg [4:0]  dbg_ctl_index_r;       // 当前 cache index
	reg [9:0]  dbg_ctl_tag_r;         // 当前 cache tag = maddr[20:11]
	reg        dbg_ctl_s_lowaddr5_fall_r; // 整行 burst 完成标志（下降沿判活）
	// ---- Task #8 八次诊断探针：flush 扫描判脏链路（2026-09-19）----
	reg        dbg_ctl_flushreq_r;   // flush 脉冲锁存
	reg        dbg_ctl_dirtywire_r;  // dirty 组合线本体（flush 分支实际判据）
	// ★ 十四次诊断探针：VRAM 行写回事件捕获。
	//   VRAM 行 = index0 / tag=0x170 / hiaddr=0x2E00 / 物理 0x08068000 / sdraddr=0x034000。
	//   用户 message 3 看到的 sdraddr=034000-0344a8 串极可能是 VGA 持续读文本帧缓冲（ddr_rd），
	//   与 VRAM 写回（ddr_wr，同地址）难以用裸 sdraddr 区分。此探针在"STATE=011 且 ddr_wr=1 且
	//   写回地址=0x2E00(VRAM)"时置 1，可一锤定音：能触发=VRAM 写回确实发生（之前为 VGA 读误判），
	//   永不触发=VRAM 行从未成为 victim，需回头查 victim 选择 / LRU 退化。
	reg        dbg_ctl_vram_wr_r;
	// ★ 十六次诊断探针（纯观测，不参与任何主逻辑）：把"CPU 到底有没有写 VRAM"和
	//   "VRAM 到底有没有写回 DDR"做成**粘滞标志**（置 1 后一直保持），这样上板跑一段时间后
	//   直接读这两个 bit 即可，无需触发、不受 1028 采样窗口远短于一帧(16.7ms)的限制。
	//   判读：isvwr_sticky=0 → CPU 从未写 VRAM（问题不在 cache，在 CPU/BIOS 流程）；
	//         isvwr_sticky=1 且 vram_wr_sticky=0 → VRAM 脏了却从不写回（真 cache bug）；
	//         两者都=1 → VRAM 写回已发生，转查 VGA 读地址。
	reg        dbg_ctl_isvwr_sticky_r = 1'b0;   // CPU 曾写 VRAM（粘滞，显式上电清零防误判）
	reg        dbg_ctl_vram_wr_sticky_r = 1'b0; // VRAM 行曾写回 DDR（粘滞，显式上电清零防误判）
	// ★ 十六次续：判别"isvwr=1 但 vram_wr=0"的三种真因（纯观测粘滞标志）
	//   A: VRAM 写全是 miss（永不 hit）→ 填充不置 dirty，VRAM 永不脏
	//   B: VRAM 曾 hit（dirty 已置 1），但 flush 扫描时 VRAM 行已不在 cache / 已不脏
	//   C: flush 扫到 VRAM 行且判为脏，却没产生带 VRAM tag 的写回 → 写回地址/way 错配
	reg        dbg_vram_wr_hit_sticky = 1'b0;      // VRAM 写命中（命中即 dirty 被置 1）
	reg        dbg_vram_wr_miss_sticky = 1'b0;     // VRAM 写缺失（走填充，dirty 不置 1）
	reg        dbg_flush_vram_seen_sticky = 1'b0;  // flush 扫描时遇到过 VRAM 行（tag 0x170/0x171，不论脏否）
	reg        dbg_flush_vram_dirty_sticky = 1'b0; // flush 扫描时遇到过 VRAM 行且判为脏
	// ★ 十七次：确认"flush 窗口里是否真有待处理 CPU 请求"（修复前会被静默丢弃的那个前提）
	reg        dbg_miss_in_flush_sticky = 1'b0;

	// ---- Task #8 诊断探针（保留：way 选择与 LRU 轮转观测）----
	reg [1:0]  dbg_ctl_blk_r;       // 实际写入选中 way（cache_mem port B 用 blk）
	reg [1:0]  dbg_ctl_lru_wr_r;    // cache_lru[blk][index]：命中 way 的 LRU 当前值（十五次 LRU 轮转修复的验证依据）
	// ★ 二十三次探针（拍错方案 A，2026-09-21）：观测写回数据相对读地址 lowaddr 的滞后相位。
	//   cache_QA = BRAM q_a 输出（lag 第 1 级，1 拍）；ddr_dout = 再加 1 级寄存（lag 第 2 级）。
	//   ★ 2026-09-21 精简：这两个 32-bit 常开镜像（64 bit）已从 ILA 移除（mark_debug 摘除），
	//     其功能由文件末尾的 v8 一组粘滞探针（index0 tag/dirty、VRAM 写回 index、flush 扫描）承担，以缓解 probe 预算。
	reg [31:0] dbg_cache_QA_r;
	reg [31:0] dbg_ddr_dout_r;
	always @(posedge ddr_clk) begin
		dbg_cache_QA_r <= cache_QA;
		dbg_ddr_dout_r <= ddr_dout;
	end

	// ★ 二十四次诊断（v6/v7 已完成使命：确认 index0 从不被写回）——相关探针已移除，见文件末尾 v8 组。
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
	// ★★ 四十五次修复（2026-09-24）：保护"BIOS 活动栈行"不被逐出。
	//   证据链（四十四次读数 + 反汇编 0x10F）：
	//     · BIOS 的 1KB 映像只活在 cache（BlackBox 预置）；其活动栈紧贴映像下方
	//       （SS:SP = 0xF000:0xFC00 ⇒ maddr 0xFFBFE，tag 0x1FF / index 15）。
	//     · BIOS 主流程在进 SD 例程前调用 `scan256`（映像 0x10F）：`mov bx,0x4000` +
	//       循环 `sub bx,0x40` ⇒ 读 256 个不同 64B 行 = 整块 cache（4 way×32 index=128 行）
	//       的两倍 ⇒ **必然把栈行逐出**，其数据此后只能靠"写回 DDR → 再回填"往返。
	//     · 实测：`dbg_pbfe_dat=0xFC31`（返回地址确实上了总线）而 `dbg_rbad_hit=1`（读回不是它、
	//       且命中）；`dbg_wild_ip = dbg_wild_bx = 0x00C8`（`pop bx` 与 `ret` 读到**同一个**陈旧值
	//       ⇒ 两次栈读都没拿到真实数据）；DDR 栈区 dump 全是上电噪声（无 0xFCxx）
	//       ⇒ **栈行的"写回→回填"往返丢了数据** ⇒ `ret` 弹出垃圾 ⇒ CPU 跑飞、屏幕冻在第一串。
	//   修法：victim 选择**优先挑"非 BIOS 栈行"的 way**；仅当某 index 的 4 个 way 全是保护行时
	//     才退回 LRU（tag 0x1FF + 同一 index 只对应唯一 64B 行，最多占 1 个 way ⇒ 永不触发）。
	//   效果：栈行常驻 cache，`scan256` 的 thrash 再也冲不掉它；栈数据每帧仍由 flush 写回 DDR。
	wire [3:0] stk_pin;   // 各 way 是否 = 受保护的 BIOS 栈行（tag 0x1FF 且 index<16）
	assign stk_pin[0] = (cache_addr[0][index] == 10'h1FF) && ~index[`SETS-1];
	assign stk_pin[1] = (cache_addr[1][index] == 10'h1FF) && ~index[`SETS-1];
	assign stk_pin[2] = (cache_addr[2][index] == 10'h1FF) && ~index[`SETS-1];
	assign stk_pin[3] = (cache_addr[3][index] == 10'h1FF) && ~index[`SETS-1];
	wire [3:0] vcand = ((&stk_pin) == 1'b1) ? 4'b1111 : ~stk_pin; // 候选 way（1=可选作 victim）
	// 用 3-bit 键把"非候选"排到最大（7），候选键 = 3'b0xx，保证非候选永不被选中。
	wire [2:0] vk0 = vcand[0] ? {1'b0, cache_lru[0][index]} : 3'b111;
	wire [2:0] vk1 = vcand[1] ? {1'b0, cache_lru[1][index]} : 3'b111;
	wire [2:0] vk2 = vcand[2] ? {1'b0, cache_lru[2][index]} : 3'b111;
	wire [2:0] vk3 = vcand[3] ? {1'b0, cache_lru[3][index]} : 3'b111;
	wire [1:0]vmin01 = (vk0 <= vk1) ? 2'd0 : 2'd1;
	wire [1:0]vmin23 = (vk2 <= vk3) ? 2'd2 : 2'd3;
	wire [2:0]vkmin01 = (vmin01 == 2'd0) ? vk0 : vk1;
	wire [2:0]vkmin23 = (vmin23 == 2'd2) ? vk2 : vk3;
	wire [1:0]vblk_lru = (vkmin01 <= vkmin23) ? vmin01 : vmin23;
	wire [`WAYS-1:0]fblk = r_flush ? flushcount[`WAYS+`SETS-1:`SETS] : vblk_lru;
	// 探针："栈行被逐出"的次数（修复后应恒 0；非 0 说明退回了 LRU 兜底）。
	reg [3:0] dbg_stk_evict_n = 4'd0;
	always @(posedge clk) begin
		if(st0 && mmreq && !hit && !r_flush && stk_pin[fblk] && (dbg_stk_evict_n != 4'hF))
			dbg_stk_evict_n <= dbg_stk_evict_n + 1'b1;
	end

	// dirty = victim(fblk) way 自己的 dirty 位（不再经 free 向量 AND）。
	// flush 扫描时 fblk=flushcount[6:5]、index=flushcount[4:0]，即扫描行自己的 dirty，语义不变。
	wire [(1<<`WAYS)-1:0]dirty_word = cache_dirty[index];
	wire dirty = dirty_word[fblk];
	// ★ 十五次修复：csblk 已在 LRU 更新改用 fit_enc + `>=` 递减后成为死代码，删除。
	//   （原 csblk = lru[0]|lru[1]|lru[2]|lru[3] 是多 hot fit 时取命中 way 的 LRU 供 `>` 比较用。）

	// ★★ 三十六次修复（2026-09-23）：lowaddr 的**复位与推进都必须只属于"当前事务"**。
	//   实测（三十五次探针，VRAM row0）：写回被启动（st011=1、ddr_wr=1、hiaddr=0x2E00），但
	//     ① 该窗口内 cache_read_data 脉冲 = 0（np=0 ⇒ top 的写 burst 根本没跑）；
	//     ② cache_line_start = 0（写回命令从未被 ack）；
	//     ③ 却出现了 s_lowaddr5_fall = 1 ⇒ 状态机凭"假 fall"提前退出；而旧逻辑照样清了脏位 ⇒ 数据丢。
	//   假 fall 的来路：lowaddr 原先被 `cache_write_data || cache_read_data` **无条件**推进，而
	//   cache_write_data = crw && sys_rd_data_valid —— **上一笔事务读 burst 的余波**（cmd 11 已 ack、
	//   crw 仍为 1）同样能推进它，于是新事务刚开始就被推进/回绕 ⇒ 交出假 fall。
	//   修法：① 复位只在**事务起点**（STATE 进入 011/111 的那一拍；IDLE 时收到 cache_line_start 作兜底）；
	//         ② 推进只认**本事务的数据相**（011→cache_read_data，111→cache_write_data）。
	//   效果：写回会老老实实等到自己的命令被 ack、burst 跑完（32 脉冲回绕）才退出 ⇒
	//   "被余波打断 / 被命令饿死"的写回不再被丢弃（row0 化石的直接堵漏）。
	reg [2:0] st_d = 3'b000;
	wire txn_start = (STATE != st_d) && (STATE == 3'b011 || STATE == 3'b111);
	wire lowadv    = (STATE == 3'b011) ? cache_read_data :
	                 (STATE == 3'b111) ? cache_write_data : 1'b0;
	always @(posedge ddr_clk) begin
		st_d <= STATE;
		if(txn_start || (cache_line_start && (STATE == 3'b000)))
			lowaddr <= {(`LINE-2){1'b0}};
		else if(lowadv)
			lowaddr <= lowaddr + 1'b1;
	end

	// ★ 三十七次撤销超时兜底：111 相超时会作废刚装入的 tag ⇒ 填充命令若被 VGA 读饿死 >5ms，
	//   CPU 就会反复 miss/重填（live-lock），用户实测表现为"屏幕乱码"。且 lowaddr 归位后 fall 已是
	//   确定性的（fill 相内必然走满 32 拍才回绕），超时兜底不再需要。详见第 35 节。

	// ★★ 三十三次修复（2026-09-23）：写回读地址改用"本次写回内独立的字序号计数"，
	//   与共享的 lowaddr 彻底解耦 —— 修 index0 整行 +1 word（dump: cell0-1=0，cell2 起才
	//   出现字符串 'S','e'…；而同一次运行的 index1 完全对齐）。
	
	//   机理：写回时 BRAM 端口 A 的读地址此前取 `lowaddr[LINE-2:1]`。`lowaddr` 是**填充与
	//   写回共用**的计数器，只由外部单周期脉冲 `cache_line_start` 复位。只要该脉冲与本次
	//   写回的相位不齐（或上一行残留未清），整行读出的字序号就整体偏移 1 个字 ——
	//   而"整行偏移"正是所有 dump 里 index0 的形状；index1 恰好相位对齐故正常。
	//   （此前测到的 dbg_i0wb_crd=0 / cache_QA 值不像本行内容，也是同一相位问题的副作用：
	//     STATE 011 的可见窗口只有几个 clk_sdr 周期，探针按 ddr_dr 采样极易漏掉。）
	
	//   修法：写回 burst 内自建计数器 wb_pcnt，只在**本次写回**内累加：
	//     - 复位：`cache_line_start` 脉冲 或 `ddr_wr` 上升沿（写回开始事件，先于 burst 若干拍）；
	//     - 递增：每个 `cache_read_data` 脉冲（= top 的 W_L/W_H，每字恰好 2 拍，与 AXI
	//       wready 停顿无关 → 结构性保证，不依赖任何节拍假设）；
	//     - 字序号 = wb_pcnt[5:1]（每 2 拍一个字）。
	//   于是 beat n（W_L 拍）present 的地址恒为 word n，W_H 拍 q_a 即 word n，
	//   与 top_zynq7010.v:360 的设计意图严格一致。
	wire [3:0] wb_word    = wb_pcnt[5:1];
	always @(posedge ddr_clk) begin
		ddr_wr_d <= ddr_wr;
		if(!ddr_wr) begin
			wb_pcnt <= 6'd0; wb_started <= 1'b0; wb_full <= 1'b0;  // 写回结束 → 归零
		end else begin
			// 仅在"本行写回的第一个脉冲之前"允许复位，确保 beat0 恒为 word0；
			// 首个脉冲出现后即锁定（wb_started），避免迟到的 cache_line_start 把序号打回 0。
			if(!wb_started && (cache_line_start || (ddr_wr & ~ddr_wr_d)))
				wb_pcnt <= 6'd0;
			else if(cache_read_data)
				wb_pcnt <= wb_pcnt + 1'b1;
			if(cache_read_data) wb_started <= 1'b1;
			if(cache_read_data && (wb_pcnt >= 6'd30)) wb_full <= 1'b1;  // 第 31 个脉冲起认定数据相已跑完
		end
	end
	// 写回读窗口（cache_read_data=1）用内部字序号；填充写入窗口用 lowaddr（原行为不变）。
	//   两者天然互斥：写回时 cache_write_data=0、填充时 cache_read_data=0。
	wire [`LINE-3:0] word_a = cache_read_data ? wb_word : lowaddr[`LINE-2:1];

	// ★★ 三十次修复（2026-09-22）：写回数据改"组合直通 cache_QA"，去掉多出来的一级寄存器。
	//   实测（v5 探针，index1 行）：word0 的 W_H 拍 cache_QA 已是**正确 word0** 0x0142014B，
	//   而同拍 ddr_dout 仍是上一拍的旧值（v4 实测 0x04000016）→ top 在 W_H 拍
	//   `main_wdata <= ram_wdata(=ddr_dout)` 锁到的是**旧值** ⇒ 整行写回后移 1 word、首字为
	//   上一行残留。这正是"方案 A 改整字却仍移位"的真因：移位来自这级寄存器，不是半字配对。
	//   cache_QA = BRAM 输出（本身已寄存 1 拍），W_H 拍其值 = 该字正确内容；组合直通后
	//   W_H 拍 ram_wdata = cache_QA = word n，与 top_zynq7010.v:360 的设计意图一致。
	always @(*) ddr_dout = cache_QA;
	// ====================================================================
	// ★★ 四十一次修复（2026-09-24）：给 BIOS 代码区加**回填源 ROM**。
	//   依据（第 37 节挖 cache 的结论，全部验算过）：
	//     · BIOS 代码只存在于 cache（BlackBox 预置 way0 的 index16-31，再复制到 way1/2/3 = 4 份冗余）；
	//       DDR 侧 0x0815_FC00 只能靠"逐出写回"（way0 预置脏位）被动播种。
	//     · 而 BIOS 的 `call 0x10F`（映像 0x10F → IP=0xFD0F）会扫 maddr 0x2000-0x4000
	//       = tag 4~7 × index 0~31；对 index 16-31 恰好是 4 个不同 tag ⇒ **把 BIOS 的 4 份副本全部逐出**。
	//       ⇒ 此后每次取指都靠 DDR 回填：一旦播种没做成/写回被丢，取指读到 0 ⇒ 跑飞。
	//   修法：填充相里，若**目标行属于 BIOS 区**（tag 0x1FF 且 index[4]=1），数据取本 ROM，不再依赖 DDR。
	//   数据通路与原来逐字一致：仍是"每拍写一个 16-bit 半字"（byteena_a 由 lowaddr[0] 选半字），
	//   所以只把 `ddr_din` 换成 ROM 的对应半字，地址/时序/word_a 全不动 ⇒ 对其它区域零影响。
	//   ROM 地址 = { index[3:0], word_a } = { maddr[9:6], lowaddr[4:1] }（= 映像第 N 个 32-bit 字，与 BlackBox 同序）。
	// ====================================================================
	// ====================================================================
	// ★★ 六十三次修复（2026-09-25）：**bios_rom 必须与 BlackBox 预置逐字一致**。
	//   起因（第 63 节）：本 ROM 是"回填源"，BlackBox（Next186_BlackBoxes.v 的
	//   cache 模块 ram[0..0xFF]）是"上电预置源"。两者是同一个 1KB BIOS 的两份拷贝。
	//   五十次修复 `62f2b9d`（把 SPI 降到 <=400kHz）**只改了 BlackBox**，本 ROM 漏改
	//   ⇒ 两表有 17 个字不一致（0x74/75/76/78/7A/7B/8C/8D/8E/91/9D/AF/D8-DC）。
	//   而 BIOS 主流程在 SD 例程**之前**就 `call 0x10F`(scan256)，其作用正是横扫
	//   tag 4~7 × index 0~31 ⇒ **把 BIOS 的 4 份副本全部逐出** ⇒ 之后取指全部从
	//   **本 ROM** 回填 ⇒ **真正执行的是"没降速"的那份 BIOS**，`spi_byte` 退回
	//   每条位只占 3~4 个 CPU_CE 的原始版本 ⇒ **0x23D 期间 SPI 跑在几 MHz，
	//   远超规范允许的 400kHz** ⇒ 卡只能零星解码（CMD0/CMD8 过），ACMD41 永远
	//   等不到 R1=0 ⇒ 死在 `0x26F` 的**无上限轮询循环**里（底行永远没有扇区号）。
	//   ⇒ 教训：`scan256` 之后的每一个字节都来自本 ROM，**改 BIOS 必须两处同改**。
	//   本次把本 ROM 的 17 个字同步为 BlackBox 的值（= 带降速补丁的版本）。
	// ====================================================================
	reg [31:0] bios_rom [0:255];
	initial begin
		bios_rom[8'h00] = 32'hC88CFCFA;
		bios_rom[8'h01] = 32'hC08ED88E;
		bios_rom[8'h02] = 32'h00BCD08E;
		bios_rom[8'h03] = 32'hE7C033FC;
		bios_rom[8'h04] = 32'hE706B080;
		bios_rom[8'h05] = 32'hE70FB08B;
		bios_rom[8'h06] = 32'hE634B08F;
		bios_rom[8'h07] = 32'hE6C03243;
		bios_rom[8'h08] = 32'hE840E640;
		bios_rom[8'h09] = 32'hFF3300A9;
		bios_rom[8'h0A] = 32'hE8FEC3BE;
		bios_rom[8'h0B] = 32'h6EE800F8;
		bios_rom[8'h0C] = 32'h0209E803;
		bios_rom[8'h0D] = 32'h0375C085;
		bios_rom[8'h0E] = 32'h8B0117E9;
		bios_rom[8'h0F] = 32'h06EAC1D0;
		bios_rom[8'h10] = 32'hB90AE0C1;
		bios_rom[8'h11] = 32'hC12B0010;
		bios_rom[8'h12] = 32'h3300DA83;
		bios_rom[8'h13] = 32'h001AE8DB;
		bios_rom[8'h14] = 32'h28E90372;
		bios_rom[8'h15] = 32'h33D23301;
		bios_rom[8'h16] = 32'h000EE8C0;
		bios_rom[8'h17] = 32'h1CE90372;
		bios_rom[8'h18] = 32'hF8834001;
		bios_rom[8'h19] = 32'hE9F27640;
		bios_rom[8'h1A] = 32'h525000E8;
		bios_rom[8'h1B] = 32'h90605351;
		bios_rom[8'h1C] = 32'hE8929090;
		bios_rom[8'h1D] = 32'h9092030C;
		bios_rom[8'h1E] = 32'h92E89090;
		bios_rom[8'h1F] = 32'h75E86100;
		bios_rom[8'h20] = 32'h81467201;
		bios_rom[8'h21] = 32'h75654E3F;
		bios_rom[8'h22] = 32'h027F8140;
		bios_rom[8'h23] = 32'h39757478;
		bios_rom[8'h24] = 32'h01C08349;
		bios_rom[8'h25] = 32'h8100D283;
		bios_rom[8'h26] = 32'hE80200C3;
		bios_rom[8'h27] = 32'h29720158;
		bios_rom[8'h28] = 32'hC381EFE2;
		bios_rom[8'h29] = 32'hF6330200;
		bios_rom[8'h2A] = 32'hE81FEEB9;
		bios_rom[8'h2B] = 32'h9090009A;
		bios_rom[8'h2C] = 32'hE8C28B90;
		bios_rom[8'h2D] = 32'h56E8032C;
		bios_rom[8'h2E] = 32'hEE478B00;
		bios_rom[8'h2F] = 32'h7400F883;
		bios_rom[8'h30] = 32'h75C23B04;
		bios_rom[8'h31] = 32'hEB59F804;
		bios_rom[8'h32] = 32'h59F95B02;
		bios_rom[8'h33] = 32'h06C3585A;
		bios_rom[8'h34] = 32'hB003C0BA;
		bios_rom[8'h35] = 32'h08B0EE10;
		bios_rom[8'h36] = 32'h03D4BAEE;
		bios_rom[8'h37] = 32'h42EE0AB0;
		bios_rom[8'h38] = 32'h4AEE20B0;
		bios_rom[8'h39] = 32'h42EE0CB0;
		bios_rom[8'h3A] = 32'h4AEE60B0;
		bios_rom[8'h3B] = 32'h42EE0DB0;
		bios_rom[8'h3C] = 32'h68EE00B0;
		bios_rom[8'h3D] = 32'h3307B800;
		bios_rom[8'h3E] = 32'h07D0B9FF;
		bios_rom[8'h3F] = 32'hABF3C033;
		bios_rom[8'h40] = 32'hB803C8BA;
		bios_rom[8'h41] = 32'h42EE0101;
		bios_rom[8'h42] = 32'hEEEE2AB0;
		bios_rom[8'h43] = 32'h53C307EE;
		bios_rom[8'h44] = 32'h3A4000BB;
		bios_rom[8'h45] = 32'h40EB831F;
		bios_rom[8'h46] = 32'hC35BF975;
		bios_rom[8'h47] = 32'hB8006806;
		bios_rom[8'h48] = 32'hAB01B407;
		bios_rom[8'h49] = 32'hE8ACC307;
		bios_rom[8'h4A] = 32'h84ACFFF2;
		bios_rom[8'h4B] = 32'hC3F875C0;
		bios_rom[8'h4C] = 32'hC10004B9;
		bios_rom[8'h4D] = 32'h245004C0;
		bios_rom[8'h4E] = 32'h720A3C0F;
		bios_rom[8'h4F] = 32'h04070402;
		bios_rom[8'h50] = 32'hFFD8E830;
		bios_rom[8'h51] = 32'hC3ECE258;
		bios_rom[8'h52] = 32'hC033D233;
		bios_rom[8'h53] = 32'hE2D003AC;
		bios_rom[8'h54] = 32'hA0BFC3FB;
		bios_rom[8'h55] = 32'hFEFDBE00;
		bios_rom[8'h56] = 32'hE8FFCBE8;
		bios_rom[8'h57] = 32'h00BEFFB1;
		bios_rom[8'h58] = 32'h0034E801;
		bios_rom[8'h59] = 32'h2FE8FC8A;
		bios_rom[8'h5A] = 32'hE8DC8A00;
		bios_rom[8'h5B] = 32'h2488002A;
		bios_rom[8'h5C] = 32'hF7754B46;
		bios_rom[8'h5D] = 32'hD48EE433;
		bios_rom[8'h5E] = 32'h000100EA;
		bios_rom[8'h5F] = 32'hFD91BEF0;
		bios_rom[8'h60] = 32'h07B9FB8B;
		bios_rom[8'h61] = 32'hBFA4F300;
		bios_rom[8'h62] = 32'hF633E000;
		bios_rom[8'h63] = 32'hFF1000B9;
		bios_rom[8'h64] = 32'hEAA5F3E3;
		bios_rom[8'h65] = 32'hFFFF0000;
		bios_rom[8'h66] = 32'hDABA80B4;
		bios_rom[8'h67] = 32'hFA52B903;
		bios_rom[8'h68] = 32'h02E8C0EC;
		bios_rom[8'h69] = 32'h40E4FAEB;
		bios_rom[8'h6A] = 32'h40E4E802;
		bios_rom[8'h6B] = 32'hEC0008E8;
		bios_rom[8'h6C] = 32'hD002E8C0;
		bios_rom[8'h6D] = 32'h81F573DC;
		bios_rom[8'h6E] = 32'hE40A5BE9;
		bios_rom[8'h6F] = 32'hE4E83840;
		bios_rom[8'h70] = 32'hC3F87540;
		bios_rom[8'h71] = 32'h01B4FFB0;
		bios_rom[8'h72] = 32'h73C003EE;
		bios_rom[8'h73] = 32'hACC3EDFB;
		bios_rom[8'h74] = 32'hE2018FE8;
		bios_rom[8'h75] = 32'h87E8C3FA;
		bios_rom[8'h76] = 32'h47258801;
		bios_rom[8'h77] = 32'hE8C3F8E2;
		bios_rom[8'h78] = 32'h06B9017E;
		bios_rom[8'h79] = 32'hFFE7E800;
		bios_rom[8'h7A] = 32'h73E8F633;
		bios_rom[8'h7B] = 32'h05744601;
		bios_rom[8'h7C] = 32'h74FFFC80;
		bios_rom[8'h7D] = 32'h5250C3F5;
		bios_rom[8'h7E] = 32'h0007E851;
		bios_rom[8'h7F] = 32'h5901E983;
		bios_rom[8'h80] = 32'h50C3585A;
		bios_rom[8'h81] = 32'hB250C28A;
		bios_rom[8'h82] = 32'hF48B5251;
		bios_rom[8'h83] = 32'hB403DABA;
		bios_rom[8'h84] = 32'h44C6EF01;
		bios_rom[8'h85] = 32'h5BE8FF05;
		bios_rom[8'h86] = 32'h06C48301;
		bios_rom[8'h87] = 32'h1675E40A;
		bios_rom[8'h88] = 32'h80016EE8;
		bios_rom[8'h89] = 32'h0E75FEFC;
		bios_rom[8'h8A] = 32'hFB8B02B5;
		bios_rom[8'h8B] = 32'hE8018DE8;
		bios_rom[8'h8C] = 32'h2BE8012E;
		bios_rom[8'h8D] = 32'hC0334101;
		bios_rom[8'h8E] = 32'h0124E8EF;
		bios_rom[8'h8F] = 32'h03DABAC3;
		bios_rom[8'h90] = 32'hE8000AB9;
		bios_rom[8'h91] = 32'hFBE2011A;
		bios_rom[8'h92] = 32'hBEEF01B4;
		bios_rom[8'h93] = 32'h91E8FF38;
		bios_rom[8'h94] = 32'h75CCFEFF;
		bios_rom[8'h95] = 32'hFF3EBE65;
		bios_rom[8'h96] = 32'hFEFF84E8;
		bios_rom[8'h97] = 32'hB15B75CC;
		bios_rom[8'h98] = 32'h8BE12B04;
		bios_rom[8'h99] = 32'h0154E8FC;
		bios_rom[8'h9A] = 32'hFC805858;
		bios_rom[8'h9B] = 32'hBE4B75AA;
		bios_rom[8'h9C] = 32'h6AE8FF50;
		bios_rom[8'h9D] = 32'h00E8E8FF;
		bios_rom[8'h9E] = 32'hE8FF4ABE;
		bios_rom[8'h9F] = 32'hCCFEFF64;
		bios_rom[8'hA0] = 32'h56BEED74;
		bios_rom[8'hA1] = 32'hFF57E8FF;
		bios_rom[8'hA2] = 32'hE12B04B1;
		bios_rom[8'hA3] = 32'h2BE8FC8B;
		bios_rom[8'hA4] = 32'h40A85801;
		bios_rom[8'hA5] = 32'hBE237458;
		bios_rom[8'hA6] = 32'h42E8FF44;
		bios_rom[8'hA7] = 32'h75E40AFF;
		bios_rom[8'hA8] = 32'hFF44E819;
		bios_rom[8'hA9] = 32'h75FEFC80;
		bios_rom[8'hAA] = 32'h2B12B111;
		bios_rom[8'hAB] = 32'hE8FC8BE1;
		bios_rom[8'hAC] = 32'h4D8B010A;
		bios_rom[8'hAD] = 32'h41CD86F6;
		bios_rom[8'hAE] = 32'hC033E78B;
		bios_rom[8'hAF] = 32'h00A0E8EF;
		bios_rom[8'hB0] = 32'h53C3C18B;
		bios_rom[8'hB1] = 32'h63726165;
		bios_rom[8'hB2] = 32'h676E6968;
		bios_rom[8'hB3] = 32'h4F494220;
		bios_rom[8'hB4] = 32'h6E6F2053;
		bios_rom[8'hB5] = 32'h43445320;
		bios_rom[8'hB6] = 32'h20647261;
		bios_rom[8'hB7] = 32'h73616C28;
		bios_rom[8'hB8] = 32'h4B382074;
		bios_rom[8'hB9] = 32'h6E612042;
		bios_rom[8'hBA] = 32'h69662064;
		bios_rom[8'hBB] = 32'h20747372;
		bios_rom[8'hBC] = 32'h74636573;
		bios_rom[8'hBD] = 32'h2973726F;
		bios_rom[8'hBE] = 32'h2E2E2E20;
		bios_rom[8'hBF] = 32'h4F494200;
		bios_rom[8'hC0] = 32'h6F6E2053;
		bios_rom[8'hC1] = 32'h6F662074;
		bios_rom[8'hC2] = 32'h2C646E75;
		bios_rom[8'hC3] = 32'h69617720;
		bios_rom[8'hC4] = 32'h676E6974;
		bios_rom[8'hC5] = 32'h206E6F20;
		bios_rom[8'hC6] = 32'h33325352;
		bios_rom[8'hC7] = 32'h31282032;
		bios_rom[8'hC8] = 32'h30323531;
		bios_rom[8'hC9] = 32'h73706230;
		bios_rom[8'hCA] = 32'h3066202C;
		bios_rom[8'hCB] = 32'h313A3030;
		bios_rom[8'hCC] = 32'h20293030;
		bios_rom[8'hCD] = 32'h002E2E2E;
		bios_rom[8'hCE] = 32'h00000040;
		bios_rom[8'hCF] = 32'h00489500;
		bios_rom[8'hD0] = 32'h87AA0100;
		bios_rom[8'hD1] = 32'h00000049;
		bios_rom[8'hD2] = 32'h4069FF00;
		bios_rom[8'hD3] = 32'hFF000000;
		bios_rom[8'hD4] = 32'h00000077;
		bios_rom[8'hD5] = 32'h007AFF00;
		bios_rom[8'hD6] = 32'hFF000000;
		bios_rom[8'hD7] = 32'h00000000;
		bios_rom[8'hD8] = 32'h01B4FFB0;
		bios_rom[8'hD9] = 32'h40B951EE;
		bios_rom[8'hDA] = 32'h59FEE200;
		bios_rom[8'hDB] = 32'hF473C003;
		bios_rom[8'hDC] = 32'h0000C3ED;
		bios_rom[8'hDD] = 32'h50FE6BE8;
		bios_rom[8'hDE] = 32'h00E0BA52;
		bios_rom[8'hDF] = 32'h5AEEC48A;
		bios_rom[8'hE0] = 32'h5250C358;
		bios_rom[8'hE1] = 32'hEF00E3BA;
		bios_rom[8'hE2] = 32'h90C3585A;
		bios_rom[8'hE3] = 32'h90909090;
		bios_rom[8'hE4] = 32'hFE54E890;
		bios_rom[8'hE5] = 32'hE1BA5250;
		bios_rom[8'hE6] = 32'hEEC48A00;
		bios_rom[8'hE7] = 32'hFCC3585A;
		bios_rom[8'hE8] = 32'hC030FF31;
		bios_rom[8'hE9] = 32'hF30004B9;
		bios_rom[8'hEA] = 32'h75C0FEAA;
		bios_rom[8'hEB] = 32'h0040BFF7;
		bios_rom[8'hEC] = 32'h80BF058A;
		bios_rom[8'hED] = 32'hFD57E800;
		bios_rom[8'hEE] = 32'h17EB258A;
		bios_rom[8'hEF] = 32'hFFA0E853;
		bios_rom[8'hF0] = 32'h9BE8DC8A;
		bios_rom[8'hF1] = 32'h89C38AFF;
		bios_rom[8'hF2] = 32'h02C78305;
		bios_rom[8'hF3] = 32'h7502E983;
		bios_rom[8'hF4] = 32'h52C35BEC;
		bios_rom[8'hF5] = 32'hEF00E4BA;
		// ★ [95th self-test probe v2, 2026-09-26] 自测额外上报 offset 0x180
		//   （line 6 自己的槽位）的回读字节到空闲端口 0x00E5。
		//   v1 已经证实 [0x80]=0x60 且 [0x84]=0x61 —— 自测图案整体右移 0x100 字节（+4 行）。
		//   本轮判据：[0x180]==0x60 ⇒ DDR 完好、是**填充读错地址**；
		//             否则 ⇒ line 6 的**写回落到了别处**。
		//   机器码：03D8 8A 85 00 01 / 03DC BA E5 00 / 03DF EE / 03E0 5A / 03E1 C3
		bios_rom[8'hF6] = 32'h0100858A;
		bios_rom[8'hF7] = 32'hEE00E5BA;
		bios_rom[8'hF8] = 32'h8B52C35A;
		bios_rom[8'hF9] = 32'h00E2BAC2;
		bios_rom[8'hFA] = 32'hB9C35AEF;
		bios_rom[8'hFB] = 32'hFEE2FFFF;
		// 原：bios_rom[8'hFC] = 32'h00FC00EA;   // JMP FAR F000:FC00（落在垃圾）
		bios_rom[8'hFC] = 32'h00E05BEA;
		bios_rom[8'hFD] = 32'h000000F0;
		bios_rom[8'hFE] = 32'h00000000;
		bios_rom[8'hFF] = 32'h00000000;
	end
	//   位映射：tag = maddr[20:11]，index = maddr[10:6] ⇒ index[4] = maddr[10]、index[3:0] = maddr[9:6]。
	//   ⚠️ 必须用 maddr[10]（=index[4]）判"index≥16"；写成 maddr[11] 会把"BIOS 代码下方的栈行"
	//      （tag 也是 0x1FF、index 0-15）也算进 BIOS 区，导致栈行被填成 ROM 数据。
	wire        bios_fill  = (STATE == 3'b111) && (maddr[`ADDR-1:`LINE+`SETS] == 10'h1FF) && maddr[`LINE+`SETS-1];
	wire [7:0]  bios_raddr = {maddr[`LINE+`SETS-2:`LINE], word_a};  // index[3:0] + 行内字序号
	wire [31:0] bios_word  = bios_rom[bios_raddr];
	wire [15:0] bios_half  = lowaddr[0] ? bios_word[31:16] : bios_word[15:0];
	wire [31:0] fill_data  = bios_fill ? {bios_half, bios_half} : {ddr_din, ddr_din};
		
	cache cache_mem
	(
		.clock_a(ddr_clk), // input clka
		.enable_a(cache_write_data | cache_read_data), // input ena
	  	.byteena_a({lowaddr[0], lowaddr[0], ~lowaddr[0], ~lowaddr[0]}),
		// ★★ 三十七次修复：端口 A 的写**只允许在填充相**（STATE 111）。
		//   证据链（三十七次那次上板）：
		//     · `dbg_fwleak = 1` —— 确有填充数据写在 STATE!=111 时到达（实测）；
		//     · 断电重上电后的 dump：cells 0-31 **全对**，但 cells 32/33/34 = 0x0000/0x0000/0x0005
		//       —— 正是 index1 那一行的**行首 1.5 个字**被覆盖；空白区还每隔约 32 cell 冒一个孤立垃圾
		//       （cell 64/65/96/130/160）⇒ 典型"泄漏的填充写落在行首字"的签名。
		//   为何这次不会像三十六次那样吞掉合法写：`lowaddr` 归位后（见上），fill 相内必须走满
		//   32 个 `cache_write_data` 脉冲才产生 fall ⇒ **所有合法填充写都落在 STATE==111 内**，
		//   门控只会挡住"迟到的泄漏写"，不会丢任何合法数据。
		.wren_a(cache_write_data && (STATE == 3'b111)), // input [0 : 0] wea
		.address_a({wb_way, ~wb_hiaddr[`SETS-1:10-`LINE], wb_hiaddr[10-`LINE-1:0], word_a}), // input [10 : 0] addra  ★★ 77th fix: FROZEN wb_way/wb_hiaddr (kills the 24.4ns CPU(25MHz)->A-port(50MHz) combinational path)
		.data_a(fill_data), // input [31 : 0] dina  // ★ 四十一次：BIOS 区取 ROM，其余取 DDR
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
				// 写命中：只把**数据实际落入的那个 way**（fit_enc；多 hot 时 = 统一选定的 way）置脏，
				// 并把同一 tag 的**兄弟 way 清干净**；同一 index 上**别的 tag** 的 way 的脏位必须原样保留。
				// ★★ 多hot置脏修复（2026-09-27，台架 A/B 已复现+验证）：
				//   原写法 `| fit` 在多 hot 情形（复位初值 index16-31 四 way 同 tag=511，而 BIOS 栈
				//   SS:SP=F000:FC00 ⇒ maddr 0xFFC00 ⇒ index16 正在其中）下，把**四个 way 全标脏**，
				//   但数据只写进 fit_enc 那一个 way ⇒ 兄弟 way 保留陈旧数据（= 预置 bootstrap 内容）
				//   却 dirty=1 ⇒ 被选为 victim 时**把陈旧数据写回到本行地址** ⇒ DDR 里这行被 bootstrap
				//   内容覆盖 ⇒ 栈行一旦逐出回填，CPU 弹垃圾、跑飞（"屏幕冻在第一串"）。
				//   ✗ 第一版修复写成 `cache_dirty[index] <= (4'b0001 << fit_enc)`：台架 A/B 对照立刻暴露
				//     它**整字覆盖**了该 index 的 4 位脏位 —— 只要此后同一 index 上另一个 tag 发生写命中
				//     （逐出-填充后紧接着的写就是这样），那条 way 的脏位会被抹掉 ⇒ 正确数据永不写回。
				//   ✔ 正解：`(dirty & ~fit) | (1<<fit_enc)` —— 只清"与本次访问同 tag 的兄弟 way"，
				//     同 index 上别的 tag 的脏位原样保留。单 way 命中时 fit==1<<fit_enc ⇒ 与原
				//     `dirty | fit` 完全等价（零回归）。
				if(|mwmask)
					cache_dirty[index] <= (cache_dirty[index] & ~fit) | (4'b0001 << fit_enc);
			end else begin
				// ★ 十次修复：miss 时 victim(fblk) 将被填充 → 设为 MRU。
				// ★ 十五次修复：同样改 `>=` 递减 + clamp，保证 victim 在 4 way 间轮转。
				for(w=0; w<(1<<`WAYS); w=w+1)
					cache_lru[w][index] <= (w == fblk) ? {`WAYS{1'b1}}
						: (cache_lru[w][index] - ((cache_lru[w][index] >= cache_lru[fblk][index]) && (cache_lru[w][index] != {`WAYS{1'b0}})));
				// ★★ 83rd fix (2026-09-26): the victim's dirty bit must NOT be cleared here.
				//   Earlier rounds cleared it at the miss decision (STATE 000), i.e. BEFORE the
				//   write-back (STATE 011) had proven it actually ran. That defeats the round-35
				//   `wb_full` guard: the dirty bit vanished even when the burst was starved
				//   (np=0 - the exact failure recorded in the round-35 comment above), so the
				//   line never reached DDR; and the per-frame flush could not retry it either
				//   (it reads dirty=0 and skips the line) -> the data was silently lost, and the
				//   next read refilled the slot with DDR zeros.
				//   The dirty bit is now cleared ONLY by `flush_wb_done` (STATE 011 + ddr_wr +
				//   s_lowaddr5_fall + wb_full). Round 21 already made that event universal for
				//   BOTH the flush path and the read-miss eviction path, and it uses the frozen
				//   wb_hiaddr/wb_way latched at STATE 000, so it hits exactly the right
				//   index/way in both cases.
				//   Worst case is one redundant write-back, never lost data - the same argument
				//   the round-35 fix is built on.
			end
		end
	end

		
	always @(posedge clk) begin
		s_lowaddr5 <= lowaddr[`LINE-2];
		s_lowaddr5_d1 <= s_lowaddr5;
		s111_d <= (STATE == 3'b111); // ★★ 88th fix: one-cycle delay before the fill read is requested
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
				ddr_rd <= 1'b0; // ★★ 88th fix: was ~dirty & ~r_flush - the fill read must NOT be requested here, hiaddr still carries the VICTIM's address (line 813)
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
			ddr_rd <= 1'b0; // ★★ 88th fix: was ~r_flush - during the write-back hiaddr = wb_hiaddr (the victim), so a read requested now would fetch the VICTIM's line
			// ★ 整行修复：必须等 lowaddr 从 31 回绕到 0（s_lowaddr5_fall）才退出。
			//   原代码在 s_lowaddr5 高电平（lowaddr=16）就退出，此时 AXI burst 还在传后半行，
			//   状态机若提前进入 111 会更新 hiaddr，导致后半行写错地址（0x20/0x40 偏移）。
			if(s_lowaddr5_fall) begin   // ★ 三十七次：回到纯 fall 判据（确定性，见第 35 节）
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
			ddr_rd <= s111_d; // ★★ 88th fix: raise the read one cycle after entering 111, i.e. only once hiaddr == maddr[`ADDR-1:`LINE] (the line we actually want to fetch)
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

	// ============================================================================
	// ★ 二十四次诊断 v8（2026-09-22）：index0 为何"从不被写回 DDR"？
	//   事实：v6/v7 两次读数 cnt/i0_flush/i0_evict 全 0；旧 sticky dbg_flush_vram_seen=0。
	//   本组分别回答：① index0 的 tag 阵列里是否出现过 VRAM tag？② index0 的 dirty 是否置过？
	//   ③ 所有 VRAM 写回里有没有 index0？④ flush 是否真的扫到过 index0、扫到时 tag 是什么？
	//   判据：
	//     ③的 bit0=0 且 ①=0 → index0 的 VRAM 行从未被装进缓存（写不进 → 也无需写回）；
	//     ① =1 而 ③bit0=0 → tag 装进去了但从不逐出/flush 到 → 查 victim/脏位；
	//     ② =0 → CPU 对 index0 的写从未置脏（写全 miss 被丢）→ 查写缺失路径。
	// ============================================================================
	reg        dbg_i0_has170     = 1'b0; // index0 任一 way 曾持有 tag 0x170/0x171
	reg [3:0]  dbg_i0_dirty_or   = 4'd0; // OR 累加 index0 的 4-way dirty
	reg [4:0]  dbg_vram_wb_idx_or = 5'd0;// OR 累加所有 VRAM 写回的 index（bit0=index0）
	reg        dbg_fl_i0_seen    = 1'b0; // flush 扫描(st0&&r_flush)曾到 index0
	reg [9:0]  dbg_fl_i0_tag     = 10'd0;// 记录 flush 扫 index0 时该 way 的 tag
	always @(posedge clk) begin
		if (cache_addr[0][0]==10'h170 || cache_addr[1][0]==10'h170 ||
		    cache_addr[2][0]==10'h170 || cache_addr[3][0]==10'h170 ||
		    cache_addr[0][0]==10'h171 || cache_addr[1][0]==10'h171 ||
		    cache_addr[2][0]==10'h171 || cache_addr[3][0]==10'h171)
			dbg_i0_has170 <= 1'b1;
		dbg_i0_dirty_or <= dbg_i0_dirty_or | cache_dirty[0];
		if ((STATE == 3'b011) && ddr_wr &&
		    (wb_hiaddr[14:5]==10'h170 || wb_hiaddr[14:5]==10'h171))
			dbg_vram_wb_idx_or <= dbg_vram_wb_idx_or | wb_hiaddr[4:0];
		if (st0 && r_flush && (index == 5'd0)) begin
			dbg_fl_i0_seen <= 1'b1;
			dbg_fl_i0_tag  <= cache_addr[fblk][index];
		end
	end

	// ============================================================================
	// ★ 三十五次诊断（2026-09-23）：钉死"VRAM row0 写回被启动、数据相却没跑"的机制。
	//   已知（三十四次）：`dbg_wr0_seen=0`（精确 gate `wb_hiaddr==0x2E00`）——row0 的写回窗口内
	//   **没有任何 cache_read_data 脉冲**；而 `dbg_wbx_seen=1`（其它 VRAM 行能写回）、
	//   ddr_186 的 `dbg_wr0_memmap=6`（确实有过 s_ddr_wr && hiaddr==0x2E00）。⇒ 写回被"启动"但没读数据。
	//   本组再分开两件事：
	//     st011 = STATE011 & ddr_wr=1 & hiaddr=0x2E00 曾成立（写回启动过）
	//     np[5:0]= **窗口口径**的读脉冲数：只在"冻结的写回地址仍是 row0"这一窗口（`wb_hiaddr==0x2E00`）
	//              内计数，不要求 STATE==011 也不要求 ddr_wr=1 ⇒ 即使 state 机提前退出/命令拉低，
	//              burst 打在 cache_read_data 上的脉冲仍被计入。=32 ⇒ burst 其实跑了（只是 FSM 已走）；
	//              =0 ⇒ burst 根本没跑（写回在命令层被饿死 / 命令从未发出）。
	//     n[5:0] = 旧口径（STATE011 内的读脉冲数，前面测到 0）
	//     l0[4:0]= 该窗口开始时的 lowaddr（≥16 且随后 cache_line_start 复位 ⇒ 假 s_lowaddr5_fall ⇒ 提前退出）
	//     cs     = 该窗口内 cache_line_start 曾为 1（复位 lowaddr 的来源）
	//     fall   = 该窗口内 s_lowaddr5_fall 曾为 1（终止事件）
	//     clr    = 该窗口内**旧判据** flush_wb_done_old 曾为 1（⇒ 脏位被清、数据被丢）
	//   判读：np=32 ⇒ 提前退出（burst 跑了但 state 机已走）→ 查退出条件/地址是否被 VGA 优先权改坏；
	//         np=0  ⇒ 命令层饿死（ddr_186 的 s_prog_empty 优先于 s_ddr_wr）→ 改写回优先级；
	//         l0≥16 ⇒ 证实"复位 lowaddr 造成假 fall"。
	reg        dbg_wbx_seen  = 1'b0;
	// ★ 三十六次补充探针：填充数据写（cache_write_data）曾在"非填充相(STATE!=111)"到达 ——
	//   即"上一笔事务读 burst 的余波"的直接证据（它会把别的行数据写进当前 cache 行）。
	reg        dbg_fwleak    = 1'b0;
	// ★ 三十八次诊断（2026-09-23）：把"空白区零星色块"钉到具体机制上。
	//   事实：清屏(rep stosw 写 0)后 cells 64/65/96/130/160 = 0x0010/0x0008/0x1000/0x0080/0x1001，
	//         且 4/5 个都落在各自 cache 行的**首字**（word0），idx2/3/5 的 off0 + idx4 的 off4。
	//   推理：CPU 对这些 cell 只写过 0 ⇒ 行里的非零字**不可能是 CPU 写的** ⇒ 只可能是填充数据写
	//         (cache_write_data，把 DDR 旧内容写进 cache 行) 泄漏进来的。本组探针直接抓它。
	//   判据：lk_nz=1 且 lk_dat ∈ {0x0010,0x0008,0x1000,0x0080,0x1001} ⇒ 泄漏写实锤；
	//         lk_cnt=0                                        ⇒ 泄漏写不成立 → 看 dbg_wlost。
	reg [7:0]  dbg_lk_cnt = 8'd0; // 泄漏写脉冲数（饱和 255）
	reg        dbg_lk_nz  = 1'b0; // 出现过"非零数据"的泄漏写
	reg [4:0]  dbg_lk_idx = 5'd0; // 最近一次非零泄漏写的 index
	reg [4:0]  dbg_lk_lo  = 5'd0; // 同一写的 lowaddr[4:0]
	reg [15:0] dbg_lk_dat = 16'd0;// 同一写的数据（=被写进该行的值）
	reg [2:0]  dbg_lk_st  = 3'd0; // 同一写时的 STATE
	// ★ 三十八次诊断之二：**CPU 写被静默丢弃**检测。
	//   代码事实：`fit[i] = ~r_flush && (...)` ⇒ 在 r_flush 刚拉高那一拍 hit 被强制 0、端口 B 写被挡
	//   （enable_b 带 !r_flush），而同一拍 `ce` 仍是 1（r_flush 分支要到本拍结束才 ce<=0，见 STATE 000 的
	//   `else if(r_flush)` 分支尾部）⇒ 该拍 CPU 若有 VRAM 写，会被 CPU 视为"已完成"但 cache 没收。
	//   后果与该 cell 保留 DDR 填充旧值完全一致（现象与泄漏写无法从值上区分）⇒ 必须用本标志判别。
	reg        dbg_wlost  = 1'b0; // ce=1 但端口 B 未接受 CPU 写
	reg [4:0]  dbg_wl_idx = 5'd0; // 该丢失写的 cache index
	reg [3:0]  dbg_wl_wrd = 4'd0; // 该丢失写在行内的字序号
	reg        dbg_wr0_seen  = 1'b0;
	reg        dbg_wr0_st011 = 1'b0;
	reg        dbg_wr0_fall  = 1'b0;
	reg        dbg_wr0_cs    = 1'b0;
	reg        dbg_wr0_clr   = 1'b0;
	reg [4:0]  dbg_wr0_l0    = 5'd0;
	reg [5:0]  dbg_wr0_n     = 6'd0;
	reg [5:0]  dbg_wr0_np    = 6'd0;
	reg [5:0]  dbg_wr0_nw    = 6'd0;  // 窗口内 cache_write_data 脉冲数（>0 即上一笔事务余波证据）
	reg [15:0] dbg_wr0_w0    = 16'd0;
	reg [15:0] dbg_wr0_w1    = 16'd0;
	reg [5:0] wr0_cnt = 6'd0, wr0_np_cnt = 6'd0, wr0_nw_cnt = 6'd0;
	reg       wr0_any = 1'b0, wr0_np_any = 1'b0, wr0_l0_done = 1'b0;
	wire wr0_act    = (STATE == 3'b011) && ddr_wr && (wb_hiaddr == 15'h2E00);
	// np 口径：只看"冻结的写回地址仍是 row0"这一窗口（wb_hiaddr 在 STATE 011 全程冻结、
	//   直到下一次写回决定才变），因此**即使 state 机提前离开 011、或 ddr_wr 已拉低**，
	//   burst 期间打在 cache_read_data 上的脉冲仍会被计入 ⇒ 能区分
	//   "burst 根本没跑(np=0)" 与 "burst 跑了但 FSM 已提前退出(np=32)"。
	wire wr0_np_win = (wb_hiaddr == 15'h2E00);
	wire wbx_any_vram = (STATE == 3'b011) && ddr_wr &&
	                    (wb_hiaddr[14:5] == 10'h170 || wb_hiaddr[14:5] == 10'h171);
	always @(posedge ddr_clk) begin
		if(wbx_any_vram) dbg_wbx_seen <= 1'b1;
		if(cache_write_data && (STATE != 3'b111)) begin
			dbg_fwleak <= 1'b1;
			if(dbg_lk_cnt != 8'hFF) dbg_lk_cnt <= dbg_lk_cnt + 8'd1;
			if(ddr_din != 16'd0) begin          // 只锁"非零数据"的泄漏（空白区该是 0，非零即证据）
				dbg_lk_nz  <= 1'b1;
				dbg_lk_idx <= index;
				dbg_lk_lo  <= lowaddr[4:0];
				dbg_lk_dat <= ddr_din;
				dbg_lk_st  <= STATE;
			end
		end
		// ★ 三十八次诊断：r_flush 刚拉高那一拍（hit 已被 ~r_flush 打掉）而 ce 仍为 1 → CPU 写被丢
		if(ce && mreq && (|wmask) && (STATE == 3'b000) && r_flush) begin
			dbg_wlost  <= 1'b1;
			dbg_wl_idx <= maddr[`LINE+`SETS-1:`LINE];
			dbg_wl_wrd <= maddr[`LINE-1:2];
		end

		// (a) 窗口口径的读脉冲计数（不受 STATE/ddr_wr 提前变化影响）
		if(wr0_np_win) begin
			if(cache_read_data) begin
				wr0_np_cnt <= wr0_np_cnt + 1'b1; wr0_np_any <= 1'b1;
			end
			if(cache_write_data) wr0_nw_cnt <= wr0_nw_cnt + 1'b1;
		end else begin
			if(wr0_np_any) begin
				dbg_wr0_np <= wr0_np_cnt;              // 窗口关闭 → 记录本次
				dbg_wr0_nw <= wr0_nw_cnt;
			end
			wr0_np_cnt <= 6'd0; wr0_np_any <= 1'b0; wr0_nw_cnt <= 6'd0;
		end

		// (b) STATE 011 窗口内的观测
		if(!ddr_wr) begin
			if(wr0_any) dbg_wr0_n <= wr0_cnt;
			wr0_cnt <= 6'd0; wr0_any <= 1'b0; wr0_l0_done <= 1'b0;
		end else begin
			if(wr0_act) begin
				dbg_wr0_st011 <= 1'b1;
				if(s_lowaddr5_fall)   dbg_wr0_fall <= 1'b1;
				if(cache_line_start)  dbg_wr0_cs   <= 1'b1;
				if(flush_wb_done_old) dbg_wr0_clr  <= 1'b1;
				if(!wr0_l0_done) begin dbg_wr0_l0 <= lowaddr[4:0]; wr0_l0_done <= 1'b1; end
			end
			if(wr0_act && cache_read_data) begin
				wr0_cnt <= wr0_cnt + 1'b1; wr0_any <= 1'b1;
				dbg_wr0_seen <= 1'b1;
				if(wr0_cnt == 6'd1) dbg_wr0_w0 <= cache_QA[15:0];
				if(wr0_cnt == 6'd3) dbg_wr0_w1 <= cache_QA[15:0];
			end
		end
	end
	
	// ★★ 四十二次诊断（2026-09-24，纯观测、不影响逻辑）：
	//   ① dbg_biosfill_seen：BIOS 区（tag 0x1FF 且 index≥16）是否真的进入过填充相
	//      —— 验证四十一次加的 ROM 回填路径**到底有没有被用到**；若恒 0，说明那次修复是 no-op。
	//   ② dbg_stk_wb_seen：tag 0x1FF 且 index<16（= BIOS 映像正下方的 1KB 栈区）是否被写回过。
	//      若栈区返回地址在逐出时丢失（脏位/写回问题）→ 后续 ret 弹出 0 → 跳 IP=0x0000 →
	//      在段内空内存里逐 +2 跑飞（与本轮新读数吻合）。此位是判据之一。
	reg dbg_biosfill_seen = 1'b0;
	reg dbg_stk_wb_seen   = 1'b0;
	always @(posedge ddr_clk) begin
		if(bios_fill) dbg_biosfill_seen <= 1'b1;
		if((STATE == 3'b011) && ddr_wr && (wb_hiaddr[14:5] == 10'h1FF) && !wb_hiaddr[4])
			dbg_stk_wb_seen <= 1'b1;
	end

	// ============================================================================
	// ★★ 四十三次诊断（2026-09-24）：对"栈返回槽"三向对账。
	//   槽 = maddr 0xFFBFE（SS:SP=0xF000:0xFBFE）→ tag 0x1FF / index 15 / 行内 offset 0x3E
	//        → 物理 0x0815FBFE（cache 行 = index15，hiaddr = {0x1FF,15} = 15'h3FEF）。
	//   背景（四十二次读数）：wild_pre=0xFD1B(=映像 0x11B 的 ret)、wild_op=0xC3(RET)、
	//     wild_ip=0x00C8 —— ret 弹出的既不是正确返回址 0xFC31，也不是 DDR 噪声 0x1114，
	//     而是确定性重复出现的 0x00C8（与上一次 esc 抓到的 CS 同值）。
	//   本组回答：① CPU 到底有没有把 0xFC31 写进这个槽（写通路）；② 命中/缺失 + 用哪个 way；
	//             ③ CPU 从该槽读回什么；④ 写回时该槽送出什么。
	//   判读：
	//     pbfe_dat=0xFC31 而 rbfe_dat=0x00C8 → 写进去了但读错 → 读通路/way 选择问题；
	//     pbfe_dat 本身不是 0xFC31         → 写通路就没带对数据（或写被丢）；
	//     s15wb_dat=0x00C8 而 DDR=0x1114   → 写回送出的数据与 DDR 不符 → 写回 way/地址错配。
	// ============================================================================
	reg        dbg_pbfe_seen = 1'b0;  // CPU 曾向该槽写入
	reg [15:0] dbg_pbfe_dat  = 16'd0;  // 写入的数据（期待 0xFC31）
	reg        dbg_pbfe_hit  = 1'b0;   // 该次写命中
	reg        dbg_pbfe_miss = 1'b0;   // 该次写缺失
	reg [1:0]  dbg_pbfe_way  = 2'd0;   // 该次写使用的 way（=blk）
	reg        dbg_rbfe_seen = 1'b0;   // CPU 曾从该槽读
	reg [15:0] dbg_rbfe_dat  = 16'd0;  // 读回的数据（期待 0xFC31）
	reg        dbg_s15wb_seen = 1'b0;  // index15 行曾被写回
	reg [15:0] dbg_s15wb_dat  = 16'd0; // 写回该槽送出的数据
	reg [7:0]  dbg_ra_n   = 8'd0; // 写入该槽的"0xFCxx"值次数（预期 3）
	reg [7:0]  dbg_rra_n  = 8'd0; // 从该槽读回的"0xFCxx"值次数（预期 3；=2 ⇒ 崩点那次读失败）
	reg        dbg_rbad_hit  = 1'b0; // 坏读且命中（行内容本身错）
	reg        dbg_rbad_miss = 1'b0; // 坏读且缺失（填充数据错）
	//   ★ 四十四次修订：原 last-wins 的两个 16-bit 数据探针**被跑飞后的垃圾访问污染**
	//     （实测 pbfe_dat=0xF000 = 垃圾 push es；rbfe_dat=0x0000 = 垃圾 pop），故改为：
	//       · pbfe_dat 改 **first-wins**（首次写入值，应为第一条 call 的返回址 0xFC26）；
	//       · 新增 **计数型**探针（对 0xFCxx 这类"返回地址样式"的值计数）+ 坏读的 hit/miss 分流。
	//     读数据比地址晚 1 拍（BRAM q_b 寄存输出，BIU 也是按 1 拍延迟消费）⇒ 用 rd_sa 延迟一拍照 dout。
	wire bfe_addr = (maddr == 21'h0FFBFE);
	wire wr_bfe   = mmreq && (|mwmask)  && bfe_addr;
	wire rd_bfe   = mmreq && !(|mwmask) && bfe_addr;
	wire wr_fc    = wr_bfe && (mdin[31:16] >= 16'hFC00);   // 写入"返回地址样式"
	wire rd_fc    = rd_bfe && (dout[31:16] >= 16'hFC00);   // 读回"返回地址样式"
	wire rd_bad   = rd_bfe && (dout[31:16] <  16'hFC00);   // 坏读
	always @(posedge clk) begin
		if(wr_bfe) begin
			dbg_pbfe_seen <= 1'b1;
			if(!dbg_pbfe_seen) dbg_pbfe_dat <= mdin[31:16]; // first-wins
			dbg_pbfe_way  <= blk;
			if(hit) dbg_pbfe_hit <= 1'b1; else dbg_pbfe_miss <= 1'b1;
		end
		if(wr_fc && dbg_ra_n  != 8'hFF) dbg_ra_n  <= dbg_ra_n  + 1'b1;
		if(rd_fc && dbg_rra_n != 8'hFF) dbg_rra_n <= dbg_rra_n + 1'b1;
		if(rd_bad) begin
			if(hit) dbg_rbad_hit <= 1'b1; else dbg_rbad_miss <= 1'b1;
		end
	end
	always @(posedge ddr_clk) begin
		if((STATE == 3'b011) && ddr_wr && (wb_hiaddr == 15'h3FEF) &&
		   (wb_pcnt[5:1] == 4'd15) && cache_read_data) begin
			dbg_s15wb_seen <= 1'b1;
			dbg_s15wb_dat  <= cache_QA[31:16]; // word15 的高半字 = 行内 offset 0x3E
		end
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
