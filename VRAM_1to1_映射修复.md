# VRAM 1:1 映射修复 —— 消除 CPU 读显存 0xA0 偏移

- 日期：2026-09-18
- 提交内容：`ddr_186.v:707` 行步进 32B→64B + `cache_controller.v map[11]` 11→6 + `ddr_186.v` VGA 文本基址 `0xE000`→`0x14000`
- 关联报告：`report/9.18_错误原因分析.md`（Mac 工作目录，仅本地参考）

---

## 1. 根因

`ddr_186.v:707` 的 cache 行地址拼接只留 **4 个 0**：

```verilog
sdraddr = {memmap_mux[8:0], cache_hi_addr[9:0], 4'b0000}
```

- `cache_hi_addr = maddr[15:6]`（64 字节/行的"行地址"，LINE=6）。
- 物理地址 `= 0x0800_0000 + ram_addr·2`，`ram_addr=sdraddr`。
- 每个 `cache_hi_addr` 步进（=64 逻辑字节）只让物理地址前进 **32 字节** → cache 看到的 VRAM 被 **2:1 压缩**。
- 奇数行整体读偏 −32B。CPU 经 cache 读逻辑第 5 行（0x0B8140，偏移 +0x140）时，AXI 总线 ARADDR = 0x0805C0A0；而 VGA/PS 走线性 1:1 在 0x0805C000 —— 这就是观测到的 **0xA0 偏移**。

VGA 与 PS 本身没问题（它们走物理线性地址），问题只出在 **CPU 经 cache 的 memmap 与物理 1:1 布局不一致**。

---

## 2. 三处修改（已全部写入仓库）

### ① `ddr_186.v:707`（核心）
```verilog
// 改前
{ memmap_mux[8:0], cache_hi_addr[9:0], 4'b0000 }
// 改后
{ memmap_mux[8:0], cache_hi_addr[9:0], 5'b00000 }
```
效果：行步进 32B → 64B，CPU 与 VGA/PS 的 VRAM 布局变为 1:1。
注：`sdraddr` 本身是 24 位 `reg`（ddr_186.v:205），拼接从 23 位变 24 位，**无截断**。

### ② `cache_controller.v` `map[11]`（段 0x0B 文本窗口重定位）
```verilog
// 改前： map[10]=10, map[11]=11
// 改后： map[10]=10, map[11]=6
reg [8:0]map[0:31] = '{ 0,1,2,3,4,5,6,7,8,9,
                        10, 6,        // ← map[11] 由 11 改为 6
                        18,19,20,21,
                        ...};
```
原因：1:1 后若 `map[11]=11`，文本 VRAM 物理基址 = `0x0800_0000 + 11·65536 + 512·64 = 0x080B8000`，**超出 VGA 可达上限 `0x0807FFFE`**（`vga_ddr_row_col` 仅 17 位）。
选 `6` → 基址 = `0x0800_0000 + 6·65536 + 512·64 = 0x08068000`（窗顶 `0x08078000 ≤ 0x0807FFFE` ✓）。

无冲突说明：段 0x06（`map[6]=6`）与段 0x0B 同指 region 6，但 `maddr[15:6]` 行偏移不同（0x060000→物理 0x08060000，0x0B8000→物理 0x08068000），物理地址不重叠，不会互相踩。

### ③ `ddr_186.v` VGA 文本基址（两处，保证一致）
```verilog
// 行 136：初值
reg [16:0]vga_ddr_row_col = 17'h14000;   // 原 17'h0E000
// 行 736：每帧 line-compare 复位
vga_ddr_row_col <= vgatext[0] ? 17'h14000 : 17'h8000;   // 原 17'he000
```
`0x14000 = (0x08068000 − 0x08040000)/2`，使 VGA 文本帧缓冲物理基址与 CPU/PS 对齐到 **0x08068000**。
（VGA 物理基址公式：`0x08040000 + 2·vga_ddr_row_col`，前缀 `6'b000001` 提供 0x08040000 基。）

