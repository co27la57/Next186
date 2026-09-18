# Next186 SoC：cache 行内 0x20 半行错位修复 + VRAM 不更新根因分析

> 关联 commit：`d2f6553` 之后（本次修复）
> 改动文件：`cache_controller.v`、`ddr_186.v`、本说明文档
> 仅此一份说明文档随本次 commit 提交（符合"只带一份最新 markdown"约束）

---

## 一、下板两个新现象回顾

1. **写通道 isvwr 拉高时 AXI 写事务静默**，isvwr 低时反而有写事务。
2. **读偏移 0x20**：PS 向 `0x08068000` 写 `aaaaaaaa` 后，PL 端 80186 CPU 在 `0x08068000` 读出全 0，却在 `0x08068020` 才读到 `aaaaaaaa`。

---

## 二、现象一（isvwr 期间无写事务）的真实性质

`isvwr`（`is_video_wr`）在 `cache_controller.v` 里**只是 ILA 探针**（`is_video_wr = is_video_mem & |mwmask`，line 86-87、240-241），**不参与任何主逻辑**。

- CPU 写显存（段 `0xB800` → `maddr[20:16]=11` → `map[11]=6` → 物理 `0x08068000`）时，数据先进入 cache 行并标脏（`cache_dirty` 置位），**不会立刻发 AXI 写**。
- AXI 写回由**每帧 vblnk 下降沿的 flush** 触发（`auto_flush==3'b110`，`ddr_186.v:796-802`），扫描 4-way×32-set 把所有脏行写回 DDR。
- 第三张波形图（`isvwr=0`、`IP=0002`、`IADDR=000000`）里出现的 `AWADDR=0x0815Fxxx` 写事务，正是 flush 在垂直消隐间隙把脏行写回——只是那次抓到的是 BIOS/高位幽灵区（`map[15]=21`）的脏行，因为当时恰好只有那些行是脏的。

**结论**：写事务集中在 CPU 不写显存的消隐间隙，是 write-back cache 的正常时序，**不是 AXI 写通道锁死**。

> **但用户指出的"VRAM 不变"是更深层的真问题**（见第三节）：写事务虽然发生，但**写回的数据落在了错误的行内偏移**，导致 DDR `0x08068000` 区域看起来"一点没变"。

---

## 三、现象二（0x20 偏移）根因：lowaddr 行内偏移计数器不复位 → 半行错位

### 3.1 数据通路回顾

- cache 行 = 64 B = 32 半字，行内偏移由 `lowaddr`（`ddr_clk` 域 6 位计数器）给出。
- **填充（DDR→cache，STATE 111）**：DDR 顺序返回半字 `k=0..31`，依次写入 cache 字 `floor(k/2)` 的半字位 `k[0]`，地址 `address_a = {blk, ~index[4], index[3:0], lowaddr[4:1]}`。
- **写回（cache→DDR，STATE 011）**：同一条 `lowaddr` 把 cache 字顺序发回 DDR。
- **CPU 读/写（port B）**：`address_b = {blk, ~index[4], index[3:0], maddr[5:2]}`——与填充侧**同一套行内字索引**。

行基址 `sdraddr = {memmap_mux, cache_hi_addr[9:0], 5'b0}` 已验证对 `0x08068000` 正确（见附注），所以偏移**只可能发生在行内**。

### 3.2 出错机理

`lowaddr` 只在计到 `lowaddr[5]==1`（值 32）时才归零（`cache_controller.v` 旧逻辑）。如果**上一条 cache 事务结束时 `lowaddr` 停在 16（或 15，下一拍进到 16）**，下一条行填充就会从 16 计到 32，而状态机在 `lowaddr=32` 拉高 `s_lowaddr5` 即认为"整行完成"，于是**只填了 cache 字 8~15**，却把 DDR 前半行数据（字节 0~31，含 `aaaaaaaa`）塞进了 CPU 地址 `0x08068020` 对应的字 8 处：

- CPU 读 `0x08068000`（字 0）→ 仍是旧 0；
- CPU 读 `0x08068020`（字 8）→ 读到 DDR 字节 0 的 `aaaaaaaa`。

这正是用户观测到的 **0x20（= 16 半字 = 半行）偏移**，也是为什么"VRAM 看起来一点没变"——CPU 写的内容被放到了行内错位的位置，DDR `0x08068000` 那一半里留下的还是旧数据（0 或测试用的 `aaaaaaaa`）。

> 用户的两个实测完全印证这一点：
> - `devmem 0x08068000..0x0806807E` 看到的全 0——CPU 清屏写的 0 落在错位处，DDR 物理行首那一半仍是旧 0；
> - 下载 bit 流前写到 `0x08068000` 的 `aaaaaaaa` 久后仍在——因为 CPU 后续写的内容被错放到 `0x08068020` 一带，DDR 行首那一半（含 `aaaaaaaa`）从未被覆盖。
>
> 所以"VRAM 数据一点没变"**恰恰证明 cache 写回（flush/驱逐）没有把 CPU 的内容正确落到 DDR `0x08068000`**，是 bug，不是 write-back 的"正常延迟"。我上一轮把它归为"正常时序"是判断不全，特此更正。

