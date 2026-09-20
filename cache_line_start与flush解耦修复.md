# Next186 SoC：cache 行起始复位(cache_line_start) + flush 解耦 修复

> 关联 commit：本说明随修复提交（替换旧 `cache状态机回退原版_死锁根因与ILA探针变动.md`）
> 改动文件：`cache_controller.v`、`ddr_186.v`、本说明文档（仅此一份 markdown，符合"只带一份最新 markdown"约束）

---

## 零、一句话结论

下板观测到的 **`isvwr` 不触发 + 0x08068000 写事务抓不到 + 0x20 半行偏移 + `dbg_IP` 线性遍历**——
**真因是 `af6f44b` 回退把两项功能性修复一起删掉了**：

1. **`cache_line_start` 每事务 lowaddr 复位**（导致复位 miss 的 DDR 行填充从错误行内偏移写 cache → CPU 跑垃圾 → 永不到达写显存指令）；
2. **flush 与 CPU 访问解耦**（导致清屏等"全命中"写入的脏行永远写不回 DDR）。

**本修复在保留 5-bit `lowaddr` 的前提下重新加回这两项**，且**明确不使用 4b797fd 的 6-bit + `lowaddr[5]` CDC 方案**（那才是死锁根因）。

> 关键澄清：`cache_line_start` 本身不是死锁元凶。**4b797fd 的死锁来自 6-bit `lowaddr` + `s_lowaddr5=lowaddr[5]`（64B 行仅 32 半字，`lowaddr[5]` 永不到）→ `s_lowaddr5` 恒低 → STATE 011 卡死**。把 `cache_line_start` 配回 **5-bit `lowaddr` + `s_lowaddr5=lowaddr[4]`（电平）** 是安全且必要的。

---

## 一、诊断过程（三选一排除）

用户要求判断是"tag 没覆盖取指地址"还是"BRAM 预填内容/地址对不上"。经追溯 + 对照原作者，结论：**两者都不是**。

| 假设 | 核查结果 | 结论 |
|---|---|---|
| tag 未覆盖 CPU 取指地址 | `cache_addr` 四 way 的 index16-31 全 =511（`d2f6553`/`af6f44b` 一致）；复位取指 tag=511 → 四 way 全命中，`dbg_ctl_hit_r` 恒高正确 | ❌ 非根因 |
| BRAM 预填内容/地址对不上 | `Next186_BlackBoxes.v` `ram[0..0FF]` 机器码与 `d2f6553`/`4b797fd` **字节一致**；对照原作者 `bootstrap.asm`（`BOOTOFFSET=0FC00h`→F000:FC00=tag511/index16）完全吻合；`ram[0xFC]=32'h00FC00EA`(JMP F000:FC00) 正确 | ❌ 非根因 |
| 状态机逻辑在回退中丢失 | `git diff 4b797fd HEAD -- cache_controller.v`：回退删除了 `cache_line_start` 端口、`flush` 解耦 STATE 分支；仅保留 5-bit `lowaddr` + `s_lowaddr5=lowaddr[4]` | ✅ **真因** |

**外部对照**：OpenCores 项目页确认"bootstrap preloaded in cache, at first flush transferred to RAM"；本地 `bootstrap.asm` 确认 BIOS 运行于 F000:FC00，硬编码机器码无误（改代码前已再三确认，本修复**不改 BlackBox**）。

---

## 二、修复内容（已实现）

### 2.1 `cache_controller.v`