---

## 3. 配套改动

> 重要澄清：BIOS 是 **硬编码在 cache BlackBox 内的 `bios.mem`**（本次已纳入仓库，开机只从这里取 1KB BIOS，不依赖 SD 卡/外部 BIOS）。所以 `scraddr` 不是"外部改"，而是直接改 `bios.mem` 机器码。

| 项 | 原值 | 新值 | 状态 |
|---|---|---|---|
| CPU VRAM 文本基址（RTL） | 0x0805C000 | **0x08068000** | 已改（`ddr_186.v:707` 5'b00000 + `map[11]=6` + VGA 初值/复位 `0x14000`，见第 2 节） |
| BIOS `scraddr`（机器码） | 0x0000 | **0x3000** | **已改**：`bios.mem` 偏移 0xE9 的 `mov al,0x00` → `mov al,0x30`（CRT 起始地址高字节，commit 见下） |
| PS 测试地址（仅供调试） | 0x0805C000 | **0x08068000** | 你下载 bit 前写 `AAAAAAAA` 并回读确认的地址，需同步改 |

**为什么 scraddr 必须改**：`ddr_186.v:735` 在每帧结束（`s_vga_endframe`）用 `scraddr` 重算 VGA 的 DDR 基址 `vga_ddr_row_col`：
```verilog
vga_ddr_row_col <= {{1'b0, scraddr[15:13]} + (vgatext[0]?4'b0111:4'b0100), scraddr[12:0]};
```
- 原 BIOS 写 `scraddr=0x0000` → 帧末 `vga_ddr_row_col` = `0x7000` → 物理 **0x0804E000**（与 CPU 文本窗 0x08068000 错位）。
- 改 `scraddr=0x3000` → 帧末 `vga_ddr_row_col` = `0x14000` → 物理 **0x08068000**，与行比较复位值（line 736，也是 `0x14000`）及 CPU 文本窗**三者一致**，VGA 稳定读 CPU 写的文本。
- 注：line 736 行比较复位已设为 `0x14000`，但帧末 line 735 的 scraddr 重算若不配套，会在帧边界把基址抖回 0x0804E000；改 scraddr=0x3000 后两处统一，无抖动。

**改动验证**：`bios.mem` 偏移 0xE9 由 `0x00`→`0x30`，低字节（偏移 0xF1）保持 `0x00` → `scraddr=0x3000`；反汇编确认 `0x0E8: B0 30 / 0x0F0: B0 00`，且 "Searching BIOS on SDCard"/"BIOS not found, waiting on RS232" 两串完好。

**图形模式（段 0x0A，`map[10]=18`）**：1:1 后仍落在 0x080E8000（超 VGA 17 位 `vga_ddr_row_col` 可达上限 0x0807FFFE），本次未动。如需图形也 1:1，需把 `map[10]` 降到 ≤6 并同步 BIOS/PS，但会引入与段 0x0A 的 region 复用，建议另议。

---

## 4. 验证（Linux Vivado 机）

- ILA 触发条件：`isvwr==1`（`dbg_ctl_isvwr_r`，cache_controller.v:79）。
- 抓取网：`dbg_sdraddr`[23:0]、`dbg_cache_hiaddr`[14:0]（ddr_186.v:840-841）、`m_axi_araddr`（top 端需补 `(* mark_debug="true" *) wire [31:0] dbg_axi_araddr_full = m_axi_araddr;`）。
- **预期**：改前 ARADDR 步进 0x20；改后步进 **0x40**，且逻辑行 N → 物理 `0x08068000 + 64·N`，**0xA0 偏移消失**。
- 功能：PS 写 `0x08068000=AAAAAAAA`，CPU 清屏（isvwr 触发）后该处应为 `0000`；CPU 写文本到 0x0B8000，VGA 应在 0x08068000 显示，ILA 看 ARADDR 与 PS 写入一致。

---

## 5. 后续处理状态

