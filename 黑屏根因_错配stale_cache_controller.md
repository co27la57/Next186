# 下板黑屏根因分析 —— cache_controller.v 与 VGA 侧文件版本错配

- 日期：2026-09-18
- 关联提交：`47cc561`（cache flush 写回解耦 + VGA 读地址对齐文本窗）
- 关联现象：下板后① CPU 仍从 `0x08068000` 读文本；② ILA 触发 `ARADDR/AWADDR==0x080A8000` 不工作；③ `isvwr==1` 时 `awaddr=0x0815FF00`；④ 显示器全黑（无乱码/色块）。

---

## 1. 结论（一句话）

**板子上跑的 `cache_controller.v` 是 `47cc561` 之前的旧版本（`map[11]=6`、旧 flush 逻辑），而 `ddr_186.v` / `Next186_BlackBoxes.v` 已经是新版本（`scraddr=0x6000` → VGA 读 `0x080A8000`）。两套文件版本错配，导致 CPU 文本窗（`0x08068000`）与 VGA 读窗（`0x080A8000`）完全脱节，且旧 flush 永不把显存脏行写回 DDR → 黑屏。**

这不是 RTL 逻辑错误，是 **Ubuntu/Vivado 机 `sources_1` 里 `cache_controller.v` 没更新到 `47cc561`**（只更新了 VGA 侧两个文件，或 `git pull` 后没把 `cache_controller.v` 覆盖进 `sources_1`）。

---

## 2. 四项现象逐条对应错配

| 现象 | 实际看到 | 错配解释 |
|---|---|---|
| ① CPU 仍读 `0x08068000` | 向 PS `0x08068000` 写 `0xAAAA_AAAA`，CPU 读到它 | 板载 `map[11]=6` → CPU 文本窗物理基址 `0x08068000`。**只有 `map[11]=10` 才在 `0x080A8000`**。说明板载 `cache_controller.v` 是旧版。 |
| ② ILA 不触发 `0x080A8000` | `ARADDR/AWADDR==0x080A8000` 抓不到波形 | CPU 文本写地址是 `0x08068000`（旧 `map[11]`），从没访问过 `0x080A8000` → 自然不触发。 |
| ③ `awaddr=0x0815FF00` | `isvwr==1` 时写地址是这个陌生值 | `0x0815FF00` 对应 `ram_addr=0x0AFF80={memmap_mux=0x15, cache_hi_addr[9:0]=0x3FC}`。`memmap_mux=0x15=map[15]=21` 由 `cache_hi_addr[14:10]=0x0F` 选出，即 cache 行 tag=`cache_addr=511`（bootstrap 幽灵区，index 16–31 恒为 511）。这是**正常的脏行驱逐写回**，与文本窗无关，不是 bug。 |
| ④ 全黑屏 | 连乱码/色块都没有 | VGA 侧（`scraddr=0x6000`）每帧从 `0x080A8000` 读文本；但 CPU 文本写在 `0x08068000`（旧 `map[11]`），且**旧 flush 逻辑把脏行写回挂在 `mmreq&&!hit` 分支下、清屏等全命中写入不产生 miss → 脏行永不写回 DDR**。于是 VGA 从 `0x080A8000` 读到的是全 0 → 黑屏。 |

> 注：若 `cache_controller.v` 也是新版的（`map[11]=10` + 新 flush），则 CPU 文本窗=`0x080A8000` = VGA 读窗=`0x080A8000`，且每帧 flush 把脏行写回 DDR，文本应正常显示（不会黑屏、不会花屏）。这正是 `47cc561` 的设计目标，已逐级核算一致（见 `VGA_读地址对齐修复.md`）。

---

## 3. 已排除的"疑似 bug"（实测不是）

- **`auto_flush[2] <= auto_flush[2] | vblnk` 把 flush 锁死？** 否。`vblnk` 是多级电平信号（`vga.v:97` `vblnk <= (vcount >= tc_vsblnk)`），在 `vblnk` 下降沿移位寄存器 `auto_flush[1:0]<={auto_flush[0],vblnk}` 恰好产出一次 `auto_flush==3'b110`（线 477 的 `flush` 脉冲），即**每帧自动 flush 一次**，不会永久拉死、不会饿死 CPU。
- **`awaddr=0x0815FF00` 是写错地址？** 否。见上，是 bootstrap 幽灵区（`cache_addr=511`）的正常驱逐写回，落在 DDR 内（`0x0815FF00` 在 `0x08000000–0x08FFFFFF` 区间），无害。
- **RTL 算术对齐错？** 否。CPU 文本窗 `0x080A8000` 与 VGA 读 `0x080A8000`（`scraddr=0x6000`→`row_col=0x14000`→`0x08080000+2·0x14000`）严格相等，已核算。

---

## 4. 修复步骤（在 Ubuntu/Vivado 机执行）

`47cc561` 的 **三个文件是相互依赖的一组改动**，必须同时到位：

1. `git pull`（确保本地是 `47cc561` / `ae2a3fd` 之后的最新）：
   ```
   cd <Next186 repo> && git log --oneline -1   # 应看到 ae2a3fd 或 47cc561
   git pull
   ```
2. **删除** `sources_1` 里旧的同名三文件（避免增量综合/缓存用旧版）：
   - `cache_controller.v`  ← **关键**，必须是最新的（`map[11]=10`、含 `r_flush` 分支、单遍 flush）
   - `ddr_186.v`          ← `auto_flush` 每帧自动触发
   - `Next186_BlackBoxes.v` ← BIOS `scraddr=0x6000`（`ram[11'h03A]=32'h4AEE60B0`）
3. 把仓库最新三文件**复制**进 `sources_1`（覆盖）。
4. **Clean** 重新综合 / 实现 / 生成 bit（建议 `Reset Output Products` + `Generate Bitstream`，或整工程 `Clean`）。
5. 下板，验证：
   - 文本屏应正常显示（非黑、非花屏）；
   - ILA：`AWADDR/AWADDR==0x080A8000` 应能触发（CPU 文本写落在 `0x080A8000`）；`dbg_ctl_rflush_r` 每帧拉高、`dbg_ctl_ddr_wr_r` 应有脉冲（脏行写回 DDR）；
   - devmem 测试地址改为 **`0x080A8000`**（不再是 `0x08068000`，见 `VGA_读地址对齐修复.md` 第 4 节）。

---

## 5. 本次附带的真实 RTL 修复（commit 见下）

`cache_controller.v` STATE `3'b100`：flush 扫描改为**单遍 128 行**即终止。
- 原实现：`flushcount[7]`（r_flush 标志）仅在 `flushcount` 溢出到 256 时因 bit7 回绕归零，导致每个 `(way,set)` 被扫描/写回**两次**（2× DDR 带宽，且与晚到 CPU 写入存在回写竞态）。
- 现：扫描到 `flushcount[6:0]==7'h7F`（最后一项）即清 `r_flush` 并复位索引，干净终止。
- 该修复与黑屏根因（文件错配）无关，是 `47cc561` flush 逻辑的附加健壮性修正；重新综合后一并生效。
