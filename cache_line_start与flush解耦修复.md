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

## 八、已规避的坑（对照前几轮）

- ❌ **绝不再用 6-bit `lowaddr` + `s_lowaddr5=lowaddr[5]` + CDC**（4b797fd 死锁根因：`lowaddr[5]` 永不到 → `s_lowaddr5` 恒低 → STATE 011 卡死）。
- ❌ 不再整体回退删 `cache_line_start`/`flush 解耦`（af6f44b 开倒车，导致 isvwr 不触发）。
- ✅ 保留：`map[11]=6`、`sdraddr` 5'b00000（1:1）、`auto_flush[2]|=vblnk`（每帧回写）、`BlackBox` 禁加 for 循环全量填充、四 way index16-31=511。
- ✅ `cache_line_start` 配 5-bit `lowaddr` 是**安全且必要**的（区别于 4b797fd 的 6-bit 方案）。