- `cache_controller.v` `lowaddr` 不复位 / RLAST 提前 —— **已在 commit `cache_line_fix` 修复（见第 6 节）**，二者同源：整行完成位误设在半行处，导致 `ddr_rd` 提前拉低、CPU 行读被腰斩。
- `flush` 推进逻辑（:148-157）—— 原作者原始设计，CPU 空闲时仍推进，**暂未动**。
- 4-way `tag=511`（:60-64）是 bootstrap 冗余，**非 bug，未改动**。

---

## 6. cache 行填充修复（lowaddr 复位 / RLAST 提前 —— 同一根因）

### 6.1 根因（比"不复位"更根本）

- `lowaddr` 原声明为 `[LINE-2:0]` = 5 位（最大 31），但 64B 行 = 32 半字（每 AXI 32 位拍在 `R_PUSH_0/1` 两拍各交付 1 个 16 位半字，`top_zynq7010.v:359` 的 `ram_rd_valid` 两拍都拉高 → 16 拍 = 32 半字）。**5 位计数器根本无法计到 32**。
- 完成信号 `s_lowaddr5 <= lowaddr[LINE-2]` = `lowaddr[4]`（值 16）在**半行（16 半字 = 32 字节）处就置位**。
- 后果：每行只填到 cache_mem 字 0–7（32 字节），`ddr_rd` 在第 8 拍被拉低 → `ddr_186.v` 仲裁把 `ram_cmd` 切回 VGA（优先级 VGA > CPU）→ CPU 行读被腰斩；下一行 `lowaddr` 卡在 16（bit4 恒高）被直接判"已填满" → 后续行全错。
- **之前观测的"RLAST 提前（第 11 拍）"本质是 cache 提前 deassert `ddr_rd` 把事务切断**，不是 AXI 链路 / DDR 配置问题（链路 16 拍回环已 100% 通过）。

### 6.2 修改（`cache_controller.v`，已 commit）

```verilog
// ① lowaddr 扩到 6 位，能计满 32 半字（整 64B 行）
reg [`LINE-1:0]lowaddr = 0;   // 原 reg [`LINE-2:0]lowaddr = 0;

