# 待机波形分析（2026-10-31）

数据：`Network.hw/backup/hw_ila_data_1.ila`
（Vivado 的 `.ila` 其实就是 **ZIP**，里面有 `waveform.csv`；也可以用
`open_hw_manager` + `read_hw_ila_data` + `write_hw_ila_data -csv_file` 导出）
→ 已解出并存档为 `ila_standby_20261031.csv`（1024 拍，采样时钟 clk_sdr = 50 MHz，合计 20.5 µs）。

ILA 是**挂在 AXI 上的 system_ila**（`top_zynq7010_0_m_axi`），采的是 AXI 事务本身，
**不含** `top_zynq7010` 的 FSM 状态寄存器和 `crw`/`sys_cmd_ack`。

## 一、R 通道逐拍（一次突发，233～293 拍）

```
RvvvRvvvRvvvRvvvRvvvRvvvRvvvRvvv
RvvvRvvvRvvvRvvvRvvvRvvvRvvvR
```
`R` = 主机接收（rvalid&rready），`v` = 存储器有数据但主机没接（rvalid=1, rready=0）。

- 接收拍：233, 237, 241, … , 293 —— **间隔恒为 4 拍**
- 区间内 `rvalid=1`：**61 / 61 = 100%**
- 区间内 `rready=1`：**16 / 61 = 26%**

## 二、结论：存储器不是瓶颈，是我们自己在浪费

| 指标 | 实测 |
|---|---|
| rvalid=1（存储器手里有数据） | 29.8% 的全部采样 / **突发内 100%** |
| rvalid=1 但 rready=0（数据在等我们） | **22.0%** |
| rvalid=0 但 rready=1（我们等存储器） | **仅 1.0%** |
| 真正传输 | 7.8% |

- PS DDR 经 HP0 **每拍都能给一个 beat**，可持续 ≈ **200 MB/s**。
- 我们 4 拍才接 1 拍 ⇒ 实际 **50 MB/s**，用了 **25%**。
- 每个缓存行（64 B）跨度 **61 clk_sdr ≈ 1.22 µs ≈ 31 个 CPU 时钟**（CPU 25 MHz）。

## 三、第二个发现：窄模式每个突发只用了前 32 字节

5 次突发的 `araddr`：`0x080d1180 → 11a0 → 11c0 → 11e0`，间隔 **0x20 = 32 字节**，
而每次 `arlen=15` = **64 字节**。

- 5 × 32 B = **160 B = 正好一行文本**（80 列 × 2 字节）
- ⇒ 这些是 **VGA 扫描突发**
- ⇒ 每个 64 字节的突发只消费了前 **32 字节**（`col_counter` 只收 16 个半字），
  后一半被 `!col_counter[4]` 丢掉 —— 这正是 `0257722` 在 **VESA 分支**修掉、
  而**窄模式（文本/13h）还没修**的那个 16 位 SDRAM 遗留。

**合计效率：25%（取数节奏）× 50%（突发内利用率）= 约 12%** 的可用带宽。

## 四、因此修正昨天的工作排序

昨天推荐“先测 → 再 cache 容量 → 再重叠”。测完之后排序应该改成：

1. **让窄模式也吃满整个 burst**（步进 8 → 16 字，`col_counter` 收 32 个半字）——
   收益最大，但**这正是 `dcdfb1a` 当年翻车的地方**：步进翻倍必须连带改
   `vga_lnend`（否则行结束判据提前一半触发 ⇒ 画面全黑）。
   ⇒ 建议先在 `sim/vga_verify` 台架上做，**不要上板盲试**。
2. **握手与半字推送重叠** → 2 拍/beat（现在是 4 拍）。
3. cache 8 KB → 16 KB：排在最后，miss 率不是当前主要矛盾。

## 五、下一捕需要补的探针

当前 ILA 只有 AXI 信号，无法区分“这次突发是 CPU 还是 VGA 发的”。补上再抓一次：
- `crw`（cache 读/写方向）、`sys_cmd_ack`（ddr_186 的命令应答）
- `top_zynq7010` 的 `state[3:0]`（AXI FSM 状态：IDLE/AR_ADDR/R_WAIT/R_PUSH_0/R_PUSH_1）
- 目的：①确认这 5 个突发全是 VGA；②量出 CPU miss 占比；③验证“4 拍 = 1 握手 + 3 推送”的构成。
