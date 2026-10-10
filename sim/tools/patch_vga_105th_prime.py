"""patch_vga_105th_prime.py — 105th′：把"第四个量"补上（FIFO 写门窗口 col_counter）

═══════════════════ 这次被忽略的地方 ═══════════════════

作者原版里，VGA 读数有三个量，在**半字口径**下是**同一个数**（同为 16 半字）：

  ① 地址步进   `vga_lnbytecount += max_read + 1`  = 8 单位 × 4B = 32 字节 = **16 半字**
  ② 写门窗口   `col_counter <= {1'b0, max_read, 1'b1}` → 装载 15 ⇒ 开 16 拍 = **16 半字**
  ③ 一次读交付  SDRAM cmd10 `RD1 = 8'h10` = **16 半字**（32 字节）
  ④ 行结束判据 `[7:3] == vga_lnend(=6)`，每次读 [7:3] +1（注释 "multiple of 32"）

移植版把 sdraddr 单位改成 2 字节后，只做了"让交付匹配步进"（105th：4 拍 = 16 字节 = 8 半字），
**但 ② 没跟着改** ⇒ 写门窗口仍是 16 半字，而一次读只交 8 半字
⇒ **每笔 VGA 读之后，写门还开着 8 拍**（台架实测 `col_leftover=7`；作者那版是 15→经过"关闭"⇒ 之后必然关闭）

这 8 拍"开着"的窗口 = **外来数据可以进来的入口**：只要在窗口内有 `!crw` 的 valid
（VGA ack 落进 cache burst 里，cache 剩余拍就会满足 `!crw`），cache 数据就会被写进 VGA FIFO
⇒ 屏幕出现**乱码垃圾**（而不是"重复但可读"）。

台架量化（`col_leftover` = 上一笔 VGA 读结束时 col_counter 的余量，bit4=1 表示写门已关）：
  · 能显示的那一版（16 拍交付 + 窗口 16）：accepted=16, col_leftover=**15**（中途经过关闭）
  · 105th（4 拍交付 + 窗口 16）        ：accepted= 8, col_leftover=**7** ❌ 窗口开着 8 拍
  · **105th′（4 拍交付 + 窗口 8）**     ：accepted= 8, col_leftover=**31** ✅ 结束时正好关闭

⇒ 所以 105th′ = 105th 的三处 + 一处：**让 ② 也等于 (max_read+1)**：
     `col_counter <= {2'b00, max_read};`     // 装载 7 ⇒ 开 8 拍 = 8 半字 = 交付 = 步进
   （作者是 `2*(max_read+1)` 半字的交付 ⇒ 装载 `2*(max_read+1)-1`；我们是 `(max_read+1)` ⇒ 装载 `max_read`）

改动清单（共 4 处）：
  ddr_186.v : ① `vga_lnend` 文本 6→12   ③ 行步进 40→80   ④ `col_counter <= {2'b00, max_read}`
  top_zynq7010.v : ② VGA 读 4 拍 (`(ram_cmd == 2'b10) ? 8'd3 : 8'd15`)
不动：`vga_lnbytecount` 步进、`s_vga_endscanline` 等号判据、FIFO 写门表达式、所有基址常量。

用法: python sim/tools/patch_vga_105th_prime.py [--revert]
"""

import os
import re
import shutil
import sys

T = [('ddr_186.v', 'sim/run/ddr_186.v.pre105thp'),
     ('top_zynq7010.v', 'sim/run/top_zynq7010.v.pre105thp')]


def load(p):
    raw = open(p, 'r', newline='').read()
    c = raw.count('\r\n')
    return raw.replace('\r\n', '\n'), ('\r\n' if c >= (raw.count('\n') - c) else '\n')


def sub1(txt, old, new, tag):
    n = txt.count(old)
    if n != 1:
        sys.exit('ANCHOR FAIL (%s): %d occurrences' % (tag, n))
    return txt.replace(old, new, 1)


