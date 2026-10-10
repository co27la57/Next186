# 109th：为什么"复原不回" —— 停在 RS232 = **引导器读 SD 失败**，不是 RTL 问题

日期：2026-09-27
现象：当前板上 dump 的 21 个路标（`0x080FE000`~）仍是"地址图案"、没有 BIOS 映像；
系统停在"找不到 SD 卡 / waiting on RS232"分支。

---

## 1. 决定性依据：引导器源码里那两句话是**两个不同阶段**的提示

```
bootstrap.asm:390   booterrmsg db 'BIOS not present on SDCard last 8KB, waiting on RS232 (115200bps, f000:100) ...',0
bootstrap.asm:69  ; If no SD card detected, wait on RS232 115200bps and load program at F000:100h
```
而卡上 8KB 映像（= 完整 BIOS）里另有一句：
```
card8k.bin 偏移 0x1459 : 'No boot device available, waiting on RS232 (115200bps, f000:100) ...'
```

| 屏幕上出现的是哪句 | 说明卡在哪一级 | 含义 |
|---|---|---|
| **`BIOS not present on SDCard last 8KB, waiting on RS232 ...`** | **引导器（FPGA 预置 1KB）阶段** | **SD 卡的最后 8KB 根本没读出来** ⇒ BIOS 从未载入 ⇒ F 段当然没有映像 ✅ 与你现在的现象吻合 |
| `No boot device available, waiting on RS232 ...` | **BIOS 已载入并运行** | SD 读成功、BIOS 跑了，只是没找到可引导设备 |

⇒ **请把屏幕上的原文（或最接近的一句）告诉我**，这一步就能定案。

## 2. 为什么"F 段没有 BIOS 映像"是**结果**而不是原因

引导器源码（`bootstrap.asm`）：
- `org 100h ; this code is loaded at 0f000h:100h` —— 引导器**预置在 cache 里**（最后 1KB / 4 条 cache line，
  dirty 位已置），复位后 CPU 直接执行它；
- 载入 BIOS 的部分：
  ```
  BIOSOK:
      mov  si, reloc + BOOTOFFSET - begin
      mov  di, bx
      mov  cx, endreloc - reloc
      rep  movsb        ; relocate code ...
      mov  di, -BIOSSIZE*512      ; = 0xE000  → F000:E000
      xor  si, si
      mov  cx, BIOSSIZE*512/2
      jmp  bx
  reloc:
      rep  movsw        ; ← 把 SD 读进来的 8KB 搬到 F000:E000
      db   0eah
      dw   0, -1        ; CPU reset, execute BIOS
  ```
  ⇒ **BIOS 的落点就是 F000:E000**（=`0x080F_E000`）；
- 所以：**SD 没读成 ⇒ 没有搬运动作 ⇒ `0x080F_E000` 自然是空的（那里残留的是 cache 逐出/探测写回的数据，
  就是你 dump 到的"地址图案"）**。

⇒ 换句话说：**"没有 BIOS 映像"和"停在 RS232"是同一件事的两个表现**，根因是 **SD 读取失败**。

## 3. 这不是 RTL 问题（附证据）

- `ddr_186.v` 当前与"那次能读对 SD 8KB、进键盘等待循环"的版本 **功能性代码零差异**（逐行核对：差异全在探针块/注释）；
- 该状态已提交并推送：`79b02d5`；
- 引导器不在 `ddr_186.v` 里 —— 它是**FPGA 预置的 cache 初值**（`Next186_SoC-master/cache_bootload.mif` / 卡上 8KB 的前 1KB），
  和 Tcl/综合配置有关，**这几轮我没动过它**；
- ⇒ 所以"复原不回"的观感来自：**这次上板 SD 卡没被读出来**，而不是 RTL 没回退。

## 4. 最可能的原因（按可能性排序）

1. **SD 卡没插到位 / 接触不良** —— 你为了在 PC 上读卡尾 8KB，把卡拔出来过；
2. **卡里的映像变了**（PC 上比对过的那份 `card8k.bin` md5 = `265f12299ae6951c6baa3b3ccec933a3`）；
3. **板上跑的不是回退后的 bitstream**（`reset_run synth_1/impl_1` 是否真的重跑过）；—— 最简单的判别：
   **屏幕上还是"每 8 个字符重复"（= 回退版）还是 105th 那种彩色乱码（= 没换）**；
4. SD 电气/供电（较少见，之前是好的）。

## 5. 立刻能做的三个检查（都不需要重新综合）

**① 报原文**：屏幕上是 `BIOS not present on SDCard…` 还是 `No boot device available…`（见 §1 表）。

**② ILA 读 SD 探针**（这几个还在，且 `cslow`/`rxnz` 是**粘滞**的 —— 复位后有没有发生过一眼就能看）：

| 探针 | 含义 | 判读 |
|---|---|---|
| `dbg_sd_cslow` | 粘滞：CS 曾被拉低过 | 0 ⇒ **引导器从未选中过卡**（根本没进 SD 通信） |
| `dbg_sd_rxnz` | 粘滞：MISO 曾被拉低过（卡有响应） | **0 ⇒ 卡从未响应** ⇒ 卡/插位/接线（不是 RTL）✅；1 ⇒ 卡有响应，问题在协议/时序 |
| `dbg_sd_do` / `dbg_sd_di` / `dbg_sd_ck` | 当前 MISO/MOSI/SCLK | 看是否还在位敲 |
| `dbg_sd_ncs` | CS 拉低次数（16bit） | 0 ⇒ 同上 |
| `dbg_cpu_lport` | 最后 I/O 端口 | `0x03DA` ⇒ 还在 SD 位敲循环；`0x0040` ⇒ 已进 RS232/PIT 等待 |

