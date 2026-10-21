# VGA 帧首/行收支验证（2026-10-21）

仿真基线为 `3f73b44`（撤销 `dcdfb1a`），两个生产 RTL 文件与 `111904f` 内容相同。用户于 2026-10-21 确认采用后，补丁已应用到生产 `ddr_186.v` 和 `Next186_BlackBoxes.v`，并重新通过 lint；没有综合或下板。

## 已验证的结论

1. **有效数据没有常态 2× 地址重叠。** `ram_addr` 的单位是 16 位半字，桥接器再乘 2 生成 AXI 字节地址。通常每笔 AXI 返回 32 半字，`col_counter=15` 让 FIFO 接受前 16、丢弃后 16。下一笔地址增加 16 半字，进入 FIFO 的数据连续。WorkBuddy 旧模型把地址右移 1、只返回 16 半字，因而得出了“8 字符重复”的结果。
2. **当前 vblank 复位没有形成事务边界。** 复位窗口中仍有读命令和返回，FIFO 的 XPM 复位忙还会延续到窗口结束之后。取指计数已经推进，部分返回却没有入 FIFO，或旧事务的尾部落入新帧。随机延迟下，原版文本帧首源地址出现 `0x5BFF0/0x5BFF2/0x5BFF4` 等变化；这复现了地址漂移，尚不能当作对板上 FS 水位 `352/336/320` 的逐值复现。
3. **`-8` 在正确帧同步下成为越界前缀。** 固定事务边界后保留 `-8` 会从文本基址之前 16 个半字开始；取消它后，第一个可见字符对应 `0x5C000`，图形第一笔对应 `0x50000`。这次有源地址和可见字符断言支持，不能把这个结论脱离完整帧同步改动单独使用。
4. **47 次读确实导致行内漂移，但并非持续积压直至 FIFO 满。** 当前原始 RTL 的稳定文本行在本台架计得 48 次 32 位请求；强制漏掉最后一次后为 47 次，水位会每行加 2，随后水位限流使部分显示行只写 80 半字，水位仍在约 352～366 范围，实测模型无 overflow。取指行与显示行的相位依然错开。硬件 47 次的来源还需核对原始 ILA 的完整行窗口，不能用强制注入证明硬件的漏读原因。
5. **另有短接受窗口回绕。** `max_read<7` 时，固定 32 半字返回会让 5 位 `col_counter` 从负区间绕回正区间，重新接纳尾部。`scraddr=5` 可复现；停止对已结束的计数继续递减后通过。

## 已采用的最小补丁

文件：[vga_frame_alignment.patch](vga_frame_alignment.patch)。生产副本在 `candidate/`，生成器为 `prepare_candidate.py`。补丁已获用户确认并应用；生成器始终从固定 `111904f` 基线重新生成，不覆盖工作区生产文件。

| 改动 | 作用 |
|---|---|
| 帧同步改为 RUN → DRAIN → RESET → READY | vblank 后在最终 `ram_cmd` 输出阻止新命令；等待旧 ACK/返回结束，保持 FIFO 复位 64 个 clk_sdr，等待 XPM `wr_rst_busy` 解除后才发新请求。空闲判断不包含 `crw`。在途 cache 返回仍由原 cache 通路处理。 |
| FIFO 包装导出 `reset_busy`；重同步清完整行状态并在消隐期间对齐显示模式 | 避免复位忙时把新帧首数据丢掉，并保证行计数、重复计数和基址属于同一帧。XPM 写侧 busy 包含读域复位往返握手，无需直接跨域采样 `rd_rst_busy`。 |
| 帧首地址取消 `-8` | 真正从 VRAM 起点开始。保留原作者单位、地址最低位和每笔推进量。 |
| 每行读请求显式计数：文本 48 / 13h 和 planar 88 / 其他 168 | 消隐前补足该行配额，避免单次尾部漏读形成逐行相位偏移。注入漏掉原最后一次时，文本在 h=784 补读，仍在水平消隐内。正常文本读请求仍为 h=16～768。此计数不处理空 FIFO 时的数据恢复。 |
| `col_counter` 到结束区间即停止递减 | 防止短接受窗口在长返回事务中绕回，吸收错误尾部。 |

