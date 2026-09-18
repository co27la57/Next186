# Next186 SoC：cache 状态机回退到原作者版本（死锁根因 + ILA 探针变动 + 显存基址）

> 关联 commit：`4b797fd` 之后的回退（本次）
> 改动文件：`cache_controller.v`、`ddr_186.v`、本说明文档（替换旧 `cache_lowaddr_0x20修复与VRAM不更新分析.md`）
> 仅此一份说明文档随本次 commit 提交（符合"只带一份最新 markdown"约束）

---

## 零、一句话结论

下板观测到的"CPU 卡死 + ILA 抓不到 0x08068000 写事务 + 0x20 偏移"——
**不是 0x20 半行错位，而是 `cache_controller` 状态机死锁**：我们在 Task #8 把整行完成握手信号 `s_lowaddr5` 从原作者 `lowaddr[4]`（电平）改成了 `lowaddr[5]`（且配 `cache_line_start` 强制归零），导致 64 B 行（仅 32 半字）永远到不了 `lowaddr[5]`，`s_lowaddr5` 恒为低，STATE 011 卡死。

**处理方式**：按用户拍板，`cache_controller.v` 整体回退到原作者已验证版本（仅保留 `map[11]=6` 与 ILA 探针），`ddr_186.v` 删除 `cache_line_start` 全部逻辑。0x20 偏移是死锁前残留下来的陈旧数据，回退后不再是关注点。

---

## 一、死锁根因（回退前 Task #8 版本 `4b797fd`）

### 1.1 原作者的整行完成握手（正确、已验证）

- cache 行 = 64 B = 32 个半字；行内偏移 `lowaddr` 为 **5 位**计数器，自动回绕 0→31。
- `s_lowaddr5 <= lowaddr[4]` —— 这是一个**电平**信号：
  - `lowaddr[4..0]` 在 `16..31` 时 `s_lowaddr5 = 1`；
  - 回绕到 `0..15` 时 `s_lowaddr5 = 0`。
- STATE 机在 `s_lowaddr5` 的**上升/下降沿**判定"整行填/写完"：
  - STATE 011（cache→DDR 写回）：`if(s_lowaddr5) ddr_wr<=0; STATE<=111;`
  - STATE 111/101：`if(~s_lowaddr5) STATE<=100/000;`

### 1.2 Task #8 改坏的地方

| 项 | 原作者 | Task #8（出错） |
|---|---|---|
| `lowaddr` 位宽 | 5 位，自动回绕 0..31 | 6 位，且 `cache_line_start` 脉冲强制归零 |
| `s_lowaddr5` 来源 | `lowaddr[4]`（电平） | `lowaddr[5]`（还经 CDC 两级同步） |
| flush | 原版单遍扫描 | "解耦/单遍"改造 |

### 1.3 为什么必然死锁

- 一行只有 32 个半字，`lowaddr` 取值范围 0..31，**`lowaddr[5]`（=32）永远到不了** → `s_lowaddr5` 恒为 **0**（低）。
- STATE 011 在 `if(s_lowaddr5)` 才退出，但 `s_lowaddr5` 永远不拉高 → **STATE 永远卡在 011**。
- 连锁反应：
  - `ddr_wr` 一直为 1 → AXI **不停写同一行**，`awaddr=0x0815C00` 恒定不变（用户 ILA 实测）。
  - `ce` 一直为 0 → **CPU 冻结**，`IP=0002 / IADDR=000000` 不动，但 `HALT` 并未拉高（冻结 ≠ HALT，故 ILA 看不到 HALT）。
  - flush 卡在首个脏行扫不到 video 区 → `isvwr` 不触发 → `0x08068000` 无写事务、也抓不到 `isvwr_r=1` 触发（之前能触发是因为死锁前的版本）。
  - `0x08068020` 读到 `aaaaaaaa` 是**死锁前残留下来的陈旧 cache 数据**，不是当前写回结果。

### 1.4 实证（区分这次死锁 vs 之前的 0x20）

- `ee3e674`（仅 `s_lowaddr5=lowaddr[5]`，**无** `cache_line_start`）：`isvwr` 还能触发 → 死锁尚未发生。
- `4b797fd`（加 `cache_line_start` 强制归零）：CPU 冻住、`awaddr` 恒定、`isvwr` 不触发 → **`cache_line_start` 是死锁回归触发点**。
- `0x20` 偏移源自更早的 `ee3e674`（`s_lowaddr5=lowaddr[5]`），但本次下板实测证明它是死锁前的陈旧数据，**真问题是状态机死锁**。

---

## 二、回退内容（已实现）

### 2.1 `cache_controller.v` —— 整体还原原作者版本

