# 95th 修复：一条 cache 事务只允许一次 AXI burst

> 2026-09-26 · 用 `sim/` 下的 Verilator 台架定位并验证
> commit `7b9e95e`（基于 `4d4f126` = 91st 修复），已 push 到 `ssh://git@ssh.github.com:443/co27la57/Next186.git`

---

## 1. 结论一句话

`ddr_wr` / `ddr_rd` 是**电平**，覆盖整条 cache 事务（实测 144 个 `clk_sdr`）；而 AXI FSM 一次
16 拍 burst 只要 ~80 个 `clk_sdr`，之后还有 **6 拍 IDLE 采样窗口**。命令寄存器取自**延迟一拍**的
`s_ddr_wr`/`s_ddr_rd`，再寄存一拍 ⇒ 比 cache 实际状态**晚 2 拍**。FSM 在 IDLE 采样时正好落进这
2 拍残留，读到**已经作废的 `2'b01`/`2'b11`**，于是**在同一条事务内多发一次完整 burst**。

写回侧这是致命的：`ram_wdata` 来自 cache 的 `ddr_dout`，字序号由 `wb_pcnt` 决定，而
`wb_pcnt` 在 `ddr_wr=0` 时被清零（`cache_controller.v:358`）。此时 cache 已离开 STATE 011
⇒ `wb_pcnt==0` ⇒ **16 拍全发 word0**，把刚写回正确的那一行覆盖成"word0 重复"。

---

## 2. 逐拍证据（`gate_fill=1`，无 VGA 争用）

```
36717 AW cmd=01 byte=08150000 cst=3 ddrwr=1   <- 正确写回，W[0..15] 数据全对
36798 FSM 回到 IDLE
36802 dwr=0（cache 离开 STATE 011）
36803 IDLE ic=5 ack=00 cmd=01 dwr=0           <- 命令寄存器残留 2'b01，FSM 在此拍采样
36804 AW cmd=10 byte=08150000 cst=7 ddrwr=0   <- 伪 burst，W[0..15] 全是 word0
```

16 个缓冲行**行行如此**（每对间隔 87 拍）：整场 48 次 AW 中 **16 次是伪 burst**。

> 注意：`36804` 那行 trace 打印的 `cmd=10` 是**采样之后**的值，具有误导性；
> 真正被采样的是 `36803` 那一拍的 `cmd=01`（`ack=01` 的写 burst 就是证据）。

---

## 3. 端到端判据（这才是能复现板上症状的判据）

台架驱动从"只读 0x40 / 0x80 两个字节"升级为 **scan256 之后逐字节读回整个 1 KB 缓冲区**：

```
for m in 0..1023:  rd_byte(F000:0000 + m)  must equal  (m>>2) & 0xFF
```

**单读 0x80 没有判别力** —— "word0 重复"这种损坏恰好让 0x80 读到 `0x20`，看起来是对的；
逐字节读回才能抓住它（`0x84` 会读到 `0x20` 而不是 `0x21`）。

| 配置 | 旧逻辑 | 95th 修复 |
|---|---|---|
| `gate_fill=1 vga=0` | **960 / 1024 字节错** | **0 / 1024 PASS** |
| `gate_fill=1 vga=1` | **880 / 1024 字节错** | **0 / 1024 PASS** |
| AXI AW burst | 48 次（**16 次伪**） | 32 次（**0 次伪**） |

`gate_fill=0` 是"没有 91st 修复"的对照，**不代表真机**（真机 RTL 已含 91st，见 `ddr_186.v:668`）。

---

## 4. 修复内容（`ddr_186.v`）

```verilog
reg  cache_cmd_done = 1'b0;
wire cache_owns = (s_ddr_wr || s_ddr_rd) && !cache_cmd_done;
...
// 本请求已被 FSM 服务过一次 burst；cache 完全无请求时重新使能
if(!ddr_wr && !ddr_rd)    cache_cmd_done <= 1'b0;
else if(cache_line_start) cache_cmd_done <= 1'b1;

// 地址使能与命令同源，保证 FSM 采样瞬间"命令"与"地址"不错配
sdraddr <= s_prog_empty || !cache_owns ? vga : cache;

if(s_prog_empty)      cntrl0_user_command_register <= 2'b10;
else if(cache_owns)   cntrl0_user_command_register <= s_ddr_wr ? 2'b01 : 2'b11;
else if(~s_prog_full) cntrl0_user_command_register <= 2'b10;
else                  cntrl0_user_command_register <= 2'b00;
```

### ⚠ 关键设计约束（第一版修法在这里翻过车，勿重犯）

