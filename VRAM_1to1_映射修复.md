# VRAM 1:1 映射修复 —— 消除 CPU 读显存 0xA0 偏移

- 日期：2026-09-18
- 提交内容：`ddr_186.v:707` 行步进 32B→64B + `cache_controller.v map[11]` 11→6 + `ddr_186.v` VGA 文本基址 `0xE000`→`0x14000`
- 关联报告：`report/9.18_错误原因分析.md`（Mac 工作目录，仅本地参考）

---

## 1. 根因

`ddr_186.v:707` 的 cache 行地址拼接只留 **4 个 0**：

```verilog
sdraddr = {memmap_mux[8:0], cache_hi_addr[9:0], 4'b0000}
```

- `cache_hi_addr = maddr[15:6]`（64 字节/行的"行地址"，LINE=6）。
- 物理地址 `= 0x0800_0000 + ram_addr·2`，`ram_addr=sdraddr`。
- 每个 `cache_hi_addr` 步进（=64 逻辑字节）只让物理地址前进 **32 字节** → cache 看到的 VRAM 被 **2:1 压缩**。
- 奇数行整体读偏 −32B。CPU 经 cache 读逻辑第 5 行（0x0B8140，偏移 +0x140）时，AXI 总线 ARADDR = 0x0805C0A0；而 VGA/PS 走线性 1:1 在 0x0805C000 —— 这就是观测到的 **0xA0 偏移**。

VGA 与 PS 本身没问题（它们走物理线性地址），问题只出在 **CPU 经 cache 的 memmap 与物理 1:1 布局不一致**。

---

## 2. 三处修改（已全部写入仓库）

### ① `ddr_186.v:707`（核心）
```verilog
// 改前
{ memmap_mux[8:0], cache_hi_addr[9:0], 4'b0000 }
// 改后
{ memmap_mux[8:0], cache_hi_addr[9:0], 5'b00000 }
```
效果：行步进 32B → 64B，CPU 与 VGA/PS 的 VRAM 布局变为 1:1。
注：`sdraddr` 本身是 24 位 `reg`（ddr_186.v:205），拼接从 23 位变 24 位，**无截断**。

### ② `cache_controller.v` `map[11]`（段 0x0B 文本窗口重定位）
```verilog
// 改前： map[10]=10, map[11]=11
// 改后： map[10]=10, map[11]=6
reg [8:0]map[0:31] = '{ 0,1,2,3,4,5,6,7,8,9,
                        10, 6,        // ← map[11] 由 11 改为 6
                        18,19,20,21,
                        ...};
```
原因：1:1 后若 `map[11]=11`，文本 VRAM 物理基址 = `0x0800_0000 + 11·65536 + 512·64 = 0x080B8000`，**超出 VGA 可达上限 `0x0807FFFE`**（`vga_ddr_row_col` 仅 17 位）。
选 `6` → 基址 = `0x0800_0000 + 6·65536 + 512·64 = 0x08068000`（窗顶 `0x08078000 ≤ 0x0807FFFE` ✓）。

无冲突说明：段 0x06（`map[6]=6`）与段 0x0B 同指 region 6，但 `maddr[15:6]` 行偏移不同（0x060000→物理 0x08060000，0x0B8000→物理 0x08068000），物理地址不重叠，不会互相踩。

### ③ `ddr_186.v` VGA 文本基址（两处，保证一致）
```verilog
// 行 136：初值
reg [16:0]vga_ddr_row_col = 17'h14000;   // 原 17'h0E000
// 行 736：每帧 line-compare 复位
vga_ddr_row_col <= vgatext[0] ? 17'h14000 : 17'h8000;   // 原 17'he000
```
`0x14000 = (0x08068000 − 0x08040000)/2`，使 VGA 文本帧缓冲物理基址与 CPU/PS 对齐到 **0x08068000**。
（VGA 物理基址公式：`0x08040000 + 2·vga_ddr_row_col`，前缀 `6'b000001` 提供 0x08040000 基。）

---

## 3. 配套改动（需用户在其它位置完成，本次未动 RTL）

| 项 | 原值 | 新值 | 说明 |
|---|---|---|---|
| PS 测试地址 | 0x0805C000 | **0x08068000** | 下载 bit 前写 `AAAAAAAA` 并回读确认的地址 |
| BIOS 文本 `scraddr` | 0x7000 | **0x3000** | 见下方说明，否则 VGA 基址会被每帧覆盖 |

**BIOS `scraddr` 关键提醒**：`ddr_186.v:735` 在每帧结束（`s_vga_endframe`）用 CRT 起始地址寄存器 `scraddr` 重算 `vga_ddr_row_col`：
```verilog
vga_ddr_row_col <= {{1'b0, scraddr[15:13]} + (vgatext[0]?4'b0111:4'b0100), scraddr[12:0]};
```
当前 BIOS 写 `scraddr=0x7000` → 转换得 `0xE000` → 物理 0x0805C000。要落到新基址 0x08068000，需 `scraddr=0x3000`（转换得 `0x14000`）。
**若 BIOS 不改**，每帧结束（line 735）会把 VGA 基址覆盖回 0x0805C000 附近，导致 VGA 与 CPU/PS 再次错位。请检查 BIOS 里设置文本模式 CRT 起始地址的位置。

**图形模式（段 0x0A，`map[10]=18`）**：1:1 后仍落在 0x080E8000（超 VGA 上限），本次未动。如需图形也 1:1，需把 `map[10]` 降到 ≤6 并同步 BIOS/PS，但会引入与段 0x0A 的 region 复用，建议另议。

---

## 4. 验证（Linux Vivado 机）

- ILA 触发条件：`isvwr==1`（`dbg_ctl_isvwr_r`，cache_controller.v:79）。
- 抓取网：`dbg_sdraddr`[23:0]、`dbg_cache_hiaddr`[14:0]（ddr_186.v:840-841）、`m_axi_araddr`（top 端需补 `(* mark_debug="true" *) wire [31:0] dbg_axi_araddr_full = m_axi_araddr;`）。
- **预期**：改前 ARADDR 步进 0x20；改后步进 **0x40**，且逻辑行 N → 物理 `0x08068000 + 64·N`，**0xA0 偏移消失**。
- 功能：PS 写 `0x08068000=AAAAAAAA`，CPU 清屏（isvwr 触发）后该处应为 `0000`；CPU 写文本到 0x0B8000，VGA 应在 0x08068000 显示，ILA 看 ARADDR 与 PS 写入一致。

---

## 5. 本次未处理（留待 1:1 验证通过后再修）

- `cache_controller.v` `lowaddr` 不按行复位（:67,103）—— 一旦 burst 被打断会旋转进错误字。
- `flush` 推进逻辑（:148-157）—— 原作者原始设计，CPU 空闲时仍推进。
- RLAST 提前（之前观测第 11 拍而非第 16 拍）—— 需查清 interconnect/DDR 配置。
- 4-way `tag=511`（:60-64）是 bootstrap 冗余，**非 bug，未改动**。
