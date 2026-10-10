# 台架补齐（102nd）：显示使能 + 流控的忠实模型，与 A/B 两候选的验收数据

日期：2026-09-27 17:0x
改动文件：`sim/tb/ddr_pipe.v`、`sim/tb/ddr_selftest_main.cpp`
补丁脚本：`sim/tools/patch_tb_flowmodel.py`（备份 `sim/run/ddr_pipe.v.preFlowModel`、`ddr_selftest_main.cpp.preFlowModel`）

---

## 1. 为什么必须补（POSTMORTEM 里那三条缺口）

100th-A 的"台架验证通过"被作废，因为台架缺三样东西，导致它**结构上不可能**看到那次失效：

| 缺口 | 事实 |
|---|---|
| 没有 `FifoStart` 模型 | `grep FifoStart sim/tb/ddr_pipe.v` → 无匹配。而它直连 `VGA_SG.ce()`，是**显示总开关** |
| 水位从 512 起步 | `reg [9:0] fifo_used = 10'd512;`，不是从空 ⇒ 永不经历"从空爬到 64 才点亮显示" |
| 阈值补丁从未生效 | 注释写 `< (fix_100 ? 32 : 64)`，实际代码一直是 `< 10'd64` |

---

## 2. 补了什么（现在与 `ddr_186.v` 一一对应）

| 项 | 模型 | RTL 出处 |
|---|---|---|
| 水位单位 | **16-bit WRITE words**，511 饱和 | `fifo` 包装的 `wrusedw`（`Next186_BlackBoxes.v`） |
| 复位初值 | **0（空）** | 板上真实行为 |
| 排空 | 只在 `FifoStart` 之后 + 行内可见区（640/800 像素占空）发生；**1 pop = 2 write words**（1 个 32-bit read word） | `vrden` ← `s_displ_on` ← `displ_on = !(hblnk|vblnk|!FifoStart)` |
| 排空速率 | 1 pop / 32 clk_sdr（= 25MHz 下 1 pop / 16 像素，与文本模式一致） | `&hcount_pan[3:0]` 节拍 |
| `s_prog_empty` / `s_prog_full` | `lvl<64` / `lvl>350`，每 clk_sdr 更新 | `ddr_186.v:983/986` |
| **`FifoStart`** | `lvl>=64` 时置位一次，**永不清零**（并记录置位周期） | `ddr_186.v:986-990` |
| 新增观测 | `o_fstart` `o_fstart_cyc` `o_lvl` `o_lvl_min` `o_lvl_max` `o_pe_hi` `o_pe_lo` `o_underr_n` | — |
| `fix_100` 扩为 2 bit | `0`=现状 / `1`=候选A(限流) / `2`=候选B(VGA 4 拍突发) | 只用于台架 A/B |

---

## 3. 判据一：模型是否忠实（用你提供的板上实测当标准）

你实测过：**`s_prog_empty` 大多数时候与 0（FIFO 满），少数时候拉高为 1**。基线必须复现：

```
drain=32(真实): FifoStart=1 @cyc=268  lvl=352  lvl min/max=62/366
                s_prog_empty hi/lo = 10 / 40899        (高占比 0.02%)   ✅ 复现
drain=16(2x快): FifoStart=1 @cyc=268  lvl=352  lvl min/max=58/366
                s_prog_empty hi/lo = 87 / 51430        (高占比 0.17%)   ✅ 复现
```
⇒ **模型的流控行为与板一致**，可以用它判定候选。

同时它有判别力：把排空加快到 4×（drain=8）时**连基线都撑不住**
（`lvl min/max=0/79，underruns=1498，s_prog_empty 高占比 94.7%`）—— 说明"饿死"这种失效它**测得出来**。

---

## 4. 判据二：字符流单调性（"每 8 字符重复"的直接判据）

台架记录 FIFO 实际接受的半字流（`ACC[n]`，`tr_on=3`）：

```
现状 fix=0 : a000 … a007   a004 … a007   a008 … a00b   a008 …      ← 索引回退 ⇒ 重叠 ⇒ 重复
候选A fix=1: a000 a001 a002 … a00f a010 a011 a012 a013 …            ← 严格单调 ✅
候选B fix=2: a000 a001 a002 … a00f a010 a011 a012 a013 …            ← 严格单调 ✅
```
⇒ **bug 在台架里被复现，两个候选都能在"数据流"层面修掉它。**

---

## 5. 判据三：流控余量（这才是分水岭）

`s_prog_empty` 的高占空比就是"FIFO 被钉在门限下、VGA 永远抢优先级、CPU 一起饿死"的度量：