1. **恢复输入端口** `input cache_line_start;`
2. **ddr_clk 域 lowaddr 复位**（避免行内偏移残留）：
   ```verilog
   always @(posedge ddr_clk) begin
       if(cache_line_start) lowaddr <= {(`LINE-2){1'b0}};   // 5-bit 归零
       else if(cache_write_data || cache_read_data) lowaddr <= lowaddr + 1'b1;
       ddr_dout <= lowaddr[0] ? cache_QA[15:0] : cache_QA[31:16];
   end
   ```
3. **STATE 000 恢复 flush 解耦分支**（清屏等全命中写入也能写回）：
   ```verilog
   end else if(r_flush) begin
       flushcount[`WAYS+`SETS] <= flushcount[`WAYS+`SETS] | flushreq;
       if(dirty) begin
           ddr_rd <= 1'b0; ddr_wr <= 1'b1; STATE <= 3'b011;   // 写回当前脏行
       end else begin
           STATE <= 3'b100;                                   // 当前行干净，推进扫描
       end
       ce <= 1'b0;   // 写回期间挂起 CPU，与正常 evict 一致，避免丢写
   end
   ```
4. **STATE 011**：flush 写完脏行后直接进 `3'b100`（不再进 111 回填，避免把刚写回 DDR 的行又用 DDR 旧数据覆盖）：
   ```verilog
   STATE <= r_flush ? 3'b100 : 3'b111;
   ```
5. **STATE 111**：flush 期间不改 `hiaddr`（写回地址已在 STATE 000 锁定）：
   ```verilog
   if(~r_flush) hiaddr <= maddr[`ADDR-1:`LINE];
   ```
6. **明确保留**：5-bit `lowaddr`（`reg [`LINE-2:0]`）、`s_lowaddr5 <= lowaddr[`LINE-2]`（=lowaddr[4]，电平）、原版 STATE 100 `flushcount <= flushcount + 1'b1` 单遍扫描（`flushcount[7:0]` 自然回绕到 0x00 终止）、`map[11]=6`、四 way index16-31=511、ILA 探针。

### 2.2 `ddr_186.v`

1. **恢复声明** `reg cache_line_start = 1'b0;`（原 line 142 附近）
2. **恢复单周期脉冲生成**（clk_sdr 域，`sys_cmd_ack` 跳变为 cache 行读 2'b11 / 写 2'b01 时；VGA 读 2'b10 与空闲不产生）：
   ```verilog
   cache_line_start <= (sys_cmd_ack != 2'b00) && (sys_cmd_ack_d1 == 2'b00) &&
                       ((sys_cmd_ack == 2'b01) || (sys_cmd_ack == 2'b11));
   ```
   `sys_cmd_ack` / `sys_cmd_ack_d1` 在原作者 DDR 控制器中本就存在（被 `crw`/`col_counter` 使用），仅缺 `cache_line_start` 生成逻辑，本次补回。
3. **恢复例化连线** `.cache_line_start(cache_line_start),`（cache_ctl 实例）

> `cache_line_start` 在 `clk_sdr` 域产生、在 `cache_controller` 的 `ddr_clk`（=clk_sdr）域消费，同频同域，**无需 CDC 同步**（这与 4b797fd 给 `lowaddr[5]` 做两级 CDC 是两回事）。

---

## 三、ILA 探针观测指引

| 探针 | 修复前(af6f44b 回退) | 修复后 | 判活信号 |
|---|---|---|---|
| `cache_line_start` | 不存在 | `sys_cmd_ack` 跳变时单周期脉冲 | 每次 cache 行事务起始应看到 1 拍高 |
| `s_lowaddr5` | `lowaddr[4]` 电平，正常翻转 | 同左，正常翻转 | 半行高/半行低，**不得恒低** |
| `lowaddr` | 5-bit 0→31 循环 | 同左，且每 `cache_line_start` 归零 | 0→31 循环，行间从 0 起 |
| `dbg_ctl_isvwr_r`/`isvwr` | 恒 0 | CPU 写文本窗时拉高 | **应重新触发** |
| `ddr_wr`/`awaddr` | flush 期间静默 | 清屏等全命中写入时 `ddr_wr` 拉起、`awaddr=0x08068000` 出现写事务 | **关键判活** |

---

## 四、显存物理基址（与修复无关，保持不变）

- 文本 VRAM：段 `0xB800` → `maddr[20:16]=11` → `map[11]=6` → 物理 **`0x08068000`**
- VGA：`scraddr=0x6000` ⇒ 读物理 `0x08068000`；PS：直接写 `0x08068000`
- **三者对齐同一物理窗 `0x08068000`** ✓（1:1 映射 `sdraddr={memmap_mux[8:0],cache_hi_addr[9:0],5'b00000}`）

---

## 五、验证计划（提交后由用户在 Ubuntu 机下板）

1. `git pull` → 同名覆盖 `sources_1` 的 `cache_controller.v` + `ddr_186.v`（与 `Next186_BlackBoxes.v` 同版本）→ Vivado 综合/生成 bit → 下板。
2. **行起始复位判活**：`cache_line_start` 在每次 cache 行事务起始出现 1 拍高；`lowaddr` 每行从 0 起、`s_lowaddr5` 正常翻转。
3. **isvwr / AWADDR 判活**：触发清屏/写串后，`dbg_ctl_isvwr_r=1` 重新可抓；`awaddr=0x08068000` 出现 AXI 写事务（`ddr_wr` 拉起）。
4. **0x20 偏移消除**：PS 写 `0x08068000=aaaaaaaa`，CPU 在 `0x08068000`（而非 `0x08068020`）读到。
5. 若仍异常：检查 `cache_line_start` 脉冲是否真送到 cache_controller（跨文件连线）；确认未误引入 6-bit `lowaddr`。

---

## 七、下板新现象与二次修复（2026-09-19 早）

### 7.1 用户下板观察

- `isvwr_r` 拉高且开始脉冲时，`ddr_wr` **恒低**，AXI 无写事务，`awaddr=0x08068000` 抓不到。
- `lowaddr[4:0]` 卡在 `0x1f`（31），`s_lowaddr5=1` 不翻转。
- `araddr=0x08068000` 能抓到读事务，且读到 `aaaaaaaa`。

### 7.2 分析：STATE 100 缺 else 分支导致卡死

`lowaddr=31` 表示 DDR  burst 已把一行（32 半字）传完，但 counter 缺一个回绕周期（下一拍 increment 归零）→ `s_lowaddr5` 恒高。STATE 111 在 `~s_lowaddr5` 才退出，因 CDC/clk-ddr_clk 相位，STATE 111 退出到 STATE 100 时 `s_lowaddr5` 可能已被采样为低。此时 STATE 100 原代码：
```verilog
if(r_flush) ... else if(s_lowaddr5) ... else // 无分支！
```
`r_flush=0` 且 `s_lowaddr5=0` 时**无去向**，状态机卡死在 STATE 100，`ddr_wr` 拉不起来。

### 7.3 二次修复

1. **STATE 100 补 else 分支**：只要 `r_flush=0` 且 `s_lowaddr5=0`，就清 `ddr_rd` 并返回 STATE 000，防止卡死。
   ```verilog
   end else begin
       ddr_rd <= 1'b0;
       STATE <= 3'b000;
   end
   ```
2. **新增 ILA 探针**：
   - `cache_line_start`（`ddr_186.v`，`mark_debug` 加到 reg 声明）
   - `dbg_ctl_STATE_r` / `dbg_ctl_flushcount_r`（`cache_controller.v`，便于下次直接看状态机卡在哪）。

### 7.4 仍需确认

- `lowaddr` 卡住是 burst 天然停在 31（缺回绕拍），还是 STATE 111 没等到回绕就退出并卡在 100。加了 STATE 探针后可分辨。
- 若 STATE 100 else 分支生效但 `awaddr=0x08068000` 仍不出现，需要再看 `cache_line_start` 脉冲位置是否在某行中间误触发（需下次下板波形）。

---

## 八、0x08068000 写事务缺失根因：VRAM 写命中未置 dirty bit（2026-09-19 中）

### 8.1 用户新波形确认

- 抓 `isvwr=1` 触发：`dirty_r[3:0]` **全程为 0**，一次都没变 1。
- `mreq_r` 与 `mmreq_r` 完全同步，都是密集脉冲；`ce_r=1`；`STATE_r=0`；此前已确认 `hit_r=1`、`wmask_r=3-0-c-3-0-c` 反复变化。

### 8.2 分析：dirty 置位条件漏采样

dirty 置位条件（`cache_controller.v:152-155`）为 `st0 && mmreq && hit && fit[i] && |mwmask`。用户探针已证实：
- `st0=1`（STATE=0）
- `hit=1`
- `|mwmask≠0`（wmask 在 3/c 时非 0）
- `mmreq` 也脉冲

但 `dirty_r` 仍为 0，唯一合理解释是：**在 cache_controller 采样沿，`mmreq` 与 `|mwmask` 没有稳定重合**，导致 `st0 && mmreq && ... && |mwmask` 这一拍实际为假。经检查 `Next186_BIU_2T_delayread.v`，`RAM_MREQ = iread || RAM_RD || RAM_WR`，`RAM_WMASK` 由 `RAM_WR` 派生；在 BIU 的 2T 流水里 MREQ 脉冲密集（含取指 iread），写周期中 MREQ 与 WMASK 理论上应重合，但实际采样沿可能存在偏差。

### 8.3 修复：为 dirty bit 增加独立写命中置位路径

保持 LRU 更新仍受 `mmreq` 门控，但为 dirty 单独加一条路径：只要 `STATE=0`、命中、对应 way 匹配、`wmask` 非 0，就把 dirty 置 1。读命中（`|mwmask=0`）不受影响；miss/flush（`hit=0` 或 `fit=0`）也不受影响。

```verilog
generate
    for(i=0; i<(1<<`WAYS); i=i+1) begin: gen2
        always @(posedge clk) begin
            if(st0 && mmreq)
                if(hit) begin
                    cache_lru[i][index] <= fit[i] ? {`WAYS{1'b1}} : ...;
                end else if(free[i]) cache_dirty[index][i] <= 1'b0;
            // 新增：与 mmreq 采样无关的写命中 dirty 置位
            if(st0 && hit && fit[i] && |mwmask)
                cache_dirty[index][i] <= 1'b1;
        end
    end
endgenerate
```

### 8.4 验证判活

- `isvwr=1` 触发时，`dirty_r` 对应命中 way 的位应在写周期变 1。
- 每帧 flush 扫描到该 index/way 时，`awaddr=0x08068000` 出现 AXI 写事务。
- 文本 VRAM 更新最终同步到 DDR，VGA 可见。

### 8.5 e0095f9 下板结果：dirty_r 仍为 0（2026-09-19 中，待下一波波形）

用户下板验证：`e0095f9` 改完后波形与之前一样，`dirty_r` **全程不变 1**。说明去掉 `mmreq` 门控后仍不满足 `st0 && hit && fit[i] && |mwmask`——
即除 `mmreq` 外的某个子条件（`st0`/`hit`/`fit[i]`/`|mwmask`）在采样沿仍不符，或写命中落到的 way 与 `fit` 向量错位。

由于重新综合代价高，本轮**不急着改功能逻辑**，先加精确定位探针（见第九节），由下一波波形锁定具体子条件。

---

## 九、dirty 置 1 条件深挖 + 诊断探针（2026-09-19 中）

### 9.1 静态代码排查的两条主线假设

**(A) `|mwmask` 相对 `mmreq` 滞后 1 拍（最可疑）**
- `is_video_wr = is_video_mem & |mwmask`，`isvwr_r` 锁存为 1 已证明当拍 `|mwmask=1`，但 `gen2` 的 dirty 置位用的是**同一 clk 沿**的组合 `|mwmask`。
- 若 CPU 写脉冲 `mreq`/`mmreq` 与其 `wmask` 在流水线里错开 1 拍（写脉冲先到、`wmask` 后到），则写命中的那拍 `mmreq=1, hit=1, fit=1` 但 `|mwmask=0` → dirty 不置位；下一拍 `wmask` 有效但 `mmreq` 已落下 → 仍不满足。
- 连带后果：cache_mem port B 的 `wren_b=|mwmask` 同样在该拍为 0 → **VRAM 数据根本写不进 cache**，VGA 永远读 DDR 旧值。这与"STATE_r 恒 0（命中，行已在 cache）、但 VRAM 不更新"完全吻合。
- **判活探针**：`dbg_ctl_mwmask_v_r`（`|mwmask` 当拍值）与已有 `mreq_r`/`mmreq_r` 叠加，看 `|mwmask` 是否滞后 `mmreq`。

**(B) `blk`（实际写 way）与 `fit`（命中 way）错位（4-way 编码 bug）**
- `blk = flushcount[6:5] | {|fit[3:2], fit[3]|fit[1]}` 把 4-bit `fit` 编成 2-bit way，但单热 `fit` 解码错误：
  - `fit=0001`（way0）→ `blk={0, 0|0}=01`=**way1** ❌（应为 0）
  - `fit=0010`（way1）→ `blk={0, 0|1}=00`=**way0** ❌（应为 1）
  - `fit=0100`（way2）→ `blk=10`=way2 ✓
  - `fit=1000`（way3）→ `blk=11`=way3 ✓
- 清屏首次访问 VRAM 触发 miss，分配新行：`fblk = flushcount[6:5] | {...}`，非 flush 时 `flushcount[6:5]=0` → **新行落到 way0**。于是 `fit[0]=1` 但 `blk=1`：数据经 port B 写进 **way1**（tag 不匹配），而 `gen2` 把 dirty 置在 **way0**（fit[0]=1）。
  - 结果：dirty 置位的是"匹配 way"，但真实数据在"blk way"，且 blk way 的 dirty 永远=0 → flush 跳过真实数据 → `awaddr=0x08068000` 不出现。
  - 注意：此 bug 下 `dirty_r`（整 4-bit 向量）理论上应显示 bit0=1（gen2 置了 way0）。用户观测到 `dirty_r` 全 0，说明**还有 (A) 类滞后或其它因素掩盖**——故需下一波波形区分。
- **判活探针**：`dbg_ctl_blk_r`（实际写 way）、`dbg_ctl_fit_wr_r`=`fit[blk]`（选中 way 是否真命中）、`dbg_ctl_dirty_wr_r`=`cache_dirty[index][blk]`（真实写 way 的 dirty 当前值）。

**(C) 整体条件探针**
- `dbg_ctl_dirty_cond_r <= st0 && hit && |mwmask && |fit`：整体"应置 dirty"信号。若 `isvwr=1` 期间它**从不为 1** → 子条件 (A) 或 `fit` 有问题；若它**为 1 但 `dirty_r` 仍 0** → `cache_dirty[index][i]` 数组写入本身未生效（需查 index 同步 / 多 always 覆盖）。

### 9.2 本轮新增 / 清理的 ILA 探针（cache_controller.v）

- **删除** `dbg_ctl_isvmem_r` 声明与采样（不再使用），保持探针总数 < 300。
- **新增 5 根**（非 top 模块，按约束用 `reg`+`always`）：
  | 探针 | 含义 | 作用 |
  |---|---|---|
  | `dbg_ctl_mwmask_v_r` | 当拍 `|mwmask` | 与 `mreq_r` 叠加看是否滞后 1 拍（假设 A） |
  | `dbg_ctl_blk_r [1:0]` | 实际写入选中 way（port B 用 `blk`） | 验证 (B) 错位 |
  | `dbg_ctl_fit_wr_r` | `fit[blk]` | 选中 way 是否真命中 |
  | `dbg_ctl_dirty_cond_r` | `st0 & hit & |mwmask & |fit` | 整体条件是否成立（假设 C） |
  | `dbg_ctl_dirty_wr_r` | `cache_dirty[index][blk]` | 真实写 way 的 dirty 当前值 |

- **下一波波形抓法**：以 `isvwr=1` 触发，叠加看 `mreq_r`/`mmreq_r`/`mwmask_v_r` 时序关系、`blk_r`/`fit_wr_r`/`dirty_cond_r`/`dirty_wr_r`/`dirty_r`。重点回答：
  1. `|mwmask`（`mwmask_v_r`）是否滞后 `mmreq` 一拍？（→ 假设 A）
  2. `isvwr=1` 期间 `dirty_cond_r` 是否曾为 1？为 1 但 `dirty_r` 仍 0 → 数组写未生效；为 0 → 查 `blk`/`fit` 错位或 `|mwmask` 滞后。
  3. `fit_wr_r`（`fit[blk]`）在写命中时是否为 1？为 0 → 确认 (B) blk/fit 错位 bug。

### 9.3 待确认后再定修复方向

- 若 (A) 成立（wmask 滞后）：修复点应是让 dirty 置位/数据写入基于**对齐后的写有效**信号（例如用 `cache_write_data`/port B `wren_b` 活动沿，或在 BIU 侧对齐 `wmask` 与 `mreq`），而非依赖组合 `|mwmask`。
- 若 (B) 成立：修复 `blk` 编码，使其正确选中 `fit` 的单热 way（如用优先级译码 `blk = way_of_first_fit(fit)`），保证数据写 way 与 dirty 置位 way 一致。
- 两者可能同时成立，需波形确认后一并修复。

---

## 十、dirty 条件成立但 `cache_dirty` 写未生效：gen2 结构歧义修复（2026-09-19 中）

### 10.1 新波形结论：A/B 均不成立，问题在 dirty 数组写入本身

用户抓 `isvwr=1` 触发后反馈：
- `mwmask_v_r` 与 `mmreq_r` **严格同步** → 假设 A（`|mwmask` 滞后 `mmreq`）**不成立**。
- `fit_wr_r`（`fit[blk]`）写命中时 **恒为 1** → 假设 B（`blk`/`fit` 错位）**不成立**。
- `dirty_cond_r`（`st0 & hit & |mwmask & |fit`）在 `isvwr=1` 期间与 `mwmask_v_r`/`mmreq_r` **三者严格同步** → `st0`、`hit`、`|mwmask`、`|fit` 全部成立。
- 但 `dirty_r[3:0]` 和 `dirty_wr_r` 仍**全程为 0**。

这意味着 `st0 && hit && fit[i] && |mwmask` 条件**确实成立**，但 `cache_dirty[index][i] <= 1'b1` 没有生效——两个独立 `if` 写到同一数组位，Vivado 的综合/优先级处理可能把第二次写优化掉或产生异常 write-enable 结构，导致 dirty 位永远写不进去。

### 10.2 修复：把 dirty 置位并入 `if(st0 && mmreq) if(hit)` 分支

将 dirty 置位从与 LRU 更新并行的独立 `if` 中，移到**同一个 hit 分支内**，用 `|mwmask` 区分读/写命中：

```verilog
generate
    for(i=0; i<(1<<`WAYS); i=i+1) begin: gen2
        always @(posedge clk) begin
            if(st0 && mmreq) begin
                if(hit) begin
                    cache_lru[i][index] <= fit[i] ? {`WAYS{1'b1}} : cache_lru[i][index] - (cache_lru[i][index] > csblk);
                    if(|mwmask)
                        cache_dirty[index][i] <= 1'b1;
                end else if(free[i]) begin
                    cache_dirty[index][i] <= 1'b0;
                end
            end
        end
    end
endgenerate
```

- 写命中（`|mwmask=1`）：LRU 更新 + dirty 置 1 在同一分支内完成，写使能无歧义。
- 读命中（`|mwmask=0`）：仅 LRU 更新，dirty 不变。
- miss 分配 victim way：`free[i]` 分支清 dirty，行为与原代码一致。
- flush 期间：`fit=0`（`r_flush=1` 时 `fit` 被强制为 0）→ 走 `else if(free[i])` 清 dirty，也与原代码一致；但 flush 期间 STATE 通常不在 000 久留，且没有 `|mwmask`，不会误置 dirty。

### 10.3 验证判活

- `isvwr=1` 触发时，`dirty_r`/`dirty_wr_r` 应在写周期后变 1。
- 每帧 flush 扫描到 VRAM 行时，该行 dirty 已置 1 → `awaddr=0x08068000` 出现 AXI 写事务。
- 文本 VRAM 最终同步到 DDR，VGA 可见。

### 10.4 下板结果：dirty_r 仍 0（2026-09-19 中，gen2 重构无效）

用户下板复测：`dirty_r` **仍不变 1**，其它波形不变。说明第十节的 gen2 重构（把 dirty 置位并入 `if(hit)` 分支）**没有改变行为**——"两个独立 if 综合歧义"的假设**不成立**。dirty 置位不管用独立 `if` 还是并入 hit 分支，都写不进 `cache_dirty`。

---

## 十一、条件已完全证实满足，锁定 `cache_dirty` 数组写本身被吞（2026-09-19 中）

### 11.1 已排除项（综合前几轮波形）

| 子条件 | 证据 | 结论 |
|---|---|---|
| `st0`(STATE=000) | `STATE_r=0` | ✅ 满足 |
| `hit`(= \|fit) | `dirty_cond_r=1`、`hit_r=1` | ✅ 满足 |
| `\|mwmask` | `mwmask_v_r` 脉冲、`isvwr=1` | ✅ 满足 |
| `fit[i]`(写命中 way) | `fit_wr_r`=fit[blk]=1 | ✅ 满足 |
| `mmreq` | `mmreq_r` 与 `mwmask_v_r` 严格同步 | ✅ 满足 |
| `blk`/`fit` 错位(假设B) | `fit_wr_r` 恒 1 | ❌ 排除 |

即 `st0 && mmreq && hit && fit[i] && |mwmask` 这一置位条件**全部成立**，但 `cache_dirty[index][i] <= 1'b1` 仍未生效 → **问题在 `cache_dirty` 数组的 runtime 写本身被 Vivado 吞掉**，不在条件判断。

### 11.2 两条待区分的根因（用新探针一次性判明）

**(P) `mmreq`（ce 门控后）在写命中那拍实际为 0**
- 我的重构把 `mmreq` 加回了 dirty 置位条件（`if(st0 && mmreq) if(hit)`）。而 `dirty_cond_r` 之前**不含 mmreq**，所以"条件满足"里其实没验证 gated `mmreq`。
- 若 `mmreq`(=`ce ? mreq : rmreq`) 在 CPU 写命中那拍为 0（例如 ce 短暂拉低、或 mreq 与写数据拍错位），则 dirty 置位和 cache_mem port B 的数据写（`enable_b=mmreq&&hit&&st0`）都会跳过 → dirty 不置 + VRAM 数据不进 cache。
- **判活**：`dbg_ctl_dirty_cond2_r`（`st0 & mmreq & hit & |mwmask & |fit`）。若它**不随 `mwmask_v_r`/`mmreq_r` 同步脉冲**，说明 gated `mmreq` 在写拍确实缺失。

**(Q) `cache_dirty[index][i]` 这个数组的 runtime 写被综合吞掉**
- `cache_dirty` 是**index-first** 维度的 4-bit 数组（`reg [3:0] cache_dirty[0:31]`），而 `cache_lru`/`cache_addr` 是 **way-first**（`[0:3][0:31]`）。`cache_addr` 的写（miss 装载 tag）已被证实有效（VRAM 行能载入、hit=1），`cache_lru` 同理。`cache_dirty` 的 index-first + 单 bit 写 `cache_dirty[index][i] <= 1'b1` 可能被 Vivado 推断为 RAM 后单 bit WE 生成异常，导致写丢失。
- **判活**：`dbg_ctl_lru_wr_r`（`cache_lru[blk][index]`）。若它在写命中时**随写更新**（例如 0→3 或递减），说明 `if(hit)` 分支确实在跑、LRU 写有效，而 `dirty_r` 仍 0 → 只有 `cache_dirty` 写被吞 → 坐实 (Q)。
- 另有 `dbg_ctl_dirty_wr_d1_r`（`dirty_wr_r` 的 1 拍延迟）：即使写后 `index` 立即变化，也能捕捉到"上一拍写进去的 1"。

### 11.3 本轮探针增删（cache_controller.v）

- **删除** `dbg_ctl_dirty_cond_r`（不含 mmreq，已被 cond2 取代）。
- **新增 / 替换**（非 top 模块，`reg`+`always`）：
  | 探针 | 含义 | 用途 |
  |---|---|---|
  | `dbg_ctl_dirty_cond2_r` | `st0 & mmreq & hit & |mwmask & |fit` | 判 (P)：gated mmreq 是否在写拍缺失 |
  | `dbg_ctl_lru_wr_r [1:0]` | `cache_lru[blk][index]` | 判 (Q)：`if(hit)` 分支是否执行、LRU 写是否生效 |
  | `dbg_ctl_dirty_wr_d1_r` | `dirty_wr_r` 的 1 拍延迟 | 捕捉写后 dirty（即使 index 变化） |
- 探针总数仍 < 300（本轮 net +2，约 24 根）。

### 11.4 抓波判读表（isvwr=1 触发，叠加看）

| 现象 | 结论 | 修复方向 |
|---|---|---|
| `dirty_cond2_r` 不脉冲（但 `mwmask_v_r`/`mmreq_r` 脉冲） | (P) gated `mmreq` 写拍缺失 | dirty/数据写改用写有效信号门控，不依赖 gated `mmreq` |
| `dirty_cond2_r` 脉冲 + `lru_wr_r` 不更新 | `if(hit)` 分支未执行（另有隐情） | 查 st0/hit 的当拍组合 |
| `dirty_cond2_r` 脉冲 + `lru_wr_r` 更新 + `dirty_r`/`dirty_wr_d1_r` 仍 0 | (Q) `cache_dirty` 写被吞 | 把 `cache_dirty` 改 way-first（`[0:3][0:31]`，与 cache_lru/cache_addr 一致），或改整字写 `cache_dirty[index] <= cache_dirty[index] | mask` |

### 11.5 待波形确认后再定修复

- 大概率是 (Q)：`cache_dirty` 的 index-first + 单 bit 写导致综合写丢失。若波形坐实，修复 = 把 `cache_dirty` 声明改为 way-first `reg [(1<<WAYS)-1:0] cache_dirty[0:(1<<WAYS)-1][0:(1<<SETS)-1]`，所有访问相应改为 `cache_dirty[i][index]`（读 `wire dirty`、探针、gen2 写）。
- 若波形指向 (P)，修复 = dirty 置位/数据写不再依赖 gated `mmreq`。

---

## 十二、定案：gen2 generate 块的寄存器写在硬件上全部失效 → 移出 generate（2026-09-19 下）

### 12.1 决定性证据（lru_wr_r 不更新）

用户下板波形（`isvwr=1` 触发）：
- `dirty_cond2_r`（`st0 & mmreq & hit & |mwmask & |fit`）**有脉冲**、`mwmask_v_r`/`mmreq_r` 有脉冲、`hit_r` 恒 1、`fit_r=0001`(way0 命中)、`blk_r=0`、`index_r=00`、`tag_r=0x170`(=VRAM 0xB8000)。
- **`lru_wr_r`（`cache_lru[blk=0][index=0]`）恒 0 不更新**。

gen2 hit 分支第一条就是 LRU 写 `cache_lru[i][index] <= fit[i] ? {`WAYS{1'b1}} : ...`，它**不依赖 `|mwmask`**、每次命中（含取指读命中）都写，way0 命中必写 `2'b11=3`。条件全成立却恒 0 → **cache_lru 写从未落地**。dirty 与 LRU 同在 gen2 块 → dirty 写同样全部失效。这解释了 `e0095f9`(独立 if)、`64e0520`(并入 hit 分支) 两次改写法都无效。

旁证：`tag_r=0x170` 且 `hit=1` → VRAM 行 tag 已存入 `cache_addr[0][0]` → **普通 always 块（STATE 块）里的数组写有效**；失效的只有 generate-for 生成的 always 块里的数组写。

附带效应：LRU 从不更新 → `free[0]=~|0` 恒 1 → 每次 miss 都换出 way0 → 系统仍能启动（掩盖问题）。

### 12.2 修复：LRU/dirty 更新移出 generate，改普通 always 块 + 整字写

```verilog
integer w;
always @(posedge clk) begin
    if(st0 && mmreq) begin
        if(hit) begin
            for(w=0; w<(1<<`WAYS); w=w+1) begin
                cache_lru[w][index] <= fit[w] ? {`WAYS{1'b1}}
                    : (cache_lru[w][index] - (cache_lru[w][index] > csblk));
            end
            if(|mwmask)
                cache_dirty[index] <= cache_dirty[index] | fit;   // 命中 way 置 dirty（整字）
        end else begin
            cache_dirty[index] <= cache_dirty[index] & ~free;     // 清 victim/free way dirty（整字）
        end
    end
end
```

- 与原 gen2 逐位功能等价：LRU 逐 way 更新（非阻塞，RHS 全取旧值）；dirty 命中整字置位、miss 整字清 free way。
- 关键差别：**不再用 generate-for**；dirty 用**整字读-改-写**（`| fit` / `& ~free`），彻底绕开 generate 内数组写 + 单 bit 写两个嫌疑点。
- `genvar i` 仍保留（gen1 的 `fit/free/lru` 组合赋值仍用）。

### 12.3 验证判活

1. **辅助**：`lru_wr_r`（`cache_lru[0][0]`）在首次命中后应变 `2'b11=3`（验证移出 generate 后写生效）。
2. **主判**：`isvwr=1` 触发时 `dirty_r` 变 1。
3. 每帧 flush 扫描到 VRAM 行时，`awaddr=0x08068000` 出现 AXI 写事务。
4. 文本 VRAM 最终同步到 DDR，VGA 可见。

---

## 十三、dirty 已置但 0x08068000 无写事务 + 0x40 读偏移根因：状态机提前半行退出（2026-09-19 下）

### 13.1 用户新波形结论

- `dirty_cond2_r` 有脉冲、`lru_wr_r=3`、`hit=1`、`fit=0001`、`blk=0`、`index=00`、`tag=0x170` → **LRU/dirty 更新已生效**（commit `1c2b14e` 的 generate→普通 always 修复成功）。
- 但 `awaddr=0x08068000` AXI 写事务仍抓不到；同时 VGA 读在 `0x08068040` 读到 `aaaaaaaa`，偏移从之前的 0x20 恶化到 0x40。

### 13.2 写回条件 checklist（dirty 已满足，还需以下全部）

| 条件 | 当前状态 | 说明 |
|---|---|---|
| ① dirty bit 置 1 | ✅ 已满足 | `cache_dirty[index]` 在写命中时被置位 |
| ② `auto_flush` 产生 flush 脉冲 | 需确认 | `vblnk` 下降沿应产生 `auto_flush==3'b110`，用 `rflush_r` 判活 |
| ③ `flushcount[7]` 置位 → `r_flush=1` | 需确认 | `flushreq` 被锁存后，STATE 000 置 `flushcount[7]` |
| ④ flush 扫描到脏行所在 index/way | 需确认 | `flushcount` 从当前值自由运行，128 步后回到起点；way=flushcount[6:5]，index=flushcount[4:0] |
| ⑤ 扫描到脏行时 `dirty=\|(free & cache_dirty[index])=1` | 理论上满足 | 若 dirty bit 在 way0/index0，当 flushcount[6:0]=0x00 时 dirty=1 |
| ⑥ STATE 011 把整行脏数据写回 DDR | ❌ 有 bug | 原状态机在 burst **中点**（lowaddr=16）就退出，导致后半行写错地址 |

### 13.3 0x40 偏移根因：状态机在 AXI burst 中点退出

`top_zynq7010.v` 的 AXI FSM 对 cache 读/写命令固定发 **16 拍 burst**（`main_awlen/arlen = 15`），每拍 32 bit（由两个 16 bit `ram_wdata` 拼成），共 **32 个 16 bit 字 = 64 字节**，正好一个 cache line。

但 `cache_controller.v` 原状态机：
- `s_lowaddr5 <= lowaddr[4]` → 高电平对应 lowaddr=16..31；
- STATE 011 在 `if(s_lowaddr5)` 就退出，即 **lowaddr=16（burst 第 17 字）时退出**；
- STATE 111 在 `if(~s_lowaddr5)` 退出，同样是中点附近。

后果：
1. **脏行写回**时，状态机提前进入 STATE 111，执行 `hiaddr <= maddr[20:6]`，把写回地址改成下一行的地址；AXI burst 仍在继续，后半行（32 字节）被写到**错误地址**，产生 0x20/0x40 偏移。
2. **读填充**时，只读了半行就返回 STATE 000，后半行 cache 数据是旧值；后续 CPU 写后半行再写回时，进一步放大错位。
3. 即使 flush 把脏行写回，若写回过程中地址被改，VGA 在预期的 `0x08068000` 就看不到数据，而会在 `0x08068040` 等偏移处看到。

### 13.4 修复：等整行 burst 完成（s_lowaddr5 下降沿）再切状态

新增：
```verilog
reg s_lowaddr5_d1 = 0;
wire s_lowaddr5_fall = s_lowaddr5_d1 & ~s_lowaddr5; // lowaddr 从 31 回绕到 0
```

状态机改动要点：
- 干净 miss：STATE 000 直接进 STATE 111（读填充），不再经 STATE 100/101。
- 脏 miss：STATE 011 等 `s_lowaddr5_fall` 再进 STATE 111；STATE 111 等 `s_lowaddr5_fall` 再回 STATE 000。
- flush：STATE 011 等 `s_lowaddr5_fall` 再进 STATE 100；flush 期间不改 `hiaddr`。
- STATE 100 仅用于 flush 推进；STATE 101 保留但不再使用。

这样确保 AXI 64B burst 完整完成前，状态机不会切走、不会改 `hiaddr`。

### 13.5 下板验证判活

1. `s_lowaddr5`：应为 16 拍低、16 拍高的方波（lowaddr 0..15/16..31）。
2. `s_lowaddr5_fall_r`：每行事务末尾出现 1 拍高脉冲。
3. `dbg_ctl_ddr_wr_r`：flush 时应持续高直到 `s_lowaddr5_fall_r` 脉冲。
4. `awaddr=0x08068000`：dirty 置位后下一帧 vblnk 应出现写事务。
5. `rflush_r`/`flushcount_r`：确认 flush 触发且扫描到 `flushcount[6:0]=0x00`。
6. VGA 读：PS/CPU 写 `0x08068000` 后，VGA 在 `0x08068000`（而非 `0x08068040`）读到新数据。

### 13.6 若仍抓不到 0x08068000 写事务

- 检查 `rflush_r` 是否为 1；若始终 0 → `auto_flush` 未产生 flush 脉冲，查 `vblnk` 连接/auto_flush 逻辑。
- 检查 `flushcount_r` 是否在变化；若卡死 → 状态机仍有死锁，看 `STATE_r`。
- 检查 `flushcount_r` 是否经过 `0x00`；若经过且 `dirty_r` 仍为 1 但无 awaddr → 写回地址计算错误（需再查 hiaddr/sdraddr）。
- 检查 `dirty_r` 是否在 flush 扫描前被清 0 → 有后续 miss 把 way0 踢掉（LRU 不应选 way0，若发生说明 LRU 逻辑仍有问题）。

---

## 八、已规避的坑（对照前几轮）

- ❌ **绝不再用 6-bit `lowaddr` + `s_lowaddr5=lowaddr[5]` + CDC**（4b797fd 死锁根因：`lowaddr[5]` 永不到 → `s_lowaddr5` 恒低 → STATE 011 卡死）。
- ❌ 不再整体回退删 `cache_line_start`/`flush 解耦`（af6f44b 开倒车，导致 isvwr 不触发）。
- ✅ 保留：`map[11]=6`、`sdraddr` 5'b00000（1:1）、`auto_flush[2]|=vblnk`（每帧回写）、`BlackBox` 禁加 for 循环全量填充、四 way index16-31=511。
- ✅ `cache_line_start` 配 5-bit `lowaddr` 是**安全且必要**的（区别于 4b797fd 的 6-bit 方案）。

---

## 十四、八次修复：flush 触发链排除 + 扫描判脏路径定罪（2026-09-19 18:23 波形）

### 14.1 两组波形的判读结论

**图 A（isvwr 触发）**：触发条件不对——isvwr 在行有效期（active video）内每次 CPU 写显存都触发，而 flush 每帧只在 vblnk 下降沿来一次，一张 isvwr 窗口里永远看不到 flush。图 A 里 `auto_flush=4`(100) 反而是**正常**读数：sticky 位 [2]=1（上一帧 vblnk 已锁存过）、移位 [1:0]=00（当前 vblnk 低）——顺带证明 auto_flush[2] 锁存 vblnk 正常。图 A 的真正价值：dirty_cond2/dirty_wr/fit/lru_wr 全部正常，写命中标脏路径无问题。

**图 B（dbg_flush_r 触发）**：flush 链路全程跑通——
1. flush 脉冲出现 → `flushcount` 从 0x00 置位到 0x80（bit7=r_flush 置 1）；
2. 扫描连续推进 0x80→0x81→…→0x97（way0, idx0→23），速率 ≈2 clk_cpu 周期/行（0↔4 循环），与 25MHz 时钟和窗口尺寸吻合；
3. **但 `ddr_wr`/`lowaddr`/`s_lowaddr5` 全程为 0**——扫描对每一行（包括 idx0/way0）都判"clean"，直接 STATE 100 推进，从未进入 STATE 011 写回。

### 14.2 逻辑矛盾与定罪

- 图 B 在 flush 脉冲时刻（扫描前 2 拍）探针显示 `index=00`、`tag=000`、`fit=0001`、`hit=1`、**`dirty_r=0001`**（cache_dirty[0] way0=1，CPU 低内存/显存写入所标）。
- 扫描到 flushcount=0x80（way0/idx0）时 free 应=0001，`dirty=|(0001&0001)=1`，flush 分支必须进 STATE 011 并拉高 ddr_wr——实测却走了 STATE 100。
- **2 拍之内代码上不存在任何清 dirty 的路径**（LRU/dirty 块被 `st0&&mmreq` 门控，扫描期间 mmreq=0）→ cache_dirty[0] 不可能变 0 → 嫌疑唯一收敛到 **generate 内 `free` 的 `r_flush` 二选一 mux 被综合错**（与 gen2 寄存器写失效同类病：generate 结构里的数组/复杂表达式在硬件上失效）。
- **旁证**：cache_dirty 初始化 idx16-31=1111（脏、tag=511）。若这些位活到扫描，flushcount=0x90~0x97（way0/idx16-23）必触发写回，实测推到 0x97 仍无 ddr_wr → 这些位是 boot 期间被正常逐出清掉的，**每次伴随一次垃圾写回**——这正是此前"AXI 写事务只出现在 0x0815FC00 bootstrap 区"的真正来源。**推论：boot 期逐出+写回+AXI burst+STATE 011 整条机器是通的**（否则 boot 会在 STATE 011 等 s_lowaddr5_fall 卡死），坏的只有 flush 扫描判脏这一条组合路径。
- **0x40 偏移现状**：post-boot ddr_wr 从未拉高 → DDR 里没有任何新写入 → 在 0x08068040 看到的 aaaaaaaa 是历史残留数据，不是当前偏移。先让写回发生，再验证落点。

### 14.3 本轮修复内容（commit：八次修复）

1. **候选修复**：`free` 移出 generate 改显式赋值——`free_lru[0..3]` 显式展开 + `scan_free = 4'b0001 << flushcount[6:5]`，`free = r_flush ? scan_free : free_lru`。功能等价、结构不同，绕开 generate 内 per-bit mux 的综合异常嫌疑。
2. **扫描起点归位**：flush 启动时 `flushcount <= 0x80`（原代码只置 bit7、低 7 位保持上轮残值），每轮固定从 way0/idx0 全扫 128 行，捕获窗口可预测。
3. **探针整理**：删除 top_zynq7010.v 全部 AXI mark_debug 探针（改用 system ILA 自动探针）；ddr_186.v 新增规范 clk_cpu 域探针 `dbg_sys_auto_flush_r/dbg_sys_vblnk_r/dbg_sys_flush_r`（板端手加版本采样时钟不明，出现"flush 脉冲 2 拍、脉冲期 auto_flush=4、vblnk 无脉冲"等自相矛盾读数——按 RTL flush 每帧只能持续 1 个 clk_cpu 周期，用仓库版替换）。
4. **定罪探针**：cache_controller.v 新增 `dbg_ctl_flushreq_r`、`dbg_ctl_free_r`、`dbg_ctl_dirtywire_r`（flush 分支实际判据的 dirty 组合线本体）。

### 14.4 下板判据（触发：dbg_sys_flush_r 上升沿，窗口 ≥ 10µs 覆盖整轮扫描）

1. **修复生效**：flushcount 到 0x80 时 `dirtywire_r=1` → ddr_wr 拉高 → STATE 011 → s_lowaddr5 方波 → 用 system ILA 抓 `awaddr=0x08068000` → VGA 更新。
2. **定罪综合异常**：`dirtywire_r` 仍为 0 而 `dirty_r=0001` → free/判脏路径综合异常坐实 → 下一步把 cache_dirty 改 way-first（`reg [0:31] cache_dirty[0:3]`）或改寄存器化判脏。
3. `dbg_sys_flush_r` 应恰好 1 拍高、`dbg_sys_auto_flush_r` 脉冲期读数 6(110)、`dbg_sys_vblnk_r` 在消隐期为一长段高电平。

---

## 十五、十次修复：blk way 错配定案 —— 0x60 偏移与显存 dirty 丢失的共同根因（2026-09-19 20:04）

### 15.1 判别波形结论（假设 B 坐实）

isvwr 触发波形：CPU 写显存时 `tag_r=0x170`、`index=00`、`fit=0001`（way0 命中）、`hiaddr=2e00={0x170,0}`，`dirty_r` 对应位置 1 —— **显存行写命中标脏成功**；但窗口末尾 dirty 被清 0。结合上一轮 flush 波形（way0/idx0 写回的是 tag=0x000 低内存行），证明：**显存行与低内存行同 index=0 互踩，显存行 dirty 在被逐出/清出后丢失，flush 永远扫不到脏的显存行**。

### 15.2 三层根因（本次全部修复）

**① blk way 错配（主犯，0x20→0x40→0x60 偏移的真正根源）**
`blk = flushcount[6:5] | fit编码`：miss 时 fit=0000，blk = flushcount[6:5] 残留值（flush 结束后恒 00=way0），而 victim 实际是 fblk（LRU 生效后轮换到 way1/2/3）。后果：**填充数据写进 way0、tag 记在 fblk；写回把 way0 的数据写到 victim 的地址**——数据/地址 way 错配。原作者代码因 LRU 永不更新（victim 恒 way0）掩盖了此 bug；六次修复 LRU 生效后立刻爆发，偏移随 way 轮换从 0x20 恶化到 0x60。

**② free 多 hot 误清 dirty（显存 dirty 丢失）**
LRU 退化（miss 不更新 LRU）→ 多个 way LRU 同时归 0 → free 多 hot → miss-clear `&~free` 一次清掉多个 way 的 dirty，但写回只写 fblk 一个 way → 其余 free way 脏数据被静默清除，显存行 dirty 就这样丢掉。

**③ flush 写回后 dirty 不清零** → 每帧重复写回同一批行。

### 15.3 修复内容

1. **blk 重定义**：`blk = r_flush ? flushcount[6:5] : (st0 ? fit_enc : vblk)`。新增 `vblk` 寄存器，miss 拍锁存 `vblk <= fblk`——填充/逐出写回的端口 A 永远用 victim way，tag 与数据同 way。
2. **miss 更新 LRU**：victim(fblk) 设为 MRU(3)，其余 >victim 旧值递减——LRU 保持严格排列，free 恒单 hot，杜绝 ②。
3. **miss-clear 只清 fblk way**：`cache_dirty[index] & ~(4'b0001 << fblk)`，不再 `&~free`。
4. **flush 写回后清 dirty**：STATE 011 的 s_lowaddr5_fall 分支（r_flush=1 时）清扫描行对应 way 的 dirty。
5. **LRU/dirty 块加 `~r_flush` 门控**：防止 flush 扫描期间残留 CPU 请求（mmreq=rmreq）误入 miss 分支污染 LRU/误清扫描行。

### 15.4 下板判据

1. **主判**：flush 扫描出现 `sdraddr=0x034000`（= 显存行，物理 0x08068000）→ system ILA 抓 `awaddr=0x08068000` → VGA 文本更新。
2. **副判**：`awaddr` 序列中不再出现与 hiaddr 不匹配的错位写回；0x08068040/0x60 的"偏移残留"不再变化。
3. 若显存行写回出现但 VGA 仍偏移 → 才需要回头查 VGA 读地址（vga_ddr_row_col/scraddr）——即 0x20/0x60 与写回 bug 彻底分离的验证点。

## 第十六节：十一次修复——cache_dirty 双写端口导致 Vivado 综合失败（2026-09-19 20:34）

### 16.1 现象

十次修复 push 后 Ubuntu 机 `git pull` 综合报错：

- `ERROR: [Synth 8-2914] Unsupported RAM template [cache_controller.v:70]`（指向 `cache_dirty` 声明行）
- `Synth 8-5743 Unable to infer RAMs due to unsupported pattern`
- `[Common 17-83] Releasing design: Synthesis failed`

8e85843（八次修复）同一段声明综合通过，差异只有十次修复的改动。

### 16.2 根因

十次修复在 **STATE always 块**（STATE 011 的 `s_lowaddr5_fall` 分支）新增了 `cache_dirty[flushcount[..]] <= ...`（flush 写回后清 dirty），而 **LRU/dirty always 块**本来就在写 `cache_dirty`（写命中置 1 / miss 清 victim）。同一存储数组被两个 always 块驱动 = 两个写端口，且两处写条件/写地址完全独立，Vivado 无法推断成 RAM 模板 → 直接报 Unsupported RAM template 并终止综合。

### 16.3 修复

1. 新增事件线 `wire flush_wb_done = (STATE==3'b011) && r_flush && ddr_wr && s_lowaddr5_fall;`（ddr_wr 在该拍仍为 1）。
2. flush 写回清 dirty 挪入 LRU/dirty 块最前面：`if(flush_wb_done) cache_dirty[扫描行] &= ~(1<<扫描way); else if(st0 && mmreq && !r_flush) ...`。
   - `flush_wb_done` 蕴含 `r_flush=1`，与 else if 的 `!r_flush` 互斥，无优先级冲突。
3. STATE 011 中删去对 `cache_dirty` 的写，仅保留 `ddr_wr <= 0` 与状态切换。

### 16.4 教训（新增勿犯项）

**同一存储数组（cache_dirty/cache_lru/cache_addr/…）严禁在两个 always 块中写**——Vivado 会以 Unsupported RAM template 报错终止综合（多驱动数组不会像单 net 那样报 multi-driven，而是 RAM 推断失败）。十次修复的功能逻辑不变，只是把清 dirty 的写集中到统一的 LRU/dirty 块。

## 第十七节：十二次修复——LRU 退化 + free=0 判脏恒 0：显存行脏数据静默丢失的总根因（2026-09-19 21:47）

### 17.1 决定性波形

1. 触发 `dbg_sys_flush_r`：flush 扫描全程 hiaddr 只有 `0x0000-0x000F`（低内存）与 `0x3FF0-0x3FFF`（bootstrap），显存行 `0x2E00`（tag=0x170）**从未出现**，dirtywire 恒 0 → 写回丢失发生在 flush 之前。
2. 单独触发 `hiaddr=0x2E00`：CPU 写显存标脏正常（dirtywire 先 0 后 1 维持，末状态 1），lru_wr_r 命中后变 3（LRU 更新生效）——但窗口内 **free_r 出现 `4'b0000`（无任何 free way）**，lru_wr_r 长时间为 0。

### 17.2 根因链（定案）

1. bootstrap 区 4 个 way 的 tag 初值均为 511 → CPU 执行 bootstrap 时 **fit 多 hot（1111）** → hit 分支把 4 个 way 的 LRU 全置 3 → LRU 排列 {0,1,2,3} 被破坏；
2. `">ref 才减"` 的 LRU 更新在全 3 态永远减不动 → **free_lru=0000 恒成立**；
3. 旧判脏公式 `dirty = |(free & cache_dirty[index])` 在 **free=0 时恒 0** → **脏 victim 被判 clean** → 不走 STATE 011 写回，miss-clear 清 dirty + 填充直接覆盖 → **显存行脏数据静默丢失，awaddr=0x08068000 永不出现**。

历史之谜闭环：低内存行（way0 初值 tag=0）与 bootstrap（tag=511）因 tag 恰等于 cache_addr 初值而永远 hit，dirty 存活，所以它们能被 flush 写回；显存行 tag=0x170≠初值，每次被挤必丢。原作者设计"能用"恰因 LRU 恒退化到单 hot way0（free 单 hot，判脏有效）；六次修复激活 LRU 后 bootstrap 多 hot fit 打破排列，引爆此 bug。

### 17.3 修复（cache_controller.v）

1. **victim 选择**：不再依赖 "LRU==0"（free 向量编码），改三级比较器选 **LRU 最小 way**（`vmin01`/`vmin23`/`vblk_lru`）。LRU 退化仍可轮转，victim→MRU 的相对更新会逐渐自愈排列。`fblk = r_flush ? flushcount[6:5] : vblk_lru`（flush 扫描语义不变）。
2. **dirty 判定**：`dirty = dirty_word[fblk]`（victim way 自己的 dirty 位），不再经 free 向量 AND。无论 LRU 处于什么状态，**victim 脏必写回**，杜绝静默丢脏数据。
3. `free`/`free_lru`/`scan_free` 保留仅为 ILA 探针观测，主逻辑不再依赖。

### 17.4 下板判据

1. flush 扫描序列（触发 dbg_sys_flush_r）**首次出现 hiaddr=0x2E00**（显存行）→ sdraddr=0x034000 → system ILA 抓 `awaddr=0x08068000` → VGA 文本更新。
2. CPU 清屏写显存后被挤/flush 时不再丢 dirty：isvwr 标脏后 dirty 保持，直到写回或 flush 清除。

## 第十八节：十三次修复——STATE 000→011 写回地址锁存，根治 thrashing 下显存行写回地址被覆盖（2026-09-19 22:10）

### 18.1 决定性波形（用户第 7-8 条）

- 触发 `dbg_ctl_ddr_wr_r` 上升沿后找不到 `0x034000`；触发 `dbg_ctl_dirty_r[0]=0` 抓到 `ddr_wr` 同步拉高，但 `sys_flush_r=0`、`auto_flush=4`（= miss 逐出写回，非 flush）。
- 该时刻 `sdraddr = 0afe00-028020-0afe20-028020-0afe40-028020…`（全是 bootstrap/VGA planar 地址，**无** VRAM `0x034000`）。
- **坐实"显存行写回地址错"**：VRAM 脏行（index0, tag=0x2D0，物理 0x08068000）的 dirty 被 miss-clear 清掉，但发出写回的 hiaddr 已被覆盖为别的行地址，故 VRAM 脏数据静默丢弃、awaddr=0x08068000 永不出现。

### 18.2 根因（定案）

`cache_controller.v` STATE 000 顶部原本每周期执行：
`hiaddr <= dirty ? {cache_addr[fblk][index], index} : maddr[`ADDR-1:`LINE];`
- `fblk`（=vblk_lru，victim）与 `index` 在 **thrashing 连续 miss** 下随 LRU 更新不断变化；
- `hiaddr` 经 `cache_hi_addr` 跨时钟域（cache clk → clk_sdr/clk_cpu）驱动 `sdraddr`/`awaddr`，采样窗口极易抓到被改写后的**瞬态值**；
- 结果：VRAM 脏行的 dirty 在 miss-clear 拍被清，但同拍锁存的写回地址已是别的行（0AFE00/028020），VRAM 写回事务地址错配 → 静默丢失。

（补充：VRAM 物理 0x08068000 → maddr[15:6]=0x200 → index=maddr[10:6]=0、tag=maddr[20:11]=0x2D0，故 `dirty_r[0]` 正是 VRAM 行 index。）

### 18.3 修复（cache_controller.v，commit 86fc7af）

1. 新增冻结寄存器 `wb_hiaddr[`ADDR-`LINE-1:0]`、`wb_way[`WAYS-1:0]`；
2. **删除 STATE 000 顶部每周期重算 hiaddr**，改为在各分支显式赋值，并在"决定逐出"拍（miss 分支 / flush 分支 dirty）锁定 `wb_hiaddr <= {cache_addr[fblk][index], index}`、`wb_way <= fblk`（无论是否 r_flush 都=本拍 fblk，与 wb_hiaddr 同源）；
3. STATE 011 全程 `hiaddr <= wb_hiaddr` 冻结写回地址，地址 way 与数据 way（vblk/wb_way）同源，杜绝 fblk/LRU 漂移导致的地址/脏位/数据错位。

### 18.4 下板判据

触发 `dbg_ctl_ddr_wr_r` 上升沿，写回序列应出现 `sdraddr=0x034000` → system ILA 抓 `awaddr=0x08068000` → VGA 文本更新；0AFE00/028020 残留若仍在属正常 bootstrap/planar 行逐出，但 VRAM 行必须单独出现一次写回。若显存写回出现而 VGA 仍偏移，转查 VGA 读地址（vga_ddr_row_col/scraddr）。

## 第十九节：十五次修复——LRU 轮转根治「显存行永不写回」（2026-09-19 23:53）

### 19.1 定案波形

十四次新增的诊断探针 **`dbg_ctl_vram_wr_r` 永不触发** → 坐实 **VRAM 行从未成为写回 victim**（而非"写回地址错"）。即 0x034000 不出现的原因是**写回事务根本没发生**，不是地址被覆盖。

（同时纠正第十三节的误算：VRAM 行 = `index0` / `tag=0x170` / **`hiaddr=0x2E00`** / 物理 `0x08068000` / `sdraddr=0x034000`。此前误记为 0x2D0。）

### 19.2 根因：LRU 更新两个缺陷叠加 → victim 锁死

`cache_controller.v` LRU/dirty 块的命中分支原为：
`cache_lru[w][index] <= fit[w] ? 3 : (cache_lru[w][index] - (cache_lru[w][index] > csblk));`

1. **多 way 同置 MRU**：bootstrap 期 4 个 way 的 `cache_addr` 同 `tag=511` → `fit` 多 hot（1111）→ 命中分支把**多个 way 同时置 MRU=3**，LRU 出现并列；
2. **并列永不打破**：递减条件用 `>`（仅严格大于才下移）。并列值相等 → 不递减；且当 victim 已是 MRU(=3) 时无人 `>3` → **并列永久保持**。

后果：`vblk_lru`（最小比较器）永远锁死在同一两个 way（并列时 tie-break 固定取小下标），**其余 way 永不成为 victim** → 落在这些 way 上的显存行（index0, tag=0x170）脏数据**永不写回**（`dirty` 一直挂着，永不产生 AXI 写事务）。

### 19.3 修复（commit e998936）

1. **MRU 只置单 way**：命中分支改 `(w == fit_enc) ? 3 : ...`，不再多 way 同置 3（多 hot 时各行 tag 相同、数据等价，取 `fit_enc` 确定的那个，正确性不受影响）；
2. **递减改 `>=` 并 clamp**：`(cache_lru[w][index] >= cache_lru[fit_enc][index]) && (cache_lru[w][index] != 0)` 才减 1——相等也下移以打破并列，`!=0` 防止 2bit 的 `0-1` 回绕成 3（否则 LRU 反而被抬高成 MRU）；
3. miss 分支同样改 `>=` + clamp。

手推验证：退化态 `way0=3,way1=2,way2=2,way3=2` 经 3 次 miss 后收敛为 `0,1,2,3` 严格排列，**4 way 严格轮转**，显存行必被逐出写回。

### 19.4 探针精简（同批）

- `cache_controller.v` 移除 6 个被覆盖/一次性探针：`dbg_ctl_free_r`（free 自十二次修复起退出主逻辑）、`dbg_ctl_mwmask_v_r`、`dbg_ctl_fit_wr_r`、`dbg_ctl_dirty_cond2_r`、`dbg_ctl_dirty_wr_r`、`dbg_ctl_dirty_wr_d1_r`；删除因本修复成为死代码的 `csblk`。
- `ddr_186.v` 移除 4 个：`dbg_cpu_halt`（与 `Next186_CPU.v` 的 `dbg_HALT` 重复）、`dbg_fifo_dout`、`dbg_ram_wdata_lo`、`dbg_fifo_words_r`。
- 生效探针：cache_controller 30→22，ddr_186 12→8（总量远低于 300 上限）。

### 19.5 下板判据

`dbg_ctl_vram_wr_r` **应能触发** → `sdraddr=0x034000` → `awaddr=0x08068000` → VGA 文本更新。同时可用 `dbg_ctl_lru_wr_r` 观察 4 个 way 的 LRU 是否真的轮转（不再长期并列）。

## 第二十节：十七次修复——STATE 000 miss 分支补 `!r_flush` 门控：VRAM 行永不 resident 的根因（2026-09-20 01:46）

### 20.1 定案判据（十六次续粘滞标志）

`dbg_vram_wr_miss_sticky = 1`，而 `dbg_vram_wr_hit_sticky / dbg_flush_vram_seen_sticky / dbg_flush_vram_dirty_sticky` **全为 0**。

⇒ 判为 **A**：**VRAM 访问全是 miss，且 VRAM 行连"干净的"都从未进过 cache**（flush 全扫 128 行，一次都没见过 tag `0x170/0x171`）。

### 20.2 根因：flush 窗口里的 CPU 访问被"静默丢弃"

`fit[i] = ~r_flush && (cache_addr[i][index] == maddr[20:11])` —— **flush 期间 `hit` 被强制为 0**。

而 STATE 000 的 miss 分支**没有 `!r_flush` 门控**：

```verilog
if(mmreq && !hit) begin          // ← 漏了 !r_flush
    if(!r_flush) begin
        cache_addr[fblk][index] <= maddr[20:11];   // flush 期间被挡掉 → tag 不装
    end
    ddr_rd <= ~dirty & ~r_flush;                    // flush 期间恒 0 → 填充也不发
```

于是 **flush 窗口里任何 CPU 请求**（stall 时 `mmreq` 取锁存的 `rmreq`）都会走进 miss 分支，但分支内 **tag 装不上、填充发不出** ⇒ 该次访问被**静默丢弃**：行永不 resident，CPU 重试仍 miss，`dirty` 永远置不上，VRAM 自然永不写回。

这也解释了写回序列里反复出现的 `0afe00 / 028028` —— 那都是被逐出的**非 VRAM 行**。

> 十次修复只给 **LRU/dirty 块**加了 `~r_flush` 门控（防扫描期污染 LRU/误清 dirty），**STATE 的 miss 分支漏了**，此处补齐。

### 20.3 修复（commit 103ca78）

`if(mmreq && !hit)` → **`if(mmreq && !r_flush && !hit)`**。

flush 期间 CPU 请求让位给 flush 扫描分支，**不再被丢弃**（CPU 仍锁存该请求；flush 结束 `r_flush=0` 后被正常服务：tag 正常安装、填充正常发出 → 重试必命中 → `dirty` 能置 1 → 可写回）。

另加确认标志 `dbg_miss_in_flush_sticky`（`st0 && mmreq && r_flush`），用于验证"flush 窗口里确实有待处理 CPU 请求"这一前提。

### 20.4 下板判据

`dbg_vram_wr_hit_sticky` 应变 1（VRAM 写开始命中）→ 随后 `dbg_ctl_vram_wr_sticky_r` 变 1 → `sdraddr=0x034000` → `awaddr=0x08068000` → **VGA 文本更新**。
辅助：`dbg_miss_in_flush_sticky=1` 可确认前述丢弃路径此前确实活跃。

---

### 21. 十八次修复（2026-09-20）：fit 自 generate 改为显式 assign——VRAM 脏位写错 way 致永不写回

下板结果（十七次修复后，`vram_wr_hit=1` 已证明 VRAM 行能 resident，但 `vram_wr=0`/`flush_vram_seen=0`）：

- 用户两条决定性判据：
  1. **`0x034000` 在 `ddr_wr` 下永不出现** → 写回事务从不发生；
  2. **空闲时 `dbg_sdraddr=0x034000` 可触发** → VGA 读地址映射正确（已复核 `vga_ddr_row_col=17'h14000` → `sdraddr=0x034000` → `awaddr=0x08068000`，且写回侧 `sdraddr={memmap_mux[8:0],cache_hi_addr[9:0],5'b0}` 经 `main_awaddr=0x0800_0000+ram_addr*2` 也精确落到 `0x08068000`，地址路径无 bug）。

#### 21.1 根因：fit 在 generate 块内被 Vivado 综合错 → 脏位写进错误 way

`fit[i]` 原在 `gen1` generate-for 内赋值（`assign fit[i] = ~r_flush && (cache_addr[i][index]==maddr[20:11])`）。本 design 的 generate 块曾两度被 Vivado 综合错（见第 8/10/11 次修复注释，gen2 寄存器写失效、free mux 嫌疑同类病），`fit` 即属同一隐患。

位序错乱后两种表象：

- `|fit`（即 `hit`）仍成立 → `vram_wr_hit_sticky=1` 与实测一致；
- 但 `cache_dirty[index] <= cache_dirty[index] | fit`（291-292）把脏位写进"错误 way"。

而 `cache_addr`（命中行 tag）由 **miss 分支的 `fblk`（三级比较器 `vblk_lru`，非 `fit`）** 写入，落在**正确 way**。

后果链：

1. VRAM 行 tag 正确 resident，但**正确 way 的 `dirty=0`**；
2. flush 扫到正确 way 时 `dirty=0` → 不写回；
3. VRAM 行很快被同索引的其它访问（代码/数据在低地址 index0-15）逐出 → tag 被覆盖 → `flush_vram_seen_sticky=0`；
4. 逐出时正确 way 的 dirty 仍为 0 → `ddr_wr` 不触发 → **`0x034000@ddr_wr` 永不出现**（正是用户两条判据）。

> 注：这与"flush 没扫到"是同一现象的两面——VRAM 行在 flush 前已被逐出，而逐出不写回是因为脏位从未落到正确 way。

#### 21.2 修复（commit 55f0dcc）

`fit0..fit3` 改为**显式 assign**，每位精确对应各自 way：

```verilog
wire fit0 = ~r_flush && (cache_addr[0][index] == maddr[`ADDR-1:`LINE+`SETS]);
wire fit1 = ~r_flush && (cache_addr[1][index] == maddr[`ADDR-1:`LINE+`SETS]);
wire fit2 = ~r_flush && (cache_addr[2][index] == maddr[`ADDR-1:`LINE+`SETS]);
wire fit3 = ~r_flush && (cache_addr[3][index] == maddr[`ADDR-1:`LINE+`SETS]);
assign fit = {fit3, fit2, fit1, fit0};
```

脏位随之写对位置，VRAM 行每帧 flush 必被写回 → `sdraddr=0x034000@ddr_wr` 出现。

附：删除十五次修复起已无引用的 `lru[i]` 线网（`{WAYS{fit[i]}} & cache_lru[i][index]`，仅旧 `csblk` 用过），`cache_lru` 寄存器数组与 `dbg_ctl_lru_wr_r` 探针保留。

#### 21.3 下板判据（本轮）

- `dbg_ctl_vram_wr_sticky_r` 应变 1，且 `dbg_sdraddr=0x034000` 在 `ddr_wr=1` 下出现；
- `dbg_flush_vram_seen_sticky` 应变 1（VRAM 行在 flush 扫描中可见，tag 不再被提前逐出覆盖）；
- VGA 文本随清屏更新。

若仍不出现 `0x034000@ddr_wr`，则根因转向"VRAM 行在 flush 前仍被逐出但逐出写回路径本身异常"，需复查 miss 分支 `ddr_wr<=dirty`（345 行）在跨时钟域下 `dirty` 采样。

---

### 22. 十九次修复（2026-09-20）：flush 期间挂起 cache_mem 端口 B——写回读与 CPU 写同字竞争（花屏/字符重叠）

十八次修复后 `0x034000@ddr_wr` 已触发（VRAM 写回发生），但出现**写时序**问题：少量花屏 + 大量字符重叠。VRAMdump（`0x08068000` 起）显示主体为顺序可读字符串（`" SacigBO nSCr ls…"`），仅两处单元损坏——`0x08068048=0x1515`、`0x0806804C=0x8940`，**均属性字节错乱**（attr 0x15/0x89，正常应为 0x01），字符字节也乱。

#### 22.1 错因：写回读与 CPU 写竞争同一 cache 字

`cache_mem` 是真双口 block RAM：端口 A（`ddr_clk`，flush 写回读）+ 端口 B（`clk`，CPU 写）。flush 期间 CPU 被 `ce<=0` 挂起，但请求锁存于 `rmreq`。flush 扫描的 `st0` 周期里：

```verilog
.enable_b(mmreq && hit && st0)   // 原 260 行，未加 !r_flush
```

ce<=0 时 `mmreq=rmreq`，若 held 的 VRAM 写命中，则经端口 B 写入——而此刻端口 A 正对该行做写回读；两端口异步时钟、访问同一 32-bit 字 → 读回陈旧/错乱字节（Xilinx BRAM 读写同地址未定义语义）→ 该单元以损坏值写回 DDR。VGA 在应显新字处显示旧/错字 = **字符重叠 + 花屏**。`LRU/dirty` 块（271 行）早已 `!r_flush` 门控，此处漏了。

#### 22.2 修复（commit 1dbd82f）

`enable_b` 加 `!r_flush`：flush 期间 CPU 写完全挂起（CPU 本就 `ce<=0`），请求在 flush 结束后正常服务，**无功能回退**。

#### 22.3 下板判据

- 清屏后 VGA 文本应无花屏/重叠；VRAMdump 中 `0x08068048`/`0x0806804C` 等单元属性应为 0x01、字符正常；
- 仍用 `dbg_sdraddr=0x034000@ddr_wr` 确认写回持续正确，且无单元属性错乱。
- 若仍有零星花屏：转向 VGA 读路径在写回突发期间的撕裂（DDR 控制器仲裁），可进一步确认 flush 写回是否完全落在 vblank 内。