**③ 核对卡与 bitstream**
- PC 上再读一次卡尾 16 扇区，`md5sum` 是否仍为 `265f12299ae6951c6baa3b3ccec933a3`；
- 板子重新插卡、按复位，看屏幕是否变成"每 8 字符重复"（= 回退版生效）。

## 6. ★ 已确认恢复 + 内存/显存 dump 指令（附上次同状态参考值）

`0x080F0000` 与 `0x080FE000` 首 16 字节都 = `4E 65 78 74 31 38 36 20 4E 65 70 74 55 4E 4F 20`（"Next186 NeptUNO"）
⇒ **SD 读到 + 8KB 搬进 F000:E000，现象已恢复到之前** ✅

### ① 文本显存（每格 16bit = 属性<<8 | 字符；属性 0x01 = 蓝字）

```sh
# 整屏 80x25 = 4000 字节 = 2000 格
b=$((0x08068000)); i=0
while [ $i -lt 4000 ]; do printf "%08x: " $((b+i)); devmem $((b+i)) 16; i=$((i+2)); done > /tmp/vram.txt
wc -l /tmp/vram.txt          # 应为 2000

# 快速看前两行（160 字节）
b=$((0x08068000)); i=0; while [ $i -lt 160 ]; do printf "%08x: " $((b+i)); devmem $((b+i)) 16; i=$((i+2)); done
```
判读：低字节 = 字符码，高字节 = 属性；`0x0000` = 该格从未写过。
上次同状态时这一屏是 `"Searching BIOS on SDCard (last 8KB and first sectors) .........."`。

### ② IVT（中断向量表，0x08000000）：确认 BIOS 已装好向量（最强静态证据）

```sh
for a in 0x08000020 0x08000040 0x0800004C 0x08000058 0x08000064 0x08000068 0x08000070 0x08000080 0x08000084; do
  printf "%08x: " $a; devmem $a 32
done
```
| 地址 | INT | 上次同状态的值（32bit 字 = 段<<16 \| 偏移）|
|---|---|---|
| `0x08000020` | 08 定时器 | `0x00700048` |
| `0x08000040` | 10 视频 | `0xF000E599` |
| `0x0800004C` | 13 磁盘 | `0xF000EE60` |
| **`0x08000058`** | **16 键盘 ★** | **`0xF000F336`** |
| `0x08000064` | 19 引导 | `0x00E3142F` |
| `0x08000068` | 1A 时间 | `0xF000F4BA` |
| `0x08000070` | 1C 定时 | `0xF000F5E3` |
| `0x08000080` | 20 退出 | `0x00E313F7` |
| `0x08000084` | 21 DOS | `0x00E313FF` |

### ③ 低端内存里那段"键盘等待循环"代码（0x08000800~0x080008FF，64 个字）

```sh
b=$((0x08000800)); i=0
while [ $i -lt 256 ]; do printf "%08x: " $((b+i)); devmem $((b+i)) 32; i=$((i+4)); done
```
上次同状态的参考（供比对，摘自那时的 4KB dump）：
```
0x880: C0 75 1E B4 | 0x884: 01 2E 02 26 | 0x888: 2A 01 CD 16 | 0x88C: 74 24 E8 BC
⇒ 0x08000880 = 0xB41E75C0、0x08000884 = 0x26022E01、0x08000888 = 0x16CD012A(内含 CD 16 = int 16h)
```

### ④ BIOS 数据区（BDA）：键盘缓冲头/尾指针

```sh
devmem 0x08000418 32      # 期望 0x001E0000（0x418 状态字节 + 0x41A 头指针 = 0x001E）
devmem 0x0800041C 32      # 期望 0x0000001E（0x41C 尾指针 = 0x001E）
devmem 0x08000410 32      # 设备字，上次 = 0x80000020
```
**头 == 尾 == 0x1E ⇒ 键盘缓冲是空的 ⇒ 还没有按键被按** ⇒ 与"在等键"一致。

### ⑤ 真正的"当前状态"要看 ILA（静态 dump 只能说明启动走到哪一步）

| 探针 | 期望（= 停在键盘等待循环）|
|---|---|
| **`dbg_cpu_lport`** | **`0x0064`**（键盘状态口；`0x03DA` 表示还卡在 SD 位敲，`0x0040` 表示已进 RS232/PIT 等待）|
| **`dbg_cpu_laddr`** | 落在 `0x00087B`~`0x0008D3` 附近（就是上面那段循环）|
| `dbg_cpu_ios` | **隔几秒连读两次，数值在涨** ⇒ 说明确实在反复轮询键盘（不是死住）|
| `dbg_cpu_lwr`/`dbg_cpu_pwr` | 该循环以读为主（`lwr=0`）|

**判据**：`lport=0x0064` + `laddr` 在上述范围 + `ios` 在涨 ⇒ **确认停在键盘等待循环** ✅

