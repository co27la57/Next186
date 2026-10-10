# stage-2b 台架：用法、可扫参数、判据

> 2026-09-26。台架 = **真 `cache_controller.v` + `ddr_186.v` 的命令流水复刻 + `top_zynq7010.v` 的 AXI FSM 复刻**
> + AXI 从机内存模型 + VGA 记账 + VGA FIFO 占用模型 + 每帧 `auto_flush` 模型。

---

## 1. 构建与运行

```bash
VPY="C:/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe"

"$VPY" sim/build.py --top ddr_pipe --out sim/run/stage2b \
    cache_controller.v Next186_BlackBoxes.v sim/tb/ddr_pipe.v sim/tb/ddr_selftest_main.cpp

cd sim/run/stage2b
./ddr_pipe.exe 1 0 0 1 2 1 0 3 4 0 6 40 400     # 真机配置
```

## 2. 参数表（按位置）

| # | 参数 | 真机值 | 说明 |
|---|---|---|---|
| 1 | `gate_fill` | **1** | 1 = 91st 修复（真机 RTL 已有）；0 = 对照 |
| 2 | `vga_model` | 0 | 1 = 旧的"饿死脉冲"模型（`s_prog_empty` 手打） |
| 3 | `tr_on` | 0 | 1 = 事务日志；**2 = 逐拍全周期日志**（排查必备） |
| 4 | `fix_re` | **1** | 1 = 95th 修复（真机 RTL 已有）；0 = 旧逻辑（对照） |
| 5 | `sdr_per_cpu` | **2** | clk_sdr : clk_cpu（`CLK_50MHZ` : MMCM 25 MHz）|
| 6 | `cpu_phase` | 0..2*sdr_per_cpu-1 | clk_cpu 沿落在哪个 clk_sdr 半周期（相位自由，要扫）|
| 7 | `frame_period` | 416667 | 每帧 clk_cpu 周期（60 Hz @25 MHz）；0 = 不触发 flush |
| 8 | `vblnk_len` | ~1 万 | vblnk 高电平的 clk_cpu 周期数 |
| 9 | `fifo_drain` | **4** | VGA FIFO 排水周期（clk_sdr）；**0 = 不用真 FIFO 模型** |
| 10 | `cpu_gap` | 0 | 每次 CPU 总线周期后插的空闲 clk_cpu 数 |
| 11 | `vga_lnend` | **6** | `ddr_186.v:176` 文本模式值 |
| 12 | `vga_stride` | **40** | 每个字符行推进的字数 |
| 13 | `vga_lcr` | 400 | `vga_ddr_row_col` 回绕的扫描行 |

## 3. 判据（**必须用逐字节读回**）

```
---- 1 KB read-back AFTER scan256 (all 1024 bytes) ----
mismatched bytes: 0 / 1024   PASS
```
**只读 0x80 没有判别力**（"word0 重复"这类损坏恰好让它读到 0x20）。同时看：
- `buffer lines mismatching in DDR: n / 16` —— **DDR 里到底对不对**（区分写侧/读侧的关键！）
- `AXI bursts: AW=.. (spurious=..)   AR(cmd=11)=.. (spurious=..)`
- `ack-edge spurious bursts (the board probe): WB=.. RD=..` —— 与板上 `dbg_spur_wb_n/rd_n` 同口径
- `VGA sweep: bursts=.. last row-col base=.. s_prog_empty cycles=.. s_prog_full cycles=..`

## 4. 扫描驱动 `sim/tools/sweep.py`

```bash
"$VPY" sim/tools/sweep.py --fifo_drain 4,6,8,12,20 --vga_lnend 6,11,21 --only_fail
"$VPY" sim/tools/sweep.py --sdr_per_cpu 2,4 --cpu_phase 0-7 --fifo_drain 4-20
"$VPY" sim/tools/sweep.py --frame_period 0,2000-12000 --only_fail
```
支持 `--<参数> a,b,c` 或 `a-b`（闭区间）；`fix_re` 默认跑 `0,1` 两遍。
输出紧凑表：`mis / ddr / spurWB / spurRD / pe / pf / vgaB`，`--only_fail` 只列失败。

## 5. 已知结论（别重复问）

| 配置 | 结果 |
|---|---|
| `2:1`（真机比例）任何相位 / drain / gap | **全 PASS**（含 `fix_re=0`）⇒ **95th 竞态在真机比例下不触发** |
| `4:1` + 常量 VGA 地址（`fifo_drain=0`） | `fix=0` FAIL 900~960/1024；`fix=1` PASS |
| `4:1` + 真 FIFO（`drain=8`） | `fix=0` FAIL，且 **`ddr=0/16`（DDR 完好）+ 读回错** ⇒ **"读侧"损坏** |
| `4:1` + 真 FIFO + `fix=1`（phase 2..6 × drain 6..16） | **全 PASS** |

**★ 台架已能产出"读侧"损坏**（`4:1/phase=5/drain=8/fix=0` → `mis=384, ddr=0, spurRD=36, spurWB=0`），
机制 = 伪填充 burst 把别的行的数据写进 cache ⇒ **DDR 不动、CPU 读错**。与板上症状同一类。

**⚠ FIFO 节奏是一阶旋钮**：加真实 FIFO 后某些配置（如 4:1/drain=4）连 95th 竞态都不触发。
⇒ 旧台架（常量 VGA 地址、FSM 从不 idle）**比真机更容易触发竞态**，早期结论要打折。

## 6. 仍未复现

板上那个 **确定性 +4 行（0x100 字节）位移**在 fix=1 下**任何配置都没复现**。
⇒ 台架目前只能**验证候选修复**，不能**找**这个 bug。下板 v3 探针（`5362c54`）是当前主路径。