def main():
    if '--revert' in sys.argv:
        for p, b in T:
            if os.path.exists(b):
                shutil.copyfile(b, p)
                print('reverted %s <- %s' % (p, b))
        return
    for p, b in T:
        if not os.path.exists(b):
            shutil.copyfile(p, b)
            print('backup: %s' % b)

    d, eol = load('ddr_186.v')

    # ① 文本 lnend：6 -> 12（12 次读 × 16B = 192B，与原版同）
    old = "wire [4:0]vga_lnend = (vgatext[0] | half[0]) ? 6 : (vga13[0] | planar[0]) ? 11 : 21;"
    new = ("// ★★★ 105th'：文本 6 -> 12。作者 6 = \"192 字节 ÷ 每次读 32 字节\"；移植版每次读 16 字节 ⇒ 12 次。\n"
           "//   步进仍是作者的 max_read+1(≤8 单位) ⇒ [7:3] 每读至多 +1 ⇒ 等号判据必中，不会跳格。\n"
           "wire [4:0]vga_lnend = (vgatext[0] | half[0]) ? 12 : (vga13[0] | planar[0]) ? 11 : 21;")
    d = sub1(d, old, new, 'lnend')

    # ③ 文本行步进：40 -> 80 单位（=160 字节）
    old = "vga_ddr_row_col <= vga_ddr_row_col + (vgatext[0] ? 40 : {vga_offset, 1'b0});"
    new = ("vga_ddr_row_col <= vga_ddr_row_col + (vgatext[0] ? 80 : {vga_offset, 1'b0});"
           "   // ★ 105th': 40->80（作者单位 4B: 40*4=160B = 80 列行；移植后单位 2B）")
    d = sub1(d, old, new, 'row stride')

    # ④ 写门窗口：{1'b0,max_read,1'b1}(=16 半字) -> {2'b00,max_read}(=8 半字, 等于 4 拍交付)
    old = "col_counter <= {1'b0, max_read, 1'b1};"
    new = ("// ★★★ 105th'【这次被忽略的那个量】作者的\"步进 / 写门窗口 / 交付\"在半字口径下是同一个数：\n"
           "                    //   他 = 16 半字（装载 2*(max_read+1)-1）；我们 4 拍交付 = max_read+1 = 8 半字\n"
           "                    //   ⇒ 窗口也必须 8 半字 ⇒ 装载 max_read。否则每笔读之后写门还开着 8 拍，\n"
           "                    //   外来(cache)数据会漏进 VGA FIFO ⇒ 屏幕乱码（台架已量化 col_leftover 7 -> 31）。\n"
           "                    col_counter <= {2'b00, max_read};")
    d = sub1(d, old, new, 'col_counter')

    assert "vga_lnbytecount <= vga_lnbytecount + max_read + 1'b1;" in d
    assert "s_vga_endscanline <= (vga_lnbytecount[7:3] == vga_lnend)" in d
    assert ".wrreq(!crw && sys_rd_data_valid && !col_counter[4])," in d
    open('ddr_186.v', 'w', newline='').write(d.replace('\n', eol))
    print("ddr_186.v: lnend 6->12, row 40->80, col_counter window -> max_read")

    t, teol = load('top_zynq7010.v')
    old = "                                main_arlen   <= 8'd15;"
    new = ("                                // ★★★ 105th'（纯 AXI 接口侧）：VGA 读 = 4 拍 = 16 字节 = 8 半字，\n"
           "                                //   与作者步进 max_read+1（2 字节单位 ⇒ 8 半字）一致；\n"
           "                                //   与 col_counter 窗口（8 半字）也一致 ⇒ 三者相等，回到作者的不变量。\n"
           "                                main_arlen   <= (ram_cmd == 2'b10) ? 8'd3 : 8'd15;")
    t = sub1(t, old, new, 'arlen')
    open('top_zynq7010.v', 'w', newline='').write(t.replace('\n', teol))
    print("top_zynq7010.v: VGA read -> 4 beats")


main()