最初写成"请求上升沿锁一个 `cache_cmd_req`、FSM 确认后撤销"，命令类型仍取实时 `s_ddr_wr`。
在 `vga=1`（VGA 抢占）下 **cache 死锁**：VGA 把 FSM 拖过请求尾巴后 `s_ddr_wr` 已落
⇒ FSM 把**写回当成填充**发 ⇒ cache 在 STATE 011 等一个永远不会来的 `ram_wr_valid`。

⇒ **命令类型与地址必须取实时信号（不锁存）**，只锁"本请求是否已被服务"这一个 bit。

`cache_cmd_done` 的清零条件取"cache 完全无请求"是安全的：cache 在 STATE 011/111 里只能靠
`ram_wr_valid`/`ram_rd_valid` 推进，所以 `ddr_wr`/`ddr_rd` **不可能**在 FSM 服务之前自行拉低
（不会丢事务，也不会卡死）。

---

## 5. 顺带修掉的两个台架 bug

它们让前任"91st 不是根因"的结论**不可信**：

1. **`ack` 声明成 1 bit**：真 RTL 是 `reg [1:0] ram_cmd_ack`。台架写成 1 bit ⇒ `ack <= ram_cmd`
   只留 bit0 ⇒ `sys_cmd_ack == 2'b11` **永远不成立** ⇒ `gate_fill=1` 时填充死锁
   （`line-2 fills = 0`，跑了 1.07e8 拍）。
2. **DDR 内存模型用绝对地址索引**：`mem[(byte_addr>>2)]`，而所有 AXI 地址都是 `0x0800_0000+`
   ⇒ 索引 ≥ `0x200_0000`，远超 `1<<20` ⇒ **每一次访存都越界**（读堆垃圾、写坏堆）。

另有两个小坑：字节写必须像真 BIU 一样把字节**复制到 4 个字节道**
（`RAM_DOUT = {DSWAP,DSWAP}`）；VGA 饿死模型必须每拍更新，否则读回阶段被冻结成常值 ⇒ 永久饿死
cache（表现为"卡死"）。

---

## 6. 校验清单（本次）

| 项 | 结果 |
|---|---|
| `begin` / `end` 平衡 | 45 / 45 |
| 行尾 | 1290 CRLF，0 个裸 LF（`ddr_186.v` 保持 CRLF） |
| 探针预算 | 39 个探针 / **269 bit**（< 300，本次**未新增探针**） |
| 两张 BIOS 表 comment-aware 逐字比对 | 256 / 256 完全一致 |
| Verilator `--lint-only`（全 RTL） | **0 个真实 error**（20 个 `MODMISSING` 全是 Vivado 原语 / VHDL） |
| 远端 HEAD（以 `git ls-remote` 为准） | `7b9e95ea7a55eb313ba3120c22d4bc55885e3dc0` |

---

## 7. 仍未解释 / 下一步

1. **板上 `dbg_dbg4 = 0x5010`（AH 读到 0x50 = line 5 的值，即 +3 行位移）尚未在仿真里复现。**
   台架里伪 burst 落在**同一行**（采样拍 `cache_hi_addr` 还没推进），所以只复现"word0 重复"。
   板上 VGA 真流量会改变采样相位，伪 burst 有可能落到**已推进的 `cache_hi_addr`**（即跨行破坏）
   —— 这是最可能解释 +3 行的路径。95th 修复把伪 burst 整体消掉，两种形态都覆盖，但**尚未直接
   复现跨行形态**。
2. **下板验收**：`reset_run synth_1/impl_1` → 重建 Set Up Debug → 读 `dbg_dbg4`，期望 `0x2010`。
3. 台架的 VGA 流量仍是近似（只有 `s_prog_empty`/`s_prog_full` 脉冲，没有真实 VGA 读 DDR 的流量）。
   若要直接复现跨行形态，需要给台架加一个真实的 VGA 扫描读模型。

---

## 8. 板上 ILA 快照解读（19:28，探针集 = 92~94 轮）

| 探针 | 值 | 判读 |
|---|---|---|
| `dbg_dbg0` | `00` | CMD17 的 R1 = 0x00 ✓（SD 命令/应答链健康） |
| `dbg_dbg1` | `fe` | 数据令牌 = 0xFE ✓ |
| **`dbg_dbg4`** | **`0010`** | **AL = 对照(读 0x40) = `0x10` ✓；AH = 测量(scan256 后读 0x80) = `0x00` ✗（期望 `0x20`）** |
| `dbg_dbg2` | `4a12` | 8KB 校验和 ✗（期望 `0x2F27`）⇒ **数据仍被破坏** |
| `dbg_dbg3` | `0000` | 扇区号高字，期望 `0x00EF` —— 待确认（可能没走到该上报点） |
| `dbg_bufwb_a` | `3c06` | 最后一次缓冲行写回的 hiaddr = tag 0x1E0 / idx 6 |
| `dbg_bufwb_n` | `ff` | 饱和（≥255 次缓冲行写回**事务**；伪 burst 不抬 `ddr_wr`，不计入） |
| `dbg_bufrd_seen` | `1` | 缓冲行填充确实发生 ✓ |
| `dbg_rd_reg` / `dbg_wb_reg` | `000` / `00f` | 首个缓冲行填充 idx=0、首个写回 idx=15 |
| `dbg_wb_or`/`dbg_rd_or`/`dbg_vga_or` | `ffffffff`/`ffff`/`ffff` | 全饱和 ⇒ **零信息量** |
| `dbg_fill_foreign` | `1` | 填充窗口内出现过非 cache 读数据；91st 已门控 ⇒ 被丢弃，与仿真一致（无害） |
| `dbg_cpu_w2`/`dbg_wb2_hi`/`dbg_rd2_hi`/`dbg_wb2_cnt`/`dbg_rd2_cnt` | 全 `f` | **全饱和 ⇒ 零信息量** |