- 删除输入端口 `input cache_line_start;`
- `s_lowaddr5 <= lowaddr[`LINE-2];`（`LINE=6` ⇒ `lowaddr[4]`，**电平，无 CDC 同步**）
- `lowaddr` 改回 `reg [`LINE-2:0]lowaddr`（5 位），`always` 里 `if(cache_write_data||cache_read_data) lowaddr <= lowaddr + 1'b1;`（自动回绕）
- flush / STATE 机（000/011/111/100/101）全部还原原作者版本
- **保留三处必要改动**：
  1. `seg_map` 中 `map[11] = 6`（文本 VRAM 窗对齐到 `0x08068000`，见第三节）
  2. `cache_addr` 初始化：四个 way 的 index16-31 保持 `511`（bootstrap 标签，保证 CPU 能找到 begin 代码；原作者此处 way1/2/3 为 0/1/2，属项目既有改动，必须保留）
  3. ILA 探针（`mark_debug`，均为 `reg`+`always`，符合非 top 模块约束）：`lowaddr`、`s_lowaddr5`、`dbg_ctl_*`（`mreq`/`wmask`/`mmreq`/`hit`/`ce`/`isvmem`）、`isvwr`

### 2.2 `ddr_186.v` —— 删除 `cache_line_start` 全部逻辑

- 删除 `reg cache_line_start = 1'b0;`（原 line 142）
- 删除例化连线 `.cache_line_start(cache_line_start),`（原 line 478）
- 删除 `sys_cmd_ack` 边沿 → `cache_line_start` 脉冲逻辑（原 lines 694-698）
- **保留**（与回退无关、独立有效）：
  - `sdraddr = {memmap_mux[8:0], cache_hi_addr[9:0], 5'b00000}`（**1:1 映射**，见第三节）
  - `auto_flush[2] <= auto_flush[2] | vblnk;`（每帧垂直消隐自动触发回写，保证脏行落到 DDR）
  - `sys_cmd_ack_d1` 边沿检测（原 line 689/692/721，被原作者 `crw`/`col_counter` 逻辑使用，**保留**）

---

## 三、ILA 探针变动（用户要求体现）

| 探针 | 回退前（Task #8） | 回退后（原作者） | 观测差异 |
|---|---|---|---|
| `cache_line_start` | `reg`，由 `sys_cmd_ack` 边沿产生 | **已删除**（信号不存在） | 该信号从波形中消失 |
| `s_lowaddr5` | `lowaddr[5]` 经 CDC 同步，**恒为 0** | `lowaddr[4]` 电平，**半行高/半行低、每行翻转** | 回退前卡 0（死锁标志）；回退后应正常翻转 |
| `lowaddr` | 6 位，行首被 `cache_line_start` 强制归零 | 5 位，自动回绕 `0→31` | 回退后应在 0..31 循环，不再有"卡在 16 不前进" |
| `dbg_ctl_*` / `isvwr` | 保留 | 保留 | 不变 |

**下板最快判活信号**：看 `s_lowaddr5` 是否从"恒定 0"变成"周期翻转"，以及 `lowaddr` 是否恢复 `0→31` 循环——满足即说明死锁已解除。

---

## 四、显存物理基址与映射（用户要求体现）

回退**未改变**显存基址（该值在 `d2f6553` 即已固定为 `0x08068000`，本次仅回退状态机，基址保持不变）：

- 文本 VRAM：段 `0xB800` → `maddr[20:16]=11` → `map[11]=6` → 物理 **`0x08068000`**
- VGA：`scraddr=0x6000` ⇒ 读物理 `0x08068000`
- PS：直接写 `0x08068000`
- **三者对齐到同一物理窗 `0x08068000`** ✓

**1:1 映射（已验证，非本次问题来源）**：
```
sdraddr = {memmap_mux[8:0], cache_hi_addr[9:0], 5'b00000}
物理地址 = 0x0800_0000 + sdraddr×2
         = 0x0800_0000 + map[maddr[20:16]]·65536 + maddr[15:6]·64
```
- `map[11]=6`、`maddr[15:6]=0x200` ⇒ `sdraddr = 6<<15 | 0x200<<5 = 0x34000`
- 物理 = `0x0800_0000 + 0x34000×2 = 0x08068000` ✓

> 注：`sdraddr` 末 5 位为 0（行内偏移由 `lowaddr` 经 cache `address_a/b` 给出），故为**1:1**（1 字节 CPU 地址 ↔ 1 字节 DDR），无 2:1 压缩。

---

## 五、验证计划（提交后由用户在 Ubuntu 机下板）

1. `git pull` → 同名覆盖 `sources_1` 的 `cache_controller.v` + `ddr_186.v`（与 `Next186_BlackBoxes.v` 同版本）→ Vivado 综合/生成 bit → 下板。
2. **死锁解除判定**：
   - `s_lowaddr5` 不再恒 0，恢复半行高/半行低翻转；
   - `lowaddr` 在 `0→31` 循环；
   - `awaddr` 不再恒定 `0x0815C00`，CPU `IP/IADDR` 继续推进，`HALT` 仍不拉高（正常）；
   - 触发条件 `awaddr=0x08068000` 与 `isvwr_r=1` **重新可抓到波形**。
3. **VRAM 更新判定**：触发 `isvwr`，确认 `sdraddr=0x34000`（⇒ 物理 `0x08068000`）被写回；`devmem 0x08068000..0x0806807E` 能看到 CPU 清屏/写串的真实内容（下板前写的 `aaaaaaaa` 应被 OS 清屏 0 覆盖——这是**正确**行为）。
4. 若回退后 VRAM 仍不更新：原作者 flush 仅在缓存缺失/空闲路径推进 flushcount，存在"清屏全命中 flush 饿死"的理论局限；届时可小改 flush 扫描触发（**不退回 `cache_line_start` 方案**），另行评估。

---

## 六、已规避的坑（对照前几轮）

- ❌ 不要再用 `cache_line_start` 强制归零 `lowaddr`（会破坏 `lowaddr[5]` 永不达 → 死锁）。
- ❌ 不要把 `s_lowaddr5` 取 `lowaddr[5]`（64 B 行只有 32 半字，`[5]` 位恒 0）。
- ❌ 不要把 `cache_controller.v` 的整行握手"解耦/单遍"改掉——原作者 `s_lowaddr5=lowaddr[4]` 电平握手是已验证可工作的设计。
- ✅ 保留：`map[11]=6`（文本窗 `0x08068000`）、`sdraddr` 5'b00000（1:1）、`auto_flush[2]|=vblnk`（每帧回写）、`BlackBox` 禁加 for 循环全量填充。
