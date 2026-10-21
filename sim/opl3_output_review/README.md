# OPL3 / I²S 输出审查（2026-10-21）

首次审查为代码对照和仿真实验，之后用户已采用第一轮修复：生产 `soundwave.v` 的 I²S 入口现已接饱和补码 PCM。音量默认值、PDM 比较器、OPL 核、FIFO、时钟和 VGA 均未修改。VGA 稳定基线为 `vga-stable-20261021`（`d237a4f`）；审查时 HEAD 为 `2f597a7`。尚待用户重新编译位流并上板试听。

用户确认：音频接三线 I²S；播放时 LED0–3 会闪；完全静音发生在大声播放一段时间之后。功放保护是待验证的解释，不能仅凭症状确诊。

## 优先级 1：I²S 数据格式错误，已用仿真复现

修复前，`soundwave.v` 的 `lmixv/rmixv` 是有符号混音值，但 `lclamp/rclamp` 是给 PDM 比较器使用的偏移二进制码：静音对应 `16'h8000`，负满幅对应 `16'h0000`，正满幅对应 `16'hffff`。

同一组 `lclamp/rclamp` 又直接连接到 `audio_top`。`audio_top.vhd` 的 `SIGNED(...)` 只改变类型，不改变位模式；`dac_if.vhd` 原样串行发送。标准 I²S 使用二进制补码、MSB 优先，因此静音应为 `16'h0000`。

| 输入 / 设置 | 当前串行 I²S 解码 | 仅修格式的实验解码 |
| --- | ---: | ---: |
| 静音 | -32768 | 0 |
| +1000 | -31768 | +1000 |
| -1000 | +31768 | -1000 |
| +1000，衰减 ÷8 | -32643 | +125 |
| +1000，衰减 ÷256 | -32765 | +3 |
| 正向饱和 | -1 | +32767 |
| 负向饱和 | 0 | -32768 |

这说明 `oplvol.com` 即使正确写入衰减，也无法修复编码：小信号仍接近满幅，过零会产生接近满量程的跳变，足以造成严重失真。它与“大声后静音”相容，但是否触发具体模块的保护仍需模块型号、FAULT/供电或模拟输出证据。

已采用的第一轮只改 `soundwave.v`：保留 19 位有符号求和及现有音量运算；新增有符号 16 位饱和 PCM，范围为 -32768..32767；I²S 接 PCM，PDM 仍接偏移码。未改 VGA、DDR 仲裁、MMCM、I²S 分频或 OPL 核。生产差异以 Git 提交为准。

格式修正后可先用 `oplvol 0 3`（OPL 不额外衰减、混音总量 ÷8）验证，再逐步调整。此建议是初始数字增益，不保证任意功放/扬声器负载下的模拟输出范围。当前 RTL 的初始总衰减仍是 0，本轮没有改默认值。

## 与作者仓库的区别

| 部分 | neptuno-fpga 上游 | 当前工程 | 判断 |
| --- | --- | --- | --- |
| OPL 合成 | 命令 FIFO、内部 NextZ80、`opl3.mem`、`opl3seq` | `opl3_ym` 包装 nukeykt YMF262；旧模块未实例化 | 并非只改了音量；先验证输出格式再决定是否做核 A/B |
| I²S 入口 | 偏移码 `lclamp/rclamp` | 同样直接接偏移码 | 上游也存在这一连接；仅回退 OPL 核不会消除它 |
| 混音宽度 | 17 位 | 19 位有符号混音 | 保留当前加宽，避免多音源相加回绕 |
| DSS 音频 FIFO | 32 位 × 4096，非 show-ahead | XPM 包装为 16 位 × 2048 | 接口与容量均不匹配，另行修复 |
| 空 FIFO 样本 | `c000c000`（每声道 -16384） | `00000000`（真正静音） | 保留零；不能靠恢复直流偏置掩盖 I²S 编码错误 |

当前 LED 来自 `ra_keyon[3:0]`，只反映通道开启，不能证明 PCM 非零。旧 OPL 内部调试信号已经被常量替代，不能用于判断新核是否运行。

## 优先级 2：复位与音频 FIFO

1. `opl3_ym.v` 的 `rst` 接入了 YMF262，但命令 FIFO 指针、重放计数、音量寄存器、粘滞标志、串行 DAC 解码状态没有对应按键复位分支。重新下载会重置初值，板上逻辑复位却可能保留旧队列/衰减/样本。建议单独补齐低有效复位，并在复位期间输出零 PCM、保持 I²S 时钟连续。需用复位中断重放、复位前队列非空等用例验证。
2. `Next186_BlackBoxes.v` 的 `sndfifo` 端口和 XPM 宽度均为 16，而 `soundwave.v` 读写的是 32 位立体声包，导致上半部声道丢失。同时 `full >= 2940` 超过当前深度 2048，无法按原设计提前限流。应恢复 32 位接口，并一起核对深度、计数器宽度、读延迟和满阈值。若保留 2048 深度，必须重新计算允许的写入突发余量；不能只机械降低一个阈值。这一路主要影响 DSS/Covox/PCM，不是本次纯 OPL 格式测试的原因。
3. 后续才处理样本跨域/重采样：YMF 出样约 49.716 kHz，混音采样约 43.945 kHz，I²S 约 48.828 kHz；目前多位样本缺少明确的整包握手。它可能影响音质，但暂不能归为静音主因。

不应整体回退 `ddr_186.v`，否则会覆盖已上板验证的 VGA 修复。

## 本轮验证与边界

运行 `python sim/opl3_output_review/run_review.py`。脚本读取生产 `soundwave.v`，在 `run/` 保存原样生产副本和仅将 I²S 重新接回偏移码的负对照，使用 Verilator 编译并通过独立 I²S 串行接收器解码。

- 旧格式负对照：10 项中 10 项不符合补码 PCM 预期，成功复现编码错误。
- 当前生产版本：10 项全部通过，覆盖静音、正负小信号、总衰减、混音饱和和满幅边界。
- 首次实验记录见 `baseline.txt`、`signed_pcm_experiment.txt`；采用后的复验记录见 `baseline_negative_control.txt`、`production.txt`、`summary.json`。
- `output_models.v` 是 `audio_top.vhd` / `dac_if.vhd` 时序的 Verilog 翻译，并将 DSS FIFO 固定为空。本测试不等于原生 VHDL 混合仿真，不验证 DSS FIFO、YMF 内部合成或物理功放，也未模拟跨域亚稳态。

第一轮采用后，若仍大声或静音，再抓新核原始左右样本、衰减值、混音/饱和 PCM、I²S 装载及队列溢出；不再抓旧 Z80 调试常量。探针仍按总数不超过 200 位规划。

## 参考

- [NXP I²S 总线规范，3.1 Serial data](https://www.nxp.com/docs/en/user-manual/UM11732.pdf)：补码、MSB 优先，WS 改变后一位时钟发送下一字 MSB。
- [上游 soundwave.v](https://github.com/neptuno-fpga/Next186_SoC/blob/master/soundwave.v)：偏移码钳位与 I²S 接线。
- [上游 opl3.v](https://github.com/neptuno-fpga/Next186_SoC/blob/master/opl3.v)：原 Z80 / 固件 / sequencer 结构。
- [上游 sndfifo.v](https://github.com/neptuno-fpga/Next186_SoC/blob/master/sndfifo.v)：32 位、4096 深度、show-ahead OFF。