### 三点关键判读

1. **`AH = 0x00` 与 95th 修复的机制完全吻合。** 伪 burst 重发的是 `cntrl0_user_input_data`，
   而 `wb_pcnt` 在 `ddr_wr=0` 时被冻结在 0 ⇒ 读到的是 BRAM 端口 A 在 `{wb_way, wb_hiaddr, word0}`
   那个位置的内容。**台架里第一条伪 burst 写的正是 16 × `0x00000000`**（DDR 转储 line 0 = 全 0），
   所以 `0x00` 是这条机制**已经产出过**的一类值，不是新故障。
2. **失败值在三次 bitstream 之间变化：`0x50` → `0x6C` → `0x00`** ⇒ 竞态特征，不是确定性数据通路错误。
   （`0x50` 那次 = line 2 被写成 `0x50505050`，即 **line 5 的 word0** —— 正是"跨行形态"。）
3. **94 轮那 5 个探针全部饱和到 `0xF`，是设计失误**：SD 驱动会把**真实 SD 数据**（任意字节，
   含 `0xF?`）写进**同一个** `F000:0000` 缓冲区，所以任何"高位半字节 OR"都必然饱和。已删除。

### 新增：能直接判定 95th 修复是否在板上生效的探针

```verilog
(* mark_debug = "true", keep = "true" *) reg [7:0] dbg_spur_wb_n = 8'h00;
(* mark_debug = "true", keep = "true" *) reg [7:0] dbg_spur_rd_n = 8'h00;
...
if((sys_cmd_ack != 2'b00) && (sys_cmd_ack_d1 == 2'b00)) begin   // ack 上升沿
    if(sys_cmd_ack == 2'b01 && !ddr_wr) ... dbg_spur_wb_n++      // 伪写回 burst
    if(sys_cmd_ack == 2'b11 && !ddr_rd) ... dbg_spur_rd_n++      // 伪填充 burst
end
```

判据只用 `cache_controller` 的模块边界端口（`sys_cmd_ack` / `ddr_wr` / `ddr_rd`），不碰 cache/CPU 内部。
**台架实测：修复前 `WB=16 / RD=92`；修复后 `WB=0 / RD=0`** —— 比 `dbg_dbg4` 锐利得多：
`dbg_dbg4` 只能告诉你"数据坏了"，这两个计数器能告诉你"**是不是这条机制**"。

同时删掉了 94 轮 5 个饱和探针 + `dbg_l2`/`dbg_cpu_l2` 两个 wire（净省 4 bit，现 36 个 / 265 bit）。

---

## 9. ⚠ 更正（20:00）：95th 修复有效，但**不是**板上数据损坏的根因

### 9.1 板上新读数（bitstream = 含 95th 探针那版）

| 探针 | 值 | 判读 |
|---|---|---|
| **`dbg_spur_wb_n` / `dbg_spur_rd_n`** | **`00` / `00`** | **伪 burst 归零 ⇒ 95th 修复在板上确实生效** |
| `dbg_dbg4` | `6010` | AL = 0x10 ✓；AH = **`0x60`** ✗（期望 0x20）⇒ **数据仍坏** |
| `dbg_dbg2` | `8f26` | 校验和仍错（期望 `0x2F27`） |
| `dbg_bufwb_a` | `3c06` | 最后一次缓冲行写回 = **index 6**；而读 0x80 得 `0x60` = **line 6 的值** |

⇒ **存在第二条独立机制。**

### 9.2 台架保真度审计：真机比例下台架连旧逻辑都不复现

先纠一个**根本性错误**：旧台架的时钟比例是 **4:1**（一个 tick 里 4 个 clk_sdr posedge），
而真机是 **2:1**：

- `dcm.v`：`CLKOUT0_DIVIDE_F(36)` → **clk_cpu = 25 MHz**
- `ddr_186.v:510`：`assign clk_sdr = CLK_50MHZ;` → **clk_sdr = 原始 50 MHz**（不走 MMCM）
- 相位自由（clk_cpu 来自 MMCM + BUFG）

