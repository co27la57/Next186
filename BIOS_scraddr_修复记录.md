# BIOS scraddr（CRT 起始地址）修复记录 —— 让硬编码 BIOS 的 VGA 文本窗与 CPU 对齐

- 日期：2026-09-18
- 改动文件：`Next186_BlackBoxes.v`（cache 模块 `initial begin` 块内硬编码 BIOS）
- 关联修复：`f2bd81b`（1:1 映射）、`ee3e674`（cache 整行填充）
- 关联文档：`VRAM_1to1_映射修复.md`（第 2/3 节）、本地 `BIOS_反汇编.md`

---

> ⚠️ **勘误（2026-09-18，commit 47cc561）**：本文档“scraddr=0x3000 → `0x08068000` 三者一致”的结论**不成立**。
> - 正确 VGA 物理基址公式 = `0x08080000 + 2·vga_ddr_row_col`（前缀 `6'b000001` 提供 `0x08080000` 基，非 0x08040000）。
> - 故 scraddr=0x3000 实际得 row_col=`0x11000` → 物理 `0x080A2000`，与当时 CPU 文本窗 `0x08068000` 仍错位 `0x3A000`——这正是花屏/乱码根因。
> - 最终对齐：commit 47cc561 把 `map[11]` 改 `10`（CPU 文本窗→`0x080A8000`）并把 BIOS `scraddr` 进一步改 `0x6000`（`ram[11'h03A]` `32'h4AEE60B0`，mov al,0x30→0x60）→ row_col=`0x14000` → 物理 `0x080A8000`，与 CPU 文本窗严格相等。文本基址已变 **`0x080A8000`**。详见 **`VGA_读地址对齐修复.md`**。

## 0. 一句话结论（原始改动，已被 47cc561 进一步修正）

把**硬编码在 `Next186_BlackBoxes.v` cache 模块 `initial begin` 内的 1KB BIOS** 中，VGA 初始化段写 CRT 起始地址寄存器（Start Address High，0x0C）的立即数由 `0x00` 改为 `0x30`（即 scraddr `0x0000 → 0x3000`），意图让 VGA 文本帧缓冲物理基址 = `0x08068000`，与 CPU 经 cache 的文本窗口（`map[11]=6`）及 DDR 文本基址初值（`0x14000`）一致。⚠️ 但该意图因 VGA 基址公式算错而未真正实现（见上方勘误），最终由 commit 47cc561 用 `map[11]=10` + `scraddr=0x6000` 完成对齐。

> 注：**没有改 `bios.mem`**。经核查，真正的启动 BIOS 源是 BlackBox 的硬编码 RAM，全仓库无任何 RTL 引用 `bios.mem`。

---

## 1. 改了什么（代码层面）

文件：`Next186_BlackBoxes.v`，`initial begin` 块（cache 模块，行 207 起），BIOS 偏移 `0x0E8` 处。

```verilog
// 改前
ram[11'h03A] = 32'h4AEE00B0;
// 改后
ram[11'h03A] = 32'h4AEE30B0;   // scraddr 高字节 0x00->0x30 (CRT 起始地址高, 改自 bios 偏移0xE9的 mov al,0x00->mov al,0x30)
```

字节级（32 位小端）：

- `4AEE00B0` = 字节 `B0 00 EE 4A` → 偏移 `0xE8=B0`、`0xE9=00`（原：高字节 0x00）
- `4AEE30B0` = 字节 `B0 30 EE 4A` → 偏移 `0xE9=30`（改后：高字节 0x30）

反汇编对应（`BIOS_反汇编.md:127-128`）：

```
00E8  B0 00        mov al, 0          ; 写 CRT 寄存器 0x0C（Start Address High）
00EA  EE           out dx, al         ; dx=0x3D5
```

这是 `mov al,0x00; out 0x3D5,al`，写的是 VGA CRT 控制器 **Start Address High（寄存器 0x0C）**。该寄存器值与后续的 Low（寄存器 0x0D，偏移 `0x0F0`）拼成 16 位 `scraddr`，在 `ddr_186.v` 中被取作 `scraddr`。

---

## 2. 为什么必须改（根因）

