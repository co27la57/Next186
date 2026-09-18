# Cache 脏行写回修复 —— 让 CPU 写显存真正落到 DDR

- 日期：2026-09-18
- 提交：`cache_controller.v`（flush 扫描与 CPU 访问解耦 + 跳过回填）+ `ddr_186.v`（每帧垂直消隐自动触发 flush）
- 关联问题：下板波形中 `isvwr` 拉高产生密集脉冲（CPU 正在清屏写 00000000）时，AXI 写通道 `awvalid/wvalid` 恒为 0、`AWADDR` 停在 0x08000000，VGA 读不到 CPU 写的内容。
- 关联报告：`report/9.18_错误原因分析.md`（Mac 工作目录，仅本地参考）

---

## 1. 根因（两层）

### 1.1 flush 触发条件被缓存缺失"卡死"

`cache_controller.v` 的脏行写回（STATE 011）原本挂在 `if(mmreq && !hit)` —— **缓存缺失** 分支下：

```verilog
3'b000: begin
    ...
    if(mmreq && !hit) begin   // 只有发生"缺失"才进入写回/回填路径
        ...
        STATE <= dirty ? 3'b011 : 3'b100;
    end else begin
        flushcount[WAYS+SETS] <= flushcount[WAYS+SETS] | flushreq;  // r_flush 置起后一直停在这里
        ce <= 1'b1;
    end
end
```

文本显存 4KB 全部落在 cache 内（cache = 4way×32set×64B = 8KB）。CPU 清屏/填屏时所有写都是 **cache 命中（hit）**，永远不产生 miss。于是：
- `r_flush` 一旦被置起，状态机永远走 `else` 分支、停在 STATE 000；
- 脏的显存行永远不被写回 DDR → 波形表现为 `isvwr` 密集脉冲时 `awvalid/wvalid` 全程为 0。

### 1.2 flush 原本只在软件写端口 0x0001 时触发

`ddr_186.v`：
```verilog
if(WR & AUX_OE) begin
    if(WORD) auto_flush[2] <= CPU_DOUT[0];   // 仅软件写 I/O 端口 0x0001(bit0) 才置位
    ...
end
auto_flush[1:0] <= {auto_flush[0], vblnk};    // shift 寄存器，在 vblnk 下降沿输出一次 flush 脉冲(3'b110)
```

裸机清屏循环等不写该端口的场景里，flush 根本不会触发，脏行永不回写。

### 1.3 次要缺陷：flush 写完后会错误回填并被 STATE 111 卡死

原 STATE 011 写完脏行后固定进 STATE 111 → 101 做"回填"。对 flush 而言：
- 会把**刚写回 DDR 的行**又用 DDR 旧数据覆盖回 cache；
- STATE 111 期间 `ddr_rd=~r_flush=0`、无 DDR 活动，`lowaddr` 计数不推进，`s_lowaddr5` 永不拉低 → 状态机卡在 111。

---

## 2. 修复（两部分，均已写入仓库）

### ① `cache_controller.v` —— flush 扫描与 CPU 访问解耦

STATE 000 增加 `else if(r_flush)` 分支：只要 flush 在进行，无论 CPU 是否访问，都扫描当前行并写回脏行：

```verilog
end else if(r_flush) begin
    flushcount[WAYS+SETS] <= flushcount[WAYS+SETS] | flushreq;
    if(dirty) begin
        ddr_rd <= 1'b0;
        ddr_wr <= 1'b1;
        STATE <= 3'b011;   // 写回当前脏行
    end else begin
        STATE <= 3'b100;   // 当前行干净，直接进入推进状态扫描下一行
    end
    ce <= 1'b0;            // 写回期间挂起 CPU（与正常 evict 一致，避免丢写）
end
```

STATE 011 写完脏行后，flush 路径**直接进 STATE 100 推进扫描**，不再回填：

```verilog
3'b011: begin
    ddr_rd <= ~r_flush;
    if(s_lowaddr5) begin
        ddr_wr <= 1'b0;
        STATE <= r_flush ? 3'b100 : 3'b111;   // flush 跳过 111/101 回填
    end
end
```

