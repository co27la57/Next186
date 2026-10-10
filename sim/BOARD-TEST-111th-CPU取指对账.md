# 111th：80186 取指路径对账 —— 判定故障落在 CPU 执行阶段

日期: 2026-10-10  
状态: 探针已打开，待综合抓包

---

## 一、为什么查这个

前面四个环节已逐一用**硬数据**排除，只剩 80186 的执行：

| 环节                                 | 验证方式                                         | 结果                                                                                      |
| ---------------------------------- | -------------------------------------------- | --------------------------------------------------------------------------------------- |
| PS → sysfs → EMIO 引脚               | `kbd_gpio_inject -V` 写完立刻读回 9 根线             | 逐位正确                                                                                    |
| EMIO → FIFO → `s_data` → 端口 `0x60` | ILA 逐拍（`hw_ila_data_1.ila` 的 `waveform.csv`） | 全程 `0x24`，`dbg_src` 全 0                                                                 |
| BIOS 查表地址                          | 静态反汇编 `BIOS_Next186.com`                     | `MOV BX,0xFB09` + `CS:XLAT` → `F000:FB09` ✓<br />`MOV AX,CS:[BX+0xFB7A]` → KeyCode 基址 ✓ |
| BIOS 表内容                           | 卡上 `devmem` 逐字节对照                            | `KeyIndex[0x24]=20`、row20 处 `0x246A`（AL=`'j'`）✓                                         |
| **80186 算出的字符**                    | 干净复测（清 BDA + 清类型缓冲）×3                        | `0x24`→`'4'` ✗ / `0x1E`→`'a'` ✓ / `0x23`→`'h'` ✓                                        |

**⇒ 字节对、BIOS 对、装载基址对，只有执行结果不对。**

### 已排除的其他猜测（不要重复）

- ❌ 字节在传输中被改写 —— ILA 逐拍证伪
- ❌ 鼠标 / 自检应答串扰 —— `dbg_src` 全程 0
- ❌ `dout` mux 抢数据口 —— `dout` 的 `0x14/0x15` 全部对应 `sel_dout=1`（读状态口 `0x64` 返回的状态字节），数据读从未被改写
- ❌ FIFO 堵死 —— `dbg_popped` 正常跳变，`OBF` 正常置位/清零
- ❌ 修饰键状态污染 —— 清 `BDA 0040:0017` 后仍复现
- ❌ BIOS 用 .COM 相对偏移导致段基址错位 —— 实际用绝对段内偏移 `0xFB09`/`0xFB7A`，与 `F000:E000` 装载吻合
- ❌ 查表整体平移 —— 0x24 偏 +31 行、0x05 偏 −1 行，平移量不一致

---

## 二、打开的 9 个 CPU 取指探针

位置：`Next186_CPU.v` 第 1835–1852、1937 行（原本就是注释状态的历史探针）。

| 信号           | 位宽 | 含义                   |
| ------------ | -- | -------------------- |
| `dbg_STAGE`  | 7  | 流水线状态                |
| `dbg_IFETCH` | 1  | 取指有效                 |
| `dbg_FETCH0` | 8  | **当前执行的指令字节 0** ← 核心 |
| `dbg_ICODE1` | 6  | 指令译码级                |
| `dbg_SRST`   | 1  | 复位状态                 |
| `dbg_SINTR`  | 1  | 中断应答状态               |
| `dbg_IACK`   | 1  | 中断应答                 |
| `dbg_IRQ`    | 1  | 有中断请求                |
| `dbg_WR`     | 1  | 写周期                  |

同批在 ILA 里（`KB_8042.v` / `kbd_gpio_rx.v`）：  
`dbg_emio_data` `dbg_emio_stb` `dbg_rx_data` `dbg_popped`  
`dbg_vk_data` `dbg_s_data` `dbg_dout` `dbg_sel_dout` `dbg_src` `dbg_vk_valid` `dbg_vk_ready` `dbg_OBF` `dbg_ctl_outb`

---

## 三、触发条件

```
Trigger mode : BASIC
条件         : dbg_IACK 上升沿        （80186 响应键盘 IRQ 的那一刻）
Capture depth: 2048
窗口         : 前 1024 / 后 1024
```

`dbg_IACK` 比 `dbg_IRQ` 更可靠：它是"CPU 真的进入了中断响应"，说明 `int09` 即将开始取指。