### 3.3 为什么写通道"有事务但 VRAM 不变"不矛盾

写事务（AWVALID/WVALID）确实在 vblnk 发生了，但**写回的行内数据被 lowaddr 错位了 0x20**，于是：
- 行基址对（写回仍去 `0x08068000`），但行内半字整体平移半行；
- DDR `0x08068000` 的那一半（字节 0~31）保留旧值，CPU 真正写的内容出现在 `0x08068020`，甚至（清屏写 0 时）整行都错放在别处 → VRAM 看起来没更新。

修复后，每行都从 `lowaddr=0` 开始，写回数据才会正确落在 `0x08068000` 起的那一半，VRAM 才会真正反映 CPU 清屏/写串的结果（届时用户下板前写的 `aaaaaaaa` 会被 OS 的清屏 0 覆盖——这是**正确**行为）。

---

## 四、修复方案（已实现）

**思路**：在每次 cache 行事务开始（DDR 命令确认跳变）时，用单周期脉冲把 `lowaddr` 强制归零，保证填充/写回都从字 0 起算；AXI 的 WREADY 停顿不会误触发复位（脉冲只在命令确认沿产生一次）。

### 4.1 `ddr_186.v`（clk_sdr 域）

在 `sys_cmd_ack` 边沿检测处增加：

```verilog
reg cache_line_start = 1'b0;   // cache 行事务开始脉冲
always @ (posedge clk_sdr) begin
    sys_cmd_ack_d1 <= sys_cmd_ack;
    // 仅在 cache 读(2'b11 填充)/写(2'b01 写回)命令确认跳变时产生单周期脉冲；
    // VGA 读(2'b10)与空闲不产生脉冲。
    cache_line_start <= (sys_cmd_ack != 2'b00) && (sys_cmd_ack_d1 == 2'b00) &&
                        ((sys_cmd_ack == 2'b01) || (sys_cmd_ack == 2'b11));
end
```

并在 `cache_controller cache_ctl` 例化中连线：`.cache_line_start(cache_line_start)`。

### 4.2 `cache_controller.v`（ddr_clk 域，与 `ddr_clk` 同源，无需额外同步）

新增输入端口 `input cache_line_start;`，并在 `ddr_clk` 计数器逻辑前置复位：

```verilog
always @(posedge ddr_clk) begin
    if(cache_line_start) lowaddr <= {`LINE{1'b0}};          // 每行事务开始强制归零
    else if(cache_write_data || cache_read_data) begin
        if(lowaddr[`LINE-1]) lowaddr <= {`LINE-1{1'b0}};    // 计满 32 半字后归零
        else                lowaddr <= lowaddr + 1'b1;
    end
    ddr_dout <= lowaddr[0] ? cache_QA[15:0] : cache_QA[31:16];
end
```

**效果**：每个 cache 读/写行都从字 0 开始填充/写回，行内 0x20 半行错位消除；VGA 读（`crw=0`，不产脉冲）不受影响，flush 扫描 128 行每行都正确归零。

---

## 五、验证计划（提交后由用户在 Ubuntu 机下板）

1. `git pull` → 同名覆盖 `sources_1` 的 `cache_controller.v` + `ddr_186.v`（与 `Next186_BlackBoxes.v` 同版本）→ Vivado 综合/生成 bit → 下板。
2. **读偏移**：PS 向 `0x08068000` 写 `aaaaaaaa`，PL CPU 读 `0x08068000` 应直接得到 `aaaaaaaa`（不再跑到 `0x08068020`）。
3. **VRAM 更新**：触发 `isvwr==1`，抓 `u_cache_ctl/lowaddr` 应见 `0→31` 归零、`s_lowaddr5` 每行末单脉冲；再 `devmem 0x08068000..0x0806807E` 应能看到 CPU 清屏/写串的真实内容（不再是全 0 或残留 `aaaaaaaa`）。
4. 推荐新增抓网：`dbg_sdraddr`（`u_system`）、`dbg_cache_hiaddr`、`dbg_cache_ddr_wr`，并在 vblnk/fush 期间确认 video 行（`hiaddr[14:10]=11`、`hiaddr[9:0]=0x200` → `sdraddr=0x34000` → 物理 `0x08068000`）被写回。
5. 若修复后 VRAM 仍不对，则下一步排查 flush 是否真正覆盖 video 区脏行（`dbg_cache_ddr_wr` 是否在 `sdraddr=0x34000` 一带拉高）。

---

## 附注：行基址 sdraddr 对 0x08068000 已验证正确（非本次偏移来源）

- `map[11] = 6`、`maddr[15:6] = 0x200`、物理 = `0x0800_0000 + 6·65536 + 0x200·64 = 0x08068000`。
- `sdraddr = {memmap_mux[8:0], cache_hi_addr[9:0], 5'b0}`：`memmap_mux = map[hiaddr[14:10]] = map[11] = 6`，`cache_hi_addr[9:0] = maddr[15:6] = 0x200`。
- → `sdraddr = 6<<15 | 0x200<<5 = 0x30000 | 0x4000 = 0x34000`；物理 = `0x0800_0000 + 0x34000*2 = 0x08068000` ✓。
- 故 0x20 偏移**纯属行内 lowaddr 错位**，已用本节方案修复。
