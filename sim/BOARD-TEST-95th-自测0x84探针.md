# 下板测试单：95th 自测探针（offset 0x84 → 端口 0x00E5）

> commit `90e9722`（已 push）。这一版 = **95th 修复 + 伪 burst 探针 + BIOS 0x84 上报**，
> 正是"下一轮要综合的那棵树"，可直接复现。

---

## 1. 要做什么

```
reset_run synth_1/impl_1   →  生成 bitstream  →  烧录
```

**不需要重建 Set Up Debug** —— `dbg_dbg5`（端口 `0x00E5`）本来就在 ILA 探针列表里
（`ddr_186.v:409/417`），本次没有增删任何探针，探针预算仍是 36 个 / 265 bit。

## 2. 要读什么（ILA）

| 信号 | 期望（健康） | 上一轮实测 |
|---|---|---|
| `dbg_dbg4[15:0]` | `0x2010`（AL=0x10 对照 ✓，AH=0x20 测量） | `0x6010`（AH = `0x60` ✗） |
| **`dbg_dbg5[7:0]`** | **`0x21`** | 上一版恒 `0x00`（未使用） |
| `dbg_spur_wb_n[7:0]` | `0x00` | `0x00` ✓ |
| `dbg_spur_rd_n[7:0]` | `0x00` | `0x00` ✓ |
| `dbg_dbg2[15:0]` | `0x2F27`（8KB 校验和） | `0x8f26` ✗ |

## 3. 怎么判读 `dbg_dbg5`（这是本轮唯一的判据）

自测流程：填 1KB（`byte@m = (m>>2)&0xFF`）→ 读 `0x40`（对照，AL）→ `scan256` 逐出全部
→ 读 `0x80`（AH）→ **读 `0x84`（新增，`dbg_dbg5`）**。

`[0x84]` 属于 line 2 的**第 1 个字**，所以它能把三种形态一次分开：

| `dbg_dbg5` | 含义 | 下一步方向 |
|---|---|---|
| **`0x61`** | line 2 的**整行内容**被换成了 line 6 的 → **整行级搬移**（地址错位或整行数据错配） | 查 `sdraddr`/`wb_hiaddr` 的地址与数据配对 |
| **`0x60`** | "line 6 的 **word0**" 被重复铺满 line 2 → **word0 级**（和 95th 同一族的机制，只是换了个触发条件） | 查 `wb_pcnt` / `word_a` / BRAM 端口 A 的字序号 |
| **`0x21`** | 只有 line 2 的**首字/首字节**错 | 查填充的起始相位（`lowaddr` / `cache_line_start`） |
| `0x00` 或 `0xFF` | 整行是空的 / 擦除态 | 该行**根本没被写回**或没被填充 → 查事务有没有发生 |

同时看 `dbg_dbg4` 的 AH：若本轮 AH 与 `dbg_dbg5` 满足 `AH = dbg_dbg5 - 1`，说明整个 line 2
是"从某一行的 byte0 开始逐字复制"（line 级），这本身就是很强的定位信息。

## 4. 附：本次改了哪三个表字（便于你核对）

```
0xF6  32'h9090C35A -> 32'hBA04458A      (8A 45 04 BA)
0xF7  32'h90909090 -> 32'h5AEE00E5      (E5 00 EE 5A)
0xF8  32'h8B529090 -> 32'h8B5290C3      (C3 90 52 8B)
```
两张表（`Next186_BlackBoxes.v` 的 `cache.ram[]`、`cache_controller.v` 的 `bios_rom[]`）
**必须完全一致**（已用 `sim/tools/bios_table_cmp.py` 验过 256/256）。

反汇编后的报告例程（`sim/tools/bios_dis.py 0x3D0 0x3F0` 可复现）：

```
03D3  52           push dx
03D4  BA E4 00     mov dx,0xe4
03D7  EF           out dx,ax        ; dbg_dbg4 = AX
03D8  8A 45 04     mov al,[di+4]    ; AL = [0x84]  (DI 仍为 0x80)
03DB  BA E5 00     mov dx,0xe5
03DE  EE           out dx,al        ; dbg_dbg5 = [0x84]
03DF  5A           pop dx
03E0  C3           ret
03E1  90           nop
03E2  52 ...                        ; pckp 未动
```

## 5. 若结果不符合预期

- `dbg_dbg5` 恒 `0x00` 且 `dbg_dbg4` 仍是 `0x6010`：说明**新增的那条指令没执行到**
  → 检查 `git log -1` 是否为 `90e9722`、以及有没有 `reset_run`（BRAM 初值变了必须重综合）。
- `dbg_dbg5` 与 `dbg_dbg4` 的 AH 一致（都是 `0x60`）：说明 line 2 整行都是同一个字
  → 指向 word0 重复族，而不是整行搬移。