改成可扫比例 × 相位后：

| 配置 | `fix_re=0`（旧逻辑） | `fix_re=1` |
|---|---|---|
| **2:1（真机）** phase 0..3 | **PASS 0/1024** | PASS |
| 4:1 phase 2..6 | **FAIL 900~960/1024** | PASS |

2:1 与 4:1 下 `ddr_wr` 脉宽**都是 150 clk_sdr**、AW 都是 32 次，但 **2:1 下伪 burst = 0**。
原因：clk_cpu 域的 `s_lowaddr5_fall → ddr_wr<=0` 在 2:1 下只延 **2** 个 clk_sdr、4:1 下延 **4** 个，
再叠命令寄存器 1 拍 ⇒ 残留窗口 2:1 下 **< 6 拍**（FSM 的 IDLE 采样点）⇒ **采样不到**。

⇒ **95th 那个竞态在真机比例下是隐性的。** 本文档第 1~6 节的机制与修复本身**成立且已被板上探针证实**，
但它**不是**板上数据损坏的根因 —— 我之前"修复会解决板上问题"的判断**过度自信，此处更正**。

### 9.3 已在台架排除（都在 2:1 + 真机配置下 PASS）

| 假设 | 实验 | 结果 |
|---|---|---|
| 跨域相位 | `cpu_phase` 0..3 全扫 | 全 PASS |
| **每帧 `auto_flush`**（台架原先 `flush` **硬接 1'b0**，完全没建模） | 建 `auto_flush` 移位寄存器模型，`frame_period` 3000..12000（flush 落进自测 2~9 次） | 全 PASS |
| VGA FIFO 占用 → 命令优先级 | 建真模型（`wrreq=!crw && sys_rd_data_valid`、`s_prog_full=used>350`、`s_prog_empty=used<64`），扫 drain 2..32 | 全 PASS |
| CPU 总线节奏 | 加 `cpu_gap` 0..16 | 全 PASS |
| `memmap_mux` 跨域陈旧 | `seg_map` 的 `assign memdata = map[memaddr]` 是**组合**输出（只有 `cpuratda` 寄存） | **假设作废** |

### 9.4 台架现在的调用签名

```
ddr_pipe.exe <gate_fill> <vga_model> <tr_on> <fix_re> <sdr_per_cpu> <cpu_phase> \
             <frame_period> <vblnk_len> <fifo_drain> <cpu_gap>
真机配置：1 0 0 <fix> 2 1 0 3 4 0
```
新增可对照量：`buf_rd_first` / `buf_wb_first` / `buf_wb_last` / `buf_wb_n` / `flush_n` /
`spur_ack_wb` / `spur_ack_rd`。

### 9.5 下一步候选（按性价比）

1. **`dbg_dbg5` 是空通道**（"自 87 次起不再写"）⇒ 把自测改成**再多上报一个回读字节**
   （如 offset 0x81 / 0x100），即可判定"移位"是整行移位、字内移位还是别的。**BIOS 补丁要成对改两张表。**
2. 台架补 **VGA 地址记账**（`max_read`/`col_counter`/`vga_lnbytecount`/`vga_ddr_row_col`），
   让 VGA 读扫过整帧（现在台架 VGA 地址恒为 0x34000，只碰一行）。
3. 台架补**真 BIU**（`Next186_BIU_2T_delayread.v`）而非简化握手。
4. 板上查清 `dbg_dbg3 = 0`（期望 `0x00EF`）—— 可能启动根本没走到那个上报点。

---

## 11. 复现命令

```bash
VPY="C:/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe"

# 构建台架
"$VPY" sim/build.py --top ddr_pipe --out sim/run/stage2b \
    cache_controller.v Next186_BlackBoxes.v sim/tb/ddr_pipe.v sim/tb/ddr_selftest_main.cpp

cd sim/run/stage2b
./ddr_pipe.exe 1 0 0 0     # 旧逻辑：mismatched bytes: 960 / 1024  **FAIL**
./ddr_pipe.exe 1 0 0 1     # 95th 修复：mismatched bytes: 0 / 1024  PASS
./ddr_pipe.exe 1 1 0 1     # 带 VGA 争用：同样 0 / 1024  PASS
./ddr_pipe.exe 1 0 2 0 > cyc.log   # tr_on=2 出全周期日志

# 分析
"$VPY" sim/tools/edges.py sim/run/stage2b/cyc.log        # 脉宽 + 每次 burst 发起点的全部信号
"$VPY" sim/tools/win.py  sim/run/stage2b/cyc.log 'AW cmd=10' 30 10 2   # 上下文窗口
"$VPY" sim/tools/bios_table_cmp.py                       # BIOS 双表比对
```
