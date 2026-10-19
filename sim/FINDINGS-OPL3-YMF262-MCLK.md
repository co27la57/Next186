# FINDINGS：YMF262 换核的时钟结论 —— MCLK 不需要 100 MHz

日期：2026-10-19　提交：`0ea266d`（前置 `19a5356` / `568f6ac`）

## 0. 一句话结论

新 OPL3（nukeykt YMF262 门级模型）的 **MCLK 直接挂原有的 `CLK_50MHZ` 即可**，
出样率、音高、幅度与 100 MHz 时**逐位相同**；而 100 MHz 在 xc7z010-1 上**时序收不住**。
同时查出一个历史错误常数：50 MHz 基相位步进应为 **1229922297**，不是 307474417。

## 1. 为什么一开始要用 100 MHz，以及为什么那是错的

移植时记录的"硬约束"是：`MCLK 必须 ≈100 MHz，50 MHz 时核心内部慢 4 倍（出样 12.5k 而非 49.7k）`。

这个"慢 4 倍"的真相是：**相位累加步进算错了 4 倍**。

```
CLK14 频率 = MCLK × INC / 2^32
  50 MHz, INC=307474417  ->  3.5795 MHz   ← 错，正好是 14.318 的 1/4
  50 MHz, INC=1229922297 -> 14.3182 MHz   ← 对
100 MHz, INC=614948834  -> 14.3180 MHz   ← 对
```

出样率 = `CLK14 / 288`。所以步进小 4 倍 ⇒ CLK 小 4 倍 ⇒ 出样慢 4 倍，
和 MCLK 频率没有关系。**以后凡看到"慢/快整数倍"，先核对相位步进。**

## 2. 机理：核心是「单时钟 + 相位使能」，与 MCLK 频率无关

`ymf262.sv` / `ym_lib.sv` 全部逻辑都在 `always @(posedge MCLK)` 里，
用 `c1` / `c2`（`CLK` 的两个半周期相位，各约 35 ns @14.318 MHz）当**时钟使能**：

```verilog
// ym_lib.sv: ym_sr_bit
always @(posedge MCLK) begin
    if (c1) v1 <= inp;          // c1 窗口内多拍重复装同一值 -> 幂等
    v2 <= c2 ? v1 : v2;         // c2 窗口把 v1 搬进 v2
end
```

`ym_cnt_bit` 的 `inp` 由 `v2` 组合算出，而 `v2` 只在 c2 窗口更新
⇒ **一个 CLK 周期只加一次**，分频比与 MCLK 快多少无关。

约束只有一条：**每个 35 ns 相位窗口里至少要有一个 MCLK 上升沿**（有 2 个更舒服）。
⇒ 下限约 30 MHz（量化极限），50 MHz 时窗口是 20/40 ns 交替，恒 ≥1 沿，
且 `CLK` 由同域相位累加器产生、边沿与 MCLK 对齐 ⇒ 是良性同步关系，无亚稳态风险。

## 3. Vivado 实测（OOC，xc7z010clg400-1，Quick 指令）

| 项目 | 50 MHz 域 | 100 MHz 域 |
|---|---|---|
| WNS | **+6.023 ns** | **−3.988 ns** |
| 违规端点 | 0 | 83 |
| 数据路径 | — | 13.475 ns（logic 4.53 / route 8.95），**15 级逻辑** |

最差路径（100 MHz）：

```
l_vib_cnt(vibrato 计数器) -> fnum_vib 加法(CARRY4 x3) -> l_block/l_multi(barrel shift)
 -> phase_carry(CARRY4 x2) -> 相位 RAM 写口 RAMD32
```

这是真实芯片在**一个 279 ns 慢节拍**里干完的活，模型把它压进了单个 MCLK 周期，
**没有流水化的余地**（拆流水会改变时序语义）。所以只能降 MCLK。

资源：**1043 LUT / 2129 FF / 0 BRAM / 0 DSP**（真实 YMF262 单乘法器时分复用，
比原作者那套「内部 Z80 + opl3.mem 固件 + 256 深命令 FIFO」还省）。

## 4. 四频点扫频实测（逐位相同）

台架：`sim/tb/opl3_ym_probe.v`（wrapper 用层次引用引出 `clk_14m / smpbd / smpac / sy / phase_acc`）
+ `sim/tb/opl3_ym_probe_main.cpp`（直接数选通沿）。

| MCLK | CLK14 | SMPBD | SMPAC | CLK14/采样 | left 峰值 |
|---|---|---|---|---|---|
| 100 MHz | 14.3182 MHz | 49720 Hz | 49720 Hz | 287.98 | −4085..4084 |
| 71.4 MHz | 14.3182 MHz | 49720 Hz | 49720 Hz | 287.98 | −4085..4084 |
| 64.29 MHz | 14.3182 MHz | 49720 Hz | 49720 Hz | 287.98 | −4085..4084 |
| 62.5 MHz | 14.3182 MHz | 49720 Hz | 49720 Hz | 287.98 | −4085..4084 |
| 60 MHz | 14.3182 MHz | 49720 Hz | 49720 Hz | 287.98 | −4085..4084 |
| 56.25 MHz | 14.3182 MHz | 49720 Hz | 49720 Hz | 287.98 | −4085..4084 |
| 50 MHz | 14.3182 MHz | 49720 Hz | 49720 Hz | 287.98 | −4085..4084 |

纯正弦测试音（调制器 TL=0x3F，fnum=0x198，block=4）：
50 MHz 与 100 MHz 都是 **音高 310.00 Hz、反推出样率 49794.5 Hz（+0.16%，在计数粒度内）**。

## 5. 测出样率时的两个计数陷阱（都踩过）

1. **数「left/right 值变化次数」会漏计**：相邻样本数值相同时不计入 → 偏低 5%~9%。
2. **数「过零次数」会高估**：FM 波形的谐波使一个基频周期有 4~8 次过零 → 偏高 300%。

⇒ **只能数采样选通（SMPBD / SMPAC）的上升沿**。判据：`CLK14/SMPBD = 288 ± 0.1`。

## 6. 最终改动

| 文件 | 改动 |
|---|---|
| `dcm.v` | 撤销本次移植才加的 `CLKOUT5`(100 MHz)，MMCM 恢复原配置 |
| `ddr_186.v` | `opl3_ym` 的 `.mclk` 接 `CLK_50MHZ`；`INC_14M=32'd1229922297` |
| `opl3_ym.v` | 默认 `INC_14M=1229922297`；重放节拍参数化 `REP_CYC`（默认 200 拍 = 4 µs @50 MHz） |
| `ymf262.sv` / `ym_lib.sv` | 由 `.v` 改名（Verilog-2001 不支持 `wire xxx[N]` 非压缩数组） |

写通路不变：FIFO + **8 µs/字节**重放（核心写链 `write0_sr→write0_l→write0_l2` 在 µs 级 clk1/clk2 上，
186 的 I/O 周期只有 ~160 ns，直送几乎全丢）。DAC 解码不变：**右移**（核心 LSB-first）。

## 7. Vivado 侧待做

工程里 `ymf262.v` / `ym_lib.v` 路径已失效，在 Tcl Console 跑：

```tcl
source D:/Xilinx/workspace/Next186/Network/fix_sv_sources.tcl
```

它会：移除旧 `.v` → 加入两个 `.sv` 并设 `file_type=SystemVerilog` → 更新编译顺序 → reset `synth_1`。
之后直接 launch 综合/实现/出位流。