- 板子开机**只从 BlackBox 硬编码 BIOS 取 1KB**，不依赖 SD 卡或外部 BIOS。BIOS 在 VGA 初始化时通过 `0x3D4/0x3D5` 写 CRT Start Address（scraddr）。
- `ddr_186.v:735` 在每帧结束（`s_vga_endframe`）用 `scraddr` 重算 VGA 的 DDR 基址 `vga_ddr_row_col`：

```verilog
vga_ddr_row_col <= {{1'b0, scraddr[15:13]} + (vgatext[0]?4'b0111:4'b0100), scraddr[12:0]};
```

  - 原 `scraddr=0x0000` → `vga_ddr_row_col = 0x7000` → 物理 `0x0804E000`
  - CPU 文本窗（`map[11]=6`，commit `f2bd81b`）物理基址 `0x08068000`
  - 二者错位 `0x1A000`：VGA 实际读 `0x0804E000` 区，CPU 写 `0x08068000` 区 → 屏上要么黑屏 / 错位 / 帧边界抖动

- 改 `scraddr=0x3000` → `vga_ddr_row_col = 0x14000` → 物理 `0x08068000`，与 **CPU 文本窗** 及 **DDR 文本基址初值（line 736 复位值 `0x14000`）三者严格相等** → VGA 稳定显示 CPU 写的文本。

（VGA 物理基址公式：`0x08040000 + 2·vga_ddr_row_col`。）

---

## 3. 为什么改在 BlackBox，而不是 `bios.mem`（重要纠错）

- 之前的 commit `5d27c32` **误把补丁写到了仓库根 `bios.mem`**。
- 但经核查，`Next186_BlackBoxes.v` 的 `initial begin`（行 207）是**显式逐字 `ram[11'h0XX] = ...` 赋值**；全仓库 `grep` 无任何 `$readmemh(bios.mem)` 或 RTL 引用 `bios.mem`。
- 即：CPU 启动真正读取的 BIOS 来自 **BlackBox 的硬编码 RAM**，`bios.mem` 在 RTL 启动路径上**完全未被引用**。改 `bios.mem` 对运行结果零影响。
- 用户明确纠正后，已做两件事：
  1. 在 `Next186_BlackBoxes.v` 落补丁（见第 1 节）；
  2. `git checkout d4d929e -- bios.mem` 撤销 `5d27c32` 对 `bios.mem` 的改动（`bios.mem` 回到 `4AEE00B0` 原值，低字节 0x00 保持）。

---

## 4. 不该动的地方（已确认非 bug）

- 4-way `tag=511`（`cache_controller.v:60-64`）：原版 bootstrap 冗余，**未改**。
- `flush` 推进逻辑（`:148-157`）：原作者设计，CPU 空闲时仍推进，**暂未动**。
- `0x044` `BB 40 00 3A`、`0x069` `40E4FAEB`：本会话早先已在 BlackBox 内的既有修改痕迹，保持原样。

---

## 5. 验证

- 反汇编确认 `0x0E8: B0 30`（原 `B0 00`）；`0x0F0`（Cursor Location Low，寄存器 0x0D 数据）保持 `B0 00` → `scraddr` 高字节 `0x30`、低字节 `0x00` = **`0x3000`**。
- "Searching BIOS on SDCard"（串 `0x2C3`）/ "BIOS not found, waiting on RS232"（串 `0x2FD`）位于 `0x2C3 / 0x2FD`，远离 `0x0E9`，**未被本次改动影响，完好**。
- 期望现象：板子开机无 SD 卡 → 屏显 "BIOS not found, waiting on RS232 ..." 文本，且文字**稳定不抖动**（VGA 基址对齐 `0x08068000`）。

---

## 6. 提交与同步

- 本次提交：仅改 `Next186_BlackBoxes.v`；`bios.mem` 回退到原值（撤销 `5d27c32` 的误改）。
- Ubuntu（Vivado）机：SSH `git pull origin main` 后，**把 `Next186_BlackBoxes.v` 同名覆盖进 `sources_1`**（`.v` 覆盖，不动 `.xdc/.bd/.xci`），Vivado `Refresh All` → 综合 → 下板。
- ILA 复测可沿用 `VRAM_1to1_映射修复.md` 第 4/6.3 节（触发 `isvwr==1`，看 `dbg_sdraddr` / `m_axi_araddr` 步进 `0x40`，以及 VGA 文本稳定显示）。
