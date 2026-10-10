# 下板测试单 v2：95th 自测探针（offset 0x180 → 端口 0x00E5）

> commit `61b167c`（已 push）。上一版 `90e9722` 的 v1 探针（报 0x84）已经用完了它的信息量。

---

## 0. v1 的结论（已经拿到，别再重复问）

板上实测 **`dbg_dbg5 = 0x61` + `dbg_dbg4 = 0x6010`**：

- `[0x80] = 0x60`、`[0x84] = 0x61` —— **连续序列**，不是"word0 重复"。
- 自测图案是 `byte@m = (m>>2)&0xFF`，而 0x60 在 1KB 内的唯一来源是 offset **0x180**。
- ⇒ **整个自测图案被右移了正好 0x100 字节 = 4 行**：**line 2 的槽位装的是 line 6 的整行内容**。

## 1. 这一轮要做什么

```
reset_run synth_1/impl_1   →  bitstream  →  烧录
```
**仍然不需要重建 Set Up Debug**（没有增删探针，预算 36 个 / 265 bit 不变）。

## 2. 要读什么

| 信号 | 判读 |
|---|---|
| `dbg_dbg4[15:0]` | 应仍为 `0x6010`（AL=0x10 对照 ✓、AH=0x60）——用来确认这一版确实跑上了 |
| **`dbg_dbg5[7:0]`** | **本轮唯一判据，见下** |
| `dbg_bufwb_a[14:0]` | 最后一次缓冲行写回的 hiaddr（上轮 = `0x3c06`，正好是**源行 index 6**，这条相关性很重要） |
| `dbg_dbg2[15:0]` | 8KB 校验和（期望 `0x2F27`） |

## 3. 怎么判读 `dbg_dbg5`（= `[0x180]`，line 6 自己的槽位）

| `dbg_dbg5` | 含义 | 下一步方向 |
|---|---|---|
| **`0x60`** | line 6 的槽位**是对的** ⇒ **DDR 完好** ⇒ 是 **line 2 的填充读错了地址**（读侧） | 查 `hiaddr`/`sdraddr` 在填充命令那一刻的取值（88th 的 `ddr_rd <= s111_d` 那条路径） |
| **其它值** | line 6 的槽位**也不对** ⇒ **line 6 的写回落到了别处**（写侧） | 查写回的 `wb_hiaddr`/`wb_way` 与 FSM 锁存的 `main_awaddr`（`sdraddr` 采样时机） |

补充读法：若 `dbg_dbg5` 恰好等于 `(0x180 + 0x100)>>2 & 0xFF = 0xA0`，说明 line 6 也被**同方向**搬移了
（即整个映射整体平移），那指向**系统性地址偏移**；若是 0x00/0xFF 之类，指向该槽位**根本没被写回**。

## 4. 本轮改的三个表字（便于核对）

```
0xF6  32'hBA04458A -> 32'h0100858A     (8A 85 00 01)
0xF7  32'h5AEE00E5 -> 32'hEE00E5BA     (BA E5 00 EE)
0xF8  32'h8B5290C3 -> 32'h8B52C35A     (5A C3 52 8B)
```

反汇编后的报告例程（`sim/tools/bios_dis.py 0x3D0 0x3EC` 可复现）：

```
03D3  52           push dx
03D4  BA E4 00     mov dx,0xe4
03D7  EF           out dx,ax        ; dbg_dbg4 = AX（不变）
03D8  8A 85 00 01  mov al,[di+0x100]  ; AL = [0x180]（DI 仍为 0x80）
03DC  BA E5 00     mov dx,0xe5
03DF  EE           out dx,al        ; dbg_dbg5 = [0x180]
03E0  5A           pop dx
03E1  C3           ret
03E2  52 ...                         ; pckp 未动
```
`0x3D8..0x3E1` 正好填满，`0x3E2`（`pckp` 的 `push dx`）未动。

## 5. ⚠ 一条踩过的坑（已修，留档）

v2 补丁脚本的"注释替换"正则多匹配了 1 行，**把 `ram[11'h0F6]` / `bios_rom[8'h0F6]` 那行删掉了**。
`sim/tools/bios_check_95st.py` 立刻报 `word 0F6 = MISSING`，`sim/tools/fix_missing_f6.py` 已修复。
**每次改 BIOS 表都必须跑一遍断言脚本**——这次就是它挡住了。

## 6. 若 `dbg_dbg5` 恒 0

说明新增指令没执行到：核对 `git log -1` 是否为 `61b167c`、是否做了 `reset_run`（BRAM 初值变了必须重综合）。