// ② 递增逻辑：整行计满(lowaddr[LINE-1] 置位)后归零，保证每行从 0 开始、行行衔接
always @(posedge ddr_clk) begin
    if(cache_write_data || cache_read_data) begin
        if(lowaddr[`LINE-1]) lowaddr <= {`LINE-1{1'b0}};   // 满 64B 行后归零
        else                lowaddr <= lowaddr + 1'b1;
    end
    ddr_dout <= lowaddr[0] ? cache_QA[15:0] : cache_QA[31:16];
end

// ③ 完成标志改到整行：lowaddr[LINE-1]（原 lowaddr[LINE-2] 误在半行处）
//    s_lowaddr5 <= lowaddr[LINE-1];

// ④ 跨时钟域同步：ddr_clk 的整行完成标志 → clk 域 2 级打拍，避免 1 拍脉冲漏采
reg s_lowaddr5_meta = 0, s_lowaddr5_sync = 0;
always @(posedge clk) begin
    s_lowaddr5_meta <= lowaddr[`LINE-1];
    s_lowaddr5_sync <= s_lowaddr5_meta;
end
always @(posedge clk) begin
    s_lowaddr5 <= s_lowaddr5_sync;   // 状态机仍按"先高后低"脉冲工作
end
```

要点：
- 读侧 `address_b` 用 `maddr[5:2]`（索引 16 字）、写侧 `address_a` 用 `lowaddr[4:1]`（16 字）—— 证明 cache 行就是 64B（16 字），完成位必须到 32 半字，原 `lowaddr[4]` 只填半行是确凿 bug。
- 改后 16 拍读满 64B，`ddr_rd` 保持到整行结束 → AXI FSM 读满 16 拍、`m_axi_rlast` 在第 16 拍正常拉高；"RLAST 提前"随之消失。
- 加了 `lowaddr` / `s_lowaddr5` 的 `mark_debug`，方便 ILA 复测整行填充。

### 6.3 验证（Linux Vivado 机，叠加在 1:1 验证上）

- ILA 增抓：`u_cache_ctl/lowaddr`[6]、`u_cache_ctl/s_lowaddr5`[1]（或 `dbg_ctl_*` 已带）。
- 触发 `isvwr==1`，观察一次 CPU 行读：`lowaddr` 应从 0 递增到 31 后归零（不再停在 16），`s_lowaddr5` 在整行末尾出现一个干净的高→低；`m_axi_rlast` 在第 16 拍拉高（非第 11 拍）。
- 功能：CPU 写文本到 0x0B8000 → VGA 在 0x08068000 完整显示，无半行错位 / 隔行乱码。

> 注：若 1:1 + 本修复后 `m_axi_rlast` 仍早于第 16 拍，才是真正的 Zynq PS **AXI HP 端口 max burst / interconnect `MAX_BURST_LENGTH`** 配置问题，再到 PS 端查（非 RTL）。

---

## 7. Linux（Ubuntu）拉取与覆盖 Vivado 工程（SSH 方式）

> 前提：Ubuntu 机已配置好 **co27la57 自己的 SSH 密钥**（仓库所有者），无需再用 nikoniko6011 协作账号。
> 首次使用前需让 SSH 信任 GitHub 主机（首次 clone 提示 `Are you sure you want to continue connecting` → 输入 `yes`）。

### 7.1 首次 clone（落点由你 `cd` 到的目录决定）
```bash
cd ~/Next186_pull                       # 任意目录，clone 会生成 Next186/ 子目录
git clone git@github.com:co27la57/Next186.git
cd Next186
git log --oneline -3                    # 应看到 ee3e674（含 1:1 + cache 行两套修复）
```

### 7.2 已 clone 过（用别的 remote）→ 改 SSH 并拉最新
```bash
cd /你已有的/Next186
git remote set-url origin git@github.com:co27la57/Next186.git
git pull origin main
```

### 7.3 之后每次拉取新提交
```bash
cd /你的/Next186
git pull origin main
```

### 7.4 ⚠️ 不要整体替换 `sources_1`，只覆盖同名 `.v` / `bios.mem`
Vivado 的 `sources_1` 里除 RTL 的 `.v` 外，通常还有约束 `.xdc`、Block Design `.bd`、IP `.xci` 等；仓库根目录**只有 `.v` + `bios.mem` + 两个 `.md`**，整体替换会删掉约束/IP。

Vivado 工程目录：`/home/oats/workspace/Next186/Network/Network.srcs/sources_1`

**安全做法**：克隆到临时目录 → 先 `ls` 核对文件名一致 → 只 `cp` 匹配的 `.v`（和 `bios.mem`）覆盖 → Vivado 里 Refresh All。

```bash
cd /home/oats/workspace/Next186/Network/Network.srcs
git clone git@github.com:co27la57/Next186.git /tmp/Next186_pull

# ① 先核对两边文件名是否一致（务必执行，避免覆盖错文件）
ls /tmp/Next186_pull/*.v
ls sources_1/*.v                 # 若 .v 在子目录(如 sources_1/imports/)，自行对应
ls sources_1/bios.mem            # 确认工程里是否也有 bios.mem

# ② 仅覆盖同名 .v（不动 .xdc / .bd / .xci）
cp -v /tmp/Next186_pull/*.v sources_1/
# ③ 若工程里也有 bios.mem（cache BlackBox 需要），同样覆盖
cp -v /tmp/Next186_pull/bios.mem sources_1/
```
覆盖后：Vivado 右侧 **Sources → 右键 → Refresh All**（或直接重开工程），新代码生效；`.md` 说明文档不必拷进工程。

> 提醒：若 `sources_1` 把 `.v` 放在子目录（如 `sources_1/imports/`），把上面 `cp` 的目标路径改成对应子目录。

