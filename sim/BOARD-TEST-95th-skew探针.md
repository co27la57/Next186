# 下板测试单 v3：量 `hiaddr → sdraddr` 错位（commit `5362c54`）

---

## 0. 已经确定的结论（不用再测）

| 读数 | 结论 |
|---|---|
| `dbg_dbg4 = 0x6010`、`dbg_dbg5 = 0x61` | `[0x80]=0x60`、`[0x84]=0x61` **连续** ⇒ 不是 word0 重复 |
| `dbg_dbg5 = 0xA0` | `[0x180]=0xA0` ⇒ line 6 的槽位装的是 **line 10** 的内容 |
| `AL = [0x40] = 0x10` ✓ | **CPU 侧地址正确** |

⇒ **CPU 读缓冲行 k 返回 W(k+4)**：**确定性 +0x100 字节（4 行）位移**，不是竞态；错位在 **DDR 往返**。

**关键推论**：`sdraddr[14:5]` 恒等于 `cache_hi_addr[9:0]`（纯函数），所以 +4 只可能是
**「`sdraddr` 锁存到的 `hiaddr` 不是被填充的那一行」**。本轮就是把这个直接量出来。

## 1. 要做什么

```
reset_run synth_1/impl_1   →  bitstream  →  烧录
```
**不需要重建 Set Up Debug**：本轮**没有新增探针信号**（改的是两个已有寄存器的赋值），
探针仍是 36 个 / 265 bit。BIOS 保持 v2 不变。

## 2. 要读什么

| 信号 | 期望（正确时） | 说明 |
|---|---|---|
| **`dbg_rd_reg[9:0]`** | 与 `dbg_wb_reg` **相等** | **FSM 实际拿到的地址** `sdraddr[14:5]` |
| **`dbg_wb_reg[9:0]`** | — | **cache 呈现的地址** `cache_hi_addr[9:0]` |
| `dbg_rdr_seen` | `1` | 捕获确实发生了 |
| `dbg_dbg5[7:0]` | 应仍为 `0xA0` | 确认这版确实跑上了 |
| `dbg_bufwb_a[14:0]` | 上次 = `0x3c06` | 最后一次缓冲行写回的 hiaddr |
| `dbg_spur_wb_n` / `dbg_spur_rd_n` | `00` / `00` | 95th 修复仍在生效 |

两个寄存器在**每个缓冲行 FILL 的 ack 上升沿**同时锁存（tracking latest）：
```
dbg_rd_reg <= sdraddr[14:5];        // FSM 实际拿到的地址
dbg_wb_reg <= cache_hi_addr[9:0];   // cache 呈现的地址
```
缓冲行的 tag = 0x1E0 ⇒ `tag[4:0]=0` ⇒ 这两个值**就等于 buffer 行号（index）**，非常好读。

## 3. 怎么判读

| 观测 | 结论 | 下一步 |
|---|---|---|
| `dbg_rd_reg == dbg_wb_reg` | **地址没有错位** ⇒ 填充拿到的 DDR 地址是对的 ⇒ 问题在**写侧**（写回落到别处 / 数据错） | 下一轮量写回的 `sdraddr`（用 `dbg_bufwb_a` 旁边再加一个） |
| **`dbg_rd_reg == dbg_wb_reg + 4`** | **错位被证实**：`sdraddr` 锁存到的 `hiaddr` 比被填充的行大 4 行 | 直接查 `sdraddr` 的采样时机（`cache_owns` / `s_prog_empty` 那条 mux） |
| 其它差值 | 错位量不是固定 4 ⇒ 采样时序与行号相关 | 把两个数发我，我按差值反推 |

例：若捕获到的是 self-test 读 `0x180` 的那次填充（index 6），则正确时
`dbg_rd_reg = dbg_wb_reg = 0x006`；若错位则为 `0x00A`。

## 4. 备注

- 该探针在**每次**缓冲行填充都刷新，所以 SD 阶段的活动也会刷新它 —— 但**不影响判定**：
  若是静态错位，SD 阶段同样会带 +4；若两个数始终相等，就说明地址路径干净。
- 回退：`sim/tools/patch_ddr_186_skew_probe.py --revert`（备份 `sim/run/ddr_186.v.preSkew`）。