没有改变 `VGA_SG`、像素时钟、HS/VS 常量、640×480 输出选择或 AXI 事务长度。`top_zynq7010.v` 不在补丁中。仿真旋钮 64 的短 AXI 对照实验未纳入补丁。

## 台架范围与判据

以 WorkBuddy 的 `sim/vga_path` 快照 `baseline_vga_path.v` 为输入，在生成副本中修正地址单位、完整 AXI 返回节拍、cache 一次性请求/呈现逻辑、FIFO 深度和 DAC 一拍同步延迟。快照、时序和字体模型均保存在本目录，重跑不依赖未跟踪的 WorkBuddy 目录。FIFO 使用本机 Vivado 2025.2 的真实 XPM RTL，参数与生产一致（1024 个半字，水位输出饱和到 511）。`ONESPIN` 宏仅避开仿真全局 GSR 引用；台架显式保持初始化复位。事件调度处理 XPM 的定时事件。

独立队列按**实际接受的 FIFO 写与读**记录完整源地址，并检查 XPM 输出；每行可见数据源地址与坐标独立计算；文本还检查字体/调色板流水后的可见字符源地址。空白测试把文本区域清零、周围填 `0xFFFF`，直接检查可见 RGB 全黑。图形验证检查数据源顺序，调色板颜色仅为简化显示，没有启动真实 BIOS/游戏或验证整机 CPU 指令执行。

cache 压力使用生产的请求呈现逻辑和人工 cache 读事务；没有覆盖真实 cache 写回/CPU 全部流量。最初两帧作为初始化/模式切换过渡，不纳入稳定帧判据。候选与基线均使用相同判据，基线失败不会被算成修复成功。

## 最终回归

结果见 `results/summary.json` 和 `results/analysis.txt`。本机每例完整日志为同目录 `.txt`，这些生成日志不纳入提交。

- 10 项最小候选回归通过：文本、文本区清零、尾部漏读注入、非零起点、滚屏页起点、水平 pan=7、13h、13h 非零起点、planar、另一随机种子。每例 7～9 帧，包含随机 DDR 延迟和 cache 读争用；稳定帧地址错误、文本字符位置错误、配额错误、overflow、underflow 和 FIFO 数据核对错误均为 0。
- 5 项缺陷复现按预期失败：基线文本、空白区垃圾、漏读、短计数回绕、仅修帧首但保留漏读。空白测试原版出现彩色像素，候选为 0。
- 1 项过载测试按预期失败：保留 16 拍 AXI、增加随机延迟至 15 拍并叠加 cache 争用，仍有活动区欠载；没有把 FIFO 空读当作通过。
- 1 项独立短 AXI 实验通过，作为后续带宽优化证据，未混入当前最小补丁。

“17/17 regression expectations met”包含预期失败，不表示所有压力情形已经修复。现阶段结论为**候选通过限定范围的仿真，尚未上板证实**。

`candidate/lint.txt` 是候选生产副本的 Verilator lint（exit=0），`baseline_lint.txt` 是同参数基线。既有隐式网线、CPU 组合环等警告仍在。未解析的厂商黑盒允许省略；此 lint 不是 Vivado 综合或时序签核。采用后，生产文件与候选逐行核对一致（仅清理一处尾随空白），`results/applied_lint.txt` 记录应用后的 lint（exit=0）。

## 重跑

从 imports 目录使用已安装的 Python：

```powershell
& 'C:/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe' sim/vga_verify/build_verify.py
& 'C:/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe' sim/vga_verify/run_regression.py
& 'C:/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe' sim/vga_verify/prepare_candidate.py
```

编译器需要读取已安装的 Zig 标准库。部分沙箱会阻止编译器打开该目录，需要允许该构建读取工具链。

仿真参数为 `flags seed max_stall frames mode cache_period pan blank scraddr vde capture`。最小候选 flags=55；63 额外注入漏读；0 为审计后的原逻辑。`results/flush_wave.csv` 是一次候选重同步的逐拍软件波形，可用 `analyze_results.py` 查看复位与首笔写入顺序。

按用户先审核每处改动方案的约定，先完成仿真和候选 lint，收到“采用”后才覆盖生产文件。当前只完成代码采用与静态检查，仍需后续综合、时序检查和上板确认。