**备选触发**

| 想看什么        | 条件                           |
| ----------- | ---------------------------- |
| 只看取指是否连续    | `dbg_IFETCH` 上升沿             |
| 抓复位打断       | `dbg_SRST` 上升沿               |
| 抓取指停摆（疑似卡死） | `dbg_IFETCH == 0` 持续 > 512 拍 |



---

## 四、判读表（抓包后对照）

### 4.1 先看 `int09` 是否正常取到那两条关键指令

BIOS 映像里的两个 landmark（文件偏移 / 段内地址）：

| 指令                      | 文件偏移     | 段内地址        | 期望 `dbg_FETCH0`          |
| ----------------------- | -------- | ----------- | ------------------------ |
| `MOV BX,0xFB09`         | `0x04F8` | `F000:E4F8` | **`BB`**（随后两拍 `09` `FB`） |
| `XLAT CS:[BX]`          | `0x04FC` | `F000:E4FC` | **`D7`**                 |
| `MOV AX,CS:[BX+0xFB7A]` | `0x0537` | `F000:E537` | **`2E`**                 |

**★ 这三个字节是"路标"。若抓到的 `dbg_FETCH0` 与它们不符（且不是 8086 指令前缀造成的正常错位），就是取指出错。**

### 4.2 再看流水线是否健康

| 现象                             | 判断                            |
| ------------------------------ | ----------------------------- |
| `dbg_STAGE` 卡在某个值不再前进          | 流水线死锁 → CPU 侧 bug             |
| `dbg_IFETCH` 长时间为 0            | 取指停摆                          |
| `dbg_SRST` 在处理过程中跳变            | 发生了复位 → 查 `test_led[1]` 复位粘滞位 |
| `dbg_IACK` 后 `dbg_IFETCH` 迟迟不起 | 中断响应被吞                        |

### 4.3 交叉验证：字节与取指要对得上

同一次抓包里，`kbd_gpio_rx` 的 `dbg_rx_data` 应该出现 `0x24`，  
BIOS 的 `int09` 应该**在同一时间窗内**取到 `BB` / `D7` / `2E` 这三个路标。

**若 `dbg_rx_data` 有 `0x24` 但 `int09` 取指里找不到路标字节 → 确认是 80186 取指出错，且范围已缩到该段（BIOS 的 `E4F8–E537`，位于映像偏移 `0x4F8–0x537`）。**

---

## 五、抓包导出（**不要靠看波形图**）

Vivado 里 `File → Export ILA Data → *.ila`，然后解包读 CSV：

```sh
# 在 Windows 上(Git Bash 可用)
mkdir -p /tmp/ila_x && cd /tmp/ila_x
unzip -o "D:/Xilinx/workspace/Next186/Network/Network.hw/backup/hw_ila_data_1.ila"
# 里面有 waveform.csv —— 直接按列名解析，不要肉眼看波形窗口
```

`waveform.csv` 第 1 行是完整探针路径，第 2 行是进制，第 3 行起是数据。  
按 `Sample in Window` 列排序即可还原时序。

（本轮教训：之前靠看波形图读错过两次 —— 把 `0x14`（读状态口返回的状态字节）当成了被改写的数据字节。以后一律走 CSV 解析。）

---

## 六、相关工具

| 文件                              | 用途                                                |
| ------------------------------- | ------------------------------------------------- |
| `sim/tools/ssh_cmd.py`          | SSH 驱动板子（`root@172.25.82.54` / `1133`）            |
| `sim/tools/vga_text_dump.sh`    | 从 PS 读 80186 的 VGA 文本缓冲 `0x080B8000`，直接看 guest 屏幕 |
| `sim/tools/bios_keymap.py`      | 从 BIOS 二进制解码真实 scancode→ASCII 表                   |
| `sim/tools/bios_keymap_dump.sh` | 板端对照表区（KeyIndex@映像 0x1B09、KeyCode@0x1B7A）         |

**板端快速复测（干净状态）：**

```sh
devmem 0x08000417 16 0        # 清修饰键状态
devmem 0x0800041A 16 0        # 清类型缓冲 head
devmem 0x0800041C 16 0        # 清类型缓冲 tail
echo | ./kbd_gpio_inject -r 24 >/dev/null 2>&1
sh /home/workspace/vga_text_dump.sh 24 1 | grep '^row24'
```