| drain（相对真实 VGA） | 现状 | **候选 A** | **候选 B** |
|---|---|---|---|
| 32（1×，真实） | 62~366 / 0.02% | 60~358 / 0.14% | 60~364 / 0.14% |
| **16（2×）** | 58~366 / **0.17%** | **31~84 / 84.5%** ❌ | 54~358 / **10.7%** ✅ |
| 8（4×，连基线都崩） | 0~79 / 94.7% | — | — |

**结论：A 把水位余量打掉约 4 倍（峰值从 366 掉到 84），在 2× 排空下直接崩掉；B 基本保留余量。**

**为什么 A 会崩**：A 发的是 **16 拍 burst 却只收下 8 个半字**，等于每个有用半字要付
**4 倍的总线时间**（64 字节取回、16 字节有用）⇒ FSM 回填速度跟不上 ⇒ 水位钉在门限下
⇒ `s_prog_empty` 长期为 1。这正是它在板上"显示直接没了"的机理 —— **而且是纯 AXI 侧的机理**：
不是 FIFO 逻辑错，是**总线带宽被浪费掉 3/4**。

**B 为什么对**：只取 4 拍 = 16 字节 = 8 个半字 = `max_read+1`，正好是作者记账的量
⇒ **取回 = 接受 = 推进**，总线按需付费，余量不变。

---

> ⚠ **本节（§6，4 拍版本）已作废**：对照原版代码后确认，问题不是"突发太长"，而是**移植时 `sdraddr`
> 单位从 4 字节改成 2 字节、作者 VGA 常量没换算**。4 拍版本只是把交付量降到与"错误步进"配平，
> 字符行几何（160 字节/行、192 字节/扫描行）仍然不对。正确修法是 **104th**：
> 见 `sim/FINDINGS-104th-VGA地址单位换算.md`（步进 32 字节 + 行步进 160 字节 + `vga_lnend=12`
> + VGA 读 8 拍）。下面内容保留作过程记录。

## 6. B 的 RTL 落点（一行，**已应用**：2026-09-27 17:06）

`top_zynq7010.v:311`（就在 IDLE 采样里 `if (ram_cmd == 2'b10 || ram_cmd == 2'b11)` 分支内）：

```diff
-  main_arlen <= 8'd15;
+  main_arlen <= (ram_cmd == 2'b10) ? 8'd3 : 8'd15;   // VGA 读 4 拍；cache 填充仍 16 拍
```
脚本：`sim/tools/patch_top_zynq7010_vga4beat.py`（`--revert` 可退，备份 `sim/run/top_zynq7010.v.preVga4Beat`）。

**已应用并校验（17:06）**：`top_zynq7010.v` CRLF 0 / bareLF 458（原本就是 LF，未破坏）、
begin/end 38/38、Verilator lint **0 个真实 error**（其余为 Vivado 原语/VHDL 的 MODMISSING，属基线）。
台架复核：`fix=0` PASS（`lvl 62~366, pe高 10/40899`）；`fix=2` PASS（`lvl 60~364, pe高 53/37870, underruns=0`）。
`ram_cmd==2'b10` = VGA 读（只取 4 拍），`2'b11` = cache 填充（保持 16 拍 = 64B 一整行），`2'b01` = 写回（AWLEN 未动）。

残余（不阻塞）：作者侧 `max_read` 在跨 256 半字边界时被夹小，那时步进 <8 而 B 固定取 8
⇒ 该笔会多带几个半字（局部重叠）。一帧地址记账扫描里该夹取出现 0/2880 次；
若将来出现，正确做法是把 `max_read` 引出，令 `arlen = max_read>>1`（同属 AXI 接口改动）。

---

## 7. 复跑命令

```bash
VPY="C:/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe"
"$VPY" sim/build.py --top ddr_pipe --out sim/run/stage2b cache_controller.v Next186_BlackBoxes.v \
      sim/tb/ddr_pipe.v sim/tb/ddr_selftest_main.cpp
cd sim/run/stage2b
# 参数: gate_fill vga_model tr_on fix_re sdr_per_cpu cpu_phase frame_period vblnk_len \
#       fifo_drain cpu_gap vga_lnend vga_stride vga_lcr inject fix_96 fix_97 fix_100
./ddr_pipe.exe 1 1 0 1 2 1 0 3 32 0 6 40 400 0 0 0 0   # 现状
./ddr_pipe.exe 1 1 0 1 2 1 0 3 32 0 6 40 400 0 0 0 2   # 候选 B
./ddr_pipe.exe 1 1 0 1 2 1 0 3 16 0 6 40 400 0 0 0 1   # 候选 A 的崩溃现场
```
