"""patch_vga_105th.py — 105th：在"作者的步进与判据一个字不改"的前提下修正 VGA 几何

══════════════ 为什么是这个方案（四条约束互相夹出来的唯一解）══════════════

约束①  行结束判据必须保持可用
   作者：`s_vga_endscanline <= (vga_lnbytecount[7:3] == vga_lnend);` 用的是**等号**。
   等号成立的前提是"**[7:3] 每读至多 +1**"，也就是 **stride(单位) ≤ 8**。
   ⇒ 一旦把 stride 翻倍（104th 做过），只要混进任意一次 stride≠16（`max_read` 被钳位、
     或采样瞬间取到 cache 地址而脱掉 16 单位栅格），[7:3] 就会**跳过** `lnend`，
     等式永远不再成立 ⇒ `vga_lnbytecount` 一路加到回绕 ⇒ 显示地址跑飞 ⇒ **黑屏（同步仍在）**。
   ⇒ 所以：**`vga_lnbytecount += max_read + 1'b1` 与那条判据都不能动。**

约束②  一次读的"交付量"必须等于"推进量"（否则就是"每 8 字符重复"）
   移植版 sdraddr 单位 = 2 字节 ⇒ 推进量 = 8 单位 = 16 字节 ⇒
   ⇒ **VGA 读的 AXI 突发必须是 4 拍 = 16 字节**（原版 SDRAM 是 16 拍 32 字节，
     但原版单位是 4 字节，8 单位=32 字节；两者在"交付=推进"这一点上等价）。

约束③  一次扫描行必须扫满整行
   80 列文本行 = 160 字节；每次读 16 字节 ⇒ **需要 12 次读**
   ⇒ `vga_lnend` 文本分支 `6` → `12`（[7:3] 仍是每读 +1 ⇒ 12 必中，判据仍稳）
   ⇒ 扫过量 = 12×16 = 192 字节（与原版 6×32 = 192 字节**逐字节相同**）

约束④  字符行推进必须是一整行
   160 字节 ÷ 2 字节/单位 ⇒ 文本行步进 `40` → `80`
   （作者写 40 是因为他的单位是 4 字节）

汇编后：AR 步进 16 字节、每扫描行 12 次读、扫过 192 字节、字符行 160 字节
     = 与作者原版**逐字节同形**，且**作者的计数器/判据一行未改**。

台架验证（本脚本不改台架：镜像已是 4 拍模型 + 作者步进，lnend/行步进走命令行 12/80）：
  `ddr_pipe.exe 1 1 3 1 2 1 0 3 32 0 12 80 400 0 0 0 2`
  AR: 8068000→8068010→…→80680b0→复位（步进 0x10、12 次/行、192B、基址未动）
  实收流 a000 a001 … a00b 严格单调；FLOW lvl 60~364 / pe高0.14% / underruns=0；
  CONTROL 0x10 / MEASURE 0x20 / mismatched 0/1024 PASS

用法: python sim/tools/patch_vga_105th.py [--revert]
"""

import os
import re
import shutil
import sys

T = [('ddr_186.v', 'sim/run/ddr_186.v.pre105th'),
     ('top_zynq7010.v', 'sim/run/top_zynq7010.v.pre105th')]


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

    # ① 文本模式 vga_lnend: 6 -> 12（保持"每扫描行 12 次读 = 192 字节"，判据仍是作者原文）
    old = "wire [4:0]vga_lnend = (vgatext[0] | half[0]) ? 6 : (vga13[0] | planar[0]) ? 11 : 21;"
    new = ("// ★★★ 105th：文本分支 6 -> 12。作者的 6 = \"192 字节 ÷ 每次读 32 字节\"；\n"
           "//   移植版每次读 16 字节（4 拍×4B），要扫同样 192 字节就得 12 次读。\n"
           "//   注意：**步进仍是作者的 max_read+1（≤8 单位）**，所以 [7:3] 每读仍至多 +1，\n"
           "//   等号判据必然命中 12，不存在 104th 那种\"跳格 ⇒ 失控 ⇒ 黑屏\"。\n"
           "wire [4:0]vga_lnend = (vgatext[0] | half[0]) ? 12 : (vga13[0] | planar[0]) ? 11 : 21;")
    d = sub1(d, old, new, 'lnend')

    # ② 文本模式字符行步进: 40 -> 80 单位（= 160 字节 = 80 列×2B）
    old = "vga_ddr_row_col <= vga_ddr_row_col + (vgatext[0] ? 40 : {vga_offset, 1'b0});"
    new = ("vga_ddr_row_col <= vga_ddr_row_col + (vgatext[0] ? 80 : {vga_offset, 1'b0});"
           "   // ★ 105th: 40->80（作者单位 4B: 40*4=160B = 80 列文本行；移植后单位 2B）")
    d = sub1(d, old, new, 'row stride')

    # 不动：vga_lnbytecount 步进、s_vga_endscanline 判据、col_counter、FIFO 写门、基址
    assert "vga_lnbytecount <= vga_lnbytecount + max_read + 1'b1;" in d, '步进必须保持作者原文'
    open('ddr_186.v', 'w', newline='').write(d.replace('\n', eol))
    print('ddr_186.v: lnend 6->12, row stride 40->80 (步进未动)')

    t, teol = load('top_zynq7010.v')
    old = "                                main_arlen   <= 8'd15;"
    new = ("                                // ★★★ 105th（纯 AXI 接口侧）：VGA 读 = 4 拍 = 16 字节。\n"
           "                                //   移植版 sdraddr 单位 = 2 字节 ⇒ 作者的步进 max_read+1 = 8 单位\n"
           "                                //   = 16 字节 ⇒ 交付必须也是 16 字节 ⇒ 32 位总线 4 拍。\n"
           "                                //   cache 填充/写回仍是 16 拍 = 64 字节（原版 RD2/WR2 = 8'h20）。\n"
           "                                main_arlen   <= (ram_cmd == 2'b10) ? 8'd3 : 8'd15;")
    t = sub1(t, old, new, 'arlen')
    open('top_zynq7010.v', 'w', newline='').write(t.replace('\n', teol))
    print('top_zynq7010.v: VGA read -> 4 beats')


main()
