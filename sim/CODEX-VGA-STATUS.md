# VGA 相位问题 — 情况说明（给 Codex，2026-10-12 晚）

> 独立简报，无需读其他文件即可接手。完整推导见同目录 `FINDINGS-153rd-VGA显示相位=FIFO水位.md`。

## 1. 项目与当前代码状态

- Next186 SoC，EBAZ4205 (Zynq-7010, xc7z010clg400-1)，Vivado 2025.2。
- GitHub 仓库 = 内层 repo：`D:\Xilinx\workspace\Next186\Network\Network.srcs\sources_1\imports\`
  （remote `origin` = `ssh://git@ssh.github.com:443/co27la57/Next186.git`，本地 SSH 直连可用）。
- **当前 HEAD = `986aa70`（已推送）**：153rd / 153rd-B 两次 VGA 修复**均已回退**，
  VGA 行为回到最初状态。鼠标注入 / OPL3 / 键盘等其他工作完好保留。

## 2. 问题（一句话）

VGA 显示侧与取指侧之间只有一个异步 FIFO、没有帧/行级同步，导致**屏幕显示的内容整体错位且随 DDR 竞争漂移**。

## 3. 根因（已定性，定量）

```
Δ = L − c'      L = 显示帧起点那一刻的 FIFO 水位（读字）,  c' = 取指侧行相位
屏幕第 k 行显示帧缓冲第 k+Δ 行
```

- 架构：显示侧 clk_25（`vrden` 文本每 16 像素 / 13h 每 8 像素弹一个 32bit 读字）；
  取指侧 clk_sdr=50MHz（`vga_ddr_row_col`/`vga_lnbytecount`/`vga_repln_count` → `sdraddr`，AXI burst）。
  两者间只有 `xpm_fifo_async`（16bit 写 / 32bit 读，写深 1024 半字）。
- 行长：文本每扫描行 48 读字；13h 每扫描行 88 读字。
- 症状 ↔ Δ：
  - 文本 Δ=3 个拷贝 ⇒ 每行顶部 3 排像素是相邻行字符 ⇒ "第一行顶部缺 3 排像素"；
  - 13h Δ mod 88 ≠ 0 ⇒ **整行左移 4Δ 列（照片实测 50~90 列 / 共 320 列）+ 行内竖缝（约在 72% 宽度处，缝右侧是该行开头=回绕）**；
  - 水位随 DDR 竞争漂 ⇒ 乱跳/闪烁；暂停后 CPU 不写显存 ⇒ 水位稳 ⇒ 画面稳（但仍有固定错位）。

## 4. 已试过的两次修复与上板结果（都失败，已回退）

| 提交 | 内容 | 上板结果 |
|---|---|---|
| `de565d0` | 153rd：`top_zynq7010.v` VGA 读 AXI 改 8 拍（`main_arlen <= (ram_cmd==2'b10) ? 8'd7 : 8'd15;`，数据等价、省一半 DDR 流量） | 画面重复消失，只剩约 1/16 水平滚动；暂停仍轻微乱跳 ⇒ 水位漂被压制但"映射随水位变"仍在 |
| `312c400` | 153rd-B：`ddr_186.v` 每帧 vblank（`vcount==482`）相位重同步——窗口内关 FIFO 写 + 异步复位指针 + 清零取指行相位 | **图形模式水平方向剧烈抖动，比回退前更糟** ⇒ 回退 |

两次提交都还在远端历史里，可 `git show` 取回细节。

## 5. 当前（回退后）代码里 VGA 相关的关键位置

- `ddr_186.v`：`xpm_fifo_async` 实例（FIFO 本体）、`col_counter`（每 VGA 事务只收 16 半字=32B=8 拍，
  第 17 个半字把 `wrreq` 关掉）、行推进块（`s_vga_endscanline` / `vga_repln_count` / `vga_lnbytecount`）、
  地址式 `{5'b00001, vga_ddr_row_col + vga_lnbytecount - 5'd8, 1'b0}`（**注意：`-5'd8` 是回退后的原值**）。
- `top_zynq7010.v`：`main_arlen <= 8'd15;`（无条件 16 拍，已回退）。

## 6. 历史盲区（别再走）

121/122/129/130/146/149/152 全在调 `-8/-448/-488` 常量与 `vcount==0` 复位——
相位本身不固定（水位漂 + 复位竞态），永远标不定。

## 7. 给下一步的线索（按推荐顺序）

1. **显示侧等 FIFO**（最稳方向）：`vrden` 门控加水位判据（如 FIFO 读数低于半行即插入等待），
   把"显示受 FIFO 约束"这条本来就存在的隐性依赖变成显式的——而不是在取指侧重置。
2. 153rd-B 失败的一种解释：vblank 内 CPU 仍在抢 DDR ⇒ 帧首预取不足 ⇒ 重同步把错误起点也钉住了。
   若要再试重同步，先确认 vblank 内 DDR 仲裁能让 VGA 预取跑完第一行。
3. 8 拍实验说明：改 AXI burst 长度会改变水位行为 ⇒ "水位"不只是余量，读写两侧**速率耦合**本身就是相位来源。
4. 需要上板数据时，ILA 探针建议（上限 200 bit）：`fifo_wr_used_words` + 帧起点标记
   （判据：帧起点那一刻的水位逐帧恒定 ±16），或帧起点锁存 `vga_repln_count`/`vga_lnbytecount` 直接读 Δ。

## 8. 协作约定

- 只改 RTL 源文件；ILA 配置 + Generate Bitstream + 烧录由用户在 Vivado GUI 做（别跑 `build_ila.tcl` 等全流程脚本，会争用 run 文件）。
- Vivado 先 `set_param general.maxThreads 8`；`STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Quick`（否则 Global Iteration 死循环）。
- 改完 RTL 必做 Verilator 单文件 lint（命令见 `HANDOFF-Next186-VGA.md` §6，在工作区根目录）。
- 用户中文交流；要结论 + 具体代码改动 + 回退路径；用户带截图/照片报现象，照片信息量极大（这次 Δ 和左移方向就是靠照片定量推出的）。
