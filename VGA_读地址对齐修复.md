# VGA 读地址对齐修复 —— 消除花屏+乱码（VGA 读到脏数据）

- 日期：2026-09-18
- 提交：`cache_controller.v`（`map[11]` 6→10）+ `Next186_BlackBoxes.v`（BIOS `scraddr` 0x3000→0x6000）
- 关联问题：下板后 VGA 文本屏花屏 + 乱码（VGA 读到的是 DDR 里与 CPU 文本窗不同的区域，全是脏/旧数据）。
- 关联报告：`report/9.18_错误原因分析.md`（Mac 工作目录，仅本地参考）

---

## 1. 根因

VGA 文本屏要正常显示，必须满足：**CPU 写文本的物理地址 == VGA 读文本的物理地址**。二者由两套独立机制决定，之前只改了其中一套。

### 1.1 地址映射事实（已逐级核到顶层）

顶层 `top_zynq7010.v:244/250`：
```
m_axi_*addr = 32'h0800_0000 + {7'b0, ram_addr, 1'b0}   // 物理 = 0x08000000 + ram_addr·2
```

- **CPU 文本窗**（`cache_controller.v` `seg_map` 的 `map[11]`，段 0x0B8000）：
  `ram_addr = (map[11]<<15) + (maddr[15:6]<<5)`
  改前 `map[11]=6` → `ram_addr = 0x34000` → 物理 **0x08068000**。
- **VGA 读路径**（`ddr_186.v`）：
  `ram_addr = {6'b000001, vga_ddr_row_col + vga_lnbytecount}`
  → 物理 = **0x08080000 + 2·vga_ddr_row_col**
  改前 `vga_ddr_row_col=0x14000`（line 136/736）→ `ram_addr = 0x54000` → 物理 **0x080A8000**。

**二者差 0x40000（ram_addr 差 0x20000）**：CPU 写 0x08068000，VGA 读 0x080A8000 → VGA 读到的全是别的区域（脏/旧数据）→ 花屏+乱码。

### 1.2 关键约束：0x08068000 落在 VGA 寻址方案的“空洞”里

VGA 读地址 = `6-bit 前缀 + 17-bit vga_ddr_row_col`，只能覆盖两个不相交区间：
- 前缀 `000000` → 物理 `0x08000000`–`0x0803FFFE`
- 前缀 `000001` → 物理 `0x08080000`–`0x080BFFFE`

**0x08068000 在两个区间之间，VGA 读路径结构上够不到**。所以“只改一个 VGA 读常数”无法对准 0x08068000——只能二选一：
- (A) 把 CPU 文本窗挪进 VGA 可读区（改 `map[11]`）；或
- (B) 重构 VGA 读路径（前缀+row_col 加宽）去够 0x08068000。

本次按用户选择采用 **(A)**：移动 CPU 文本窗到 VGA 区，VGA 读路径完全不动。

---

## 2. 修复（两部分）

### ① `cache_controller.v` —— `map[11]` 6→10

```verilog
reg [8:0]map[0:31] = '{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
                         10, 10,          // ← map[11]: 6 -> 10（文本窗挪到 VGA 可读区）
                         18, 19, 20, 21,
                         ...
```
效果：`map[11]=10` → CPU 文本窗物理 = 0x08000000 + (10<<16) + (0x200<<6) = **0x080A8000**，正好落在 VGA 前缀-1 区（`0x08080000`–`0x080BFFFE`）。

### ② `Next186_BlackBoxes.v` —— BIOS `scraddr` 0x3000→0x6000

`ddr_186.v:735` 每帧末用 `scraddr` 重算 `vga_ddr_row_col`：
```verilog
vga_ddr_row_col <= {{1'b0, scraddr[15:13]} + (vgatext[0] ? 4'b0111 : 4'b0100), scraddr[12:0]};
```
- 旧 `scraddr=0x3000` → 算出 `row_col=0x11000` → VGA 物理 0x080A2000（与 CPU 文本窗 0x080A8000 仍错位 0x6000）。
- 新 `scraddr=0x6000` → 算出 `row_col=0x14000` → VGA 物理 **0x080A8000**，与 CPU 文本窗完全一致。

改动落在 BIOS 硬编码（`ram[11'h03A]` 的 `mov al,0x30`→`mov al,0x60`，机器码 `B0 30`→`B0 60`）：
```verilog
ram[11'h03A] = 32'h4AEE60B0;   // scraddr 高字节 0x30->0x60（CRT 起始地址高）
```

> 注：`vga_ddr_row_col` 的初值/逐行值（line 136/736 的 `17'h14000`）本身已正确，无需改动；只改 `scraddr` 让每帧重算也落在 `0x14000`。

---

## 3. 对齐验证（逐项）

| 项 | 改前 | 改后 |
|---|---|---|
| CPU 文本窗物理（map[11]） | 0x08068000 | **0x080A8000** |
| VGA 读物理（row_col=0x14000，前缀000001） | 0x080A8000 | **0x080A8000** |
| 每帧重算 row_col（scraddr） | 0x11000（→0x080A2000） | **0x14000（→0x080A8000）** |

CPU 写文本与 VGA 读文本现在指向同一 DDR 区域 **0x080A8000**，花屏/乱码应消失，文本实时刷新。

---

## 4. 下板验证提示

1. 文本屏应正常显示、随 CPU 清屏/填屏实时更新（配合 `cache_flush_写回修复.md` 的 flush 修复）。
2. **devmem 测试地址变更**：文本帧缓冲物理基址已从 `0x08068000` 变为 **`0x080A8000`**。原先在 `0x08068000` 做的读写验证需相应改到 `0x080A8000`；`0x08068000` 现在只是一个普通物理地址（不再是文本窗，CPU 经 cache 读它仍是 1:1 正确，但与显示无关）。
3. ILA：可看 `dbg_sdraddr`（ddr_186.v 已有，reg+always 采样）——VGA 读地址应停在 `0x080A8000` 附近的文本区，而非旧的 `0x080A2000`/`0x08068000`。

---

## 5. 已知遗留（非本次阻塞）

- **图形模式（map[10]）未同步对齐**：图形帧缓冲 VGA 侧基址在 `ddr_186.v:736` 为 `17'h8000`（→物理 0x08090000），而 CPU 图形窗（map[10]=10）基址为 0x080AA000，二者仍差 0x1A000。本次只修文本模式（用户现象为文本花屏）。若后续需图形模式正常显示，按同样方法把图形 `row_col` 基址 / `scraddr` 图形支路径对齐到 map[10] 所指区域即可。
- `0x08068000` 不再作为文本窗；任何依赖旧文本基址的外部脚本/测试请更新为 `0x080A8000`。

---

## 6. 同步步骤

1. Mac 提交并 push：`git add cache_controller.v Next186_BlackBoxes.v && git commit -m "..." && git push origin main`
2. Ubuntu（Vivado）机：`git pull` 拉取最新 `cache_controller.v` / `Next186_BlackBoxes.v`，覆盖进 `sources_1` 同名文件，重新综合 / 生成 bit。
3. 下板看文本屏 + ILA（`dbg_sdraddr`、`dbg_ctl_rflush_r`、`dbg_ctl_ddr_wr_r`、顶层 `AWVALID/WVALID/AWADDR`）。