STATE 111 在 flush 期间不再改写 `hiaddr`（写回地址已在 STATE 000 锁定）：

```verilog
3'b111: begin
    if(~r_flush) hiaddr <= maddr[`ADDR-1:`LINE];
    if(~s_lowaddr5) STATE <= 3'b100;
end
```

扫描通过 `flushcount` 溢出自然结束：`flushcount = {r_flush, way[1:0], set[4:0]}`，扫完 way=3/set=31 后 `+1` 溢出使 `r_flush(bit7)` 清零，flush 完成，等待下一帧触发。

### ② `ddr_186.v` —— 每帧垂直消隐自动触发 flush

在 `auto_flush` 的 shift 之后追加（与软件写端口 0x0001 并存，自动触发为主）：

```verilog
auto_flush[1:0] <= {auto_flush[0], vblnk};
// ★ 每帧 vblnk 自动置位 auto_flush[2]，shift 寄存器在 vblnk 下降沿产生一次 flush 脉冲
auto_flush[2] <= auto_flush[2] | vblnk;
```

效果：无论软件是否写端口 0x0001，每帧垂直消隐都会触发一次 cache 全扫描写回，CPU 写显存的脏行保证落到 DDR，VGA 下一帧即可读到。

### ③ ILA 探针补充（便于下板验证）

`cache_controller.v` 新增两个合规探针（`reg` + `always` 采样，符合非 top 模块约束）：
- `dbg_ctl_rflush_r` —— flush 扫描进行中（r_flush）
- `dbg_ctl_ddr_wr_r` —— cache→DDR 写回脉冲（应当驱动 AXI `awvalid/wvalid`）

顶层的 AXI 写地址/写数据探针原本就存在（top 模块可用 `wire`），无需改动。

---

## 3. 下板验证预期

触发条件：`isvwr` 拉高（CPU 写显存）后，在每帧 `vblnk` 处应能看到：
1. `dbg_ctl_rflush_r` 拉高若干个时钟（flush 扫描进行）；
2. `dbg_ctl_ddr_wr_r` 随每个脏行写回拉高；
3. AXI 写通道 `AWVALID/WVALID` 不再恒 0，`AWADDR` 在显存区 **0x08068000 附近** 跳动；
4. `AWADDR` 步进为 **0x10**（AXI HP 把 64B 行拆成 4×16B 子 burst，属正常，非 1:1 回归）；
5. VGA 文本屏能随 CPU 清屏/填屏实时更新。

若仍**看不到 `awvalid/wvalid`**：优先排查 (a) VGA 时序是否产生 `vblnk`（无 vblnk 则自动 flush 不触发）；(b) `AWREADY` 是否被 DDR 控制器反压；(c) 顶层的 `m_axi_awaddr` 拼接是否仍依赖旧 `cache_hi_addr` 宽度。

---

## 4. 同步步骤（与历史提交一致）

1. Mac 提交并 push：`git add cache_controller.v ddr_186.v && git commit -m "..." && git push origin main`
2. Ubuntu（Vivado）机：`git pull` 拉取最新 `cache_controller.v` / `ddr_186.v`，覆盖进 `sources_1` 同名文件，重新综合 / 生成 bit。
3. 下板抓 ILA：重点看 `dbg_ctl_rflush_r`、`dbg_ctl_ddr_wr_r`、顶层 `AWVALID/WVALID/AWADDR`。

---

## 5. 备注

- 本修复**不影响**正常 miss→evict 路径（r_flush=0 时逻辑完全保持原样）。
- 自动 flush 每帧回写所有脏行（含代码/数据行，非仅显存），属写回式 cache 的标准做法，DDR 带宽开销可忽略（整 cache 8KB 扫描 << 一帧时间）。
- 仍残留的"非缺陷"现象：文本 VRAM 的 `AWADDR` 步进 0x10（AXI burst 拆分），已在 `VRAM_1to1_映射修复.md` 第 4 节说明，非本次问题。
