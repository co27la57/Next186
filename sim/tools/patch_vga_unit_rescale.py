"""patch_vga_unit_rescale.py — 104th：按原版 SDRAM 语义，补齐 VGA 通路"单位换算漏做"

════════════════════ 研究结论（对照 Next186_SoC-master/）════════════════════

原版（作者）:
  · sdram.v : `RD1 = 8'h10 = 16` 个 16-bit 字 = **32 字节** —— cmd 10 (VGA)
              `RD2 = 8'h20 = 32` 个 16-bit 字 = **64 字节** —— cmd 11/01 (cache 一整行)
              ddr_186.v 的注释也写着 `// 10=read 32 bytes, 11=read 64 bytes`
  · sdraddr 单位 = **4 字节**：cache 分支 `{..., cache_hi_addr[9:0], 4'b0000}`（4 个零位），
    且 SDRAM 控制器里 `sdr_ADDR[ColBits-1:0] <= {colAddr, {PitchBits{1'b0}}}`（PitchBits=1）
  · 作者 VGA 常量都是按 4 字节单位写的，注释点名了：
      `vga_lnend = (vgatext[0]|half[0]) ? 6 : ...;  // multiple of 32 (SDRAM resolution = 32)`
      ⇒ [7:3] 每 +1 = 一次 **32 字节** 的 VGA 读
  · 由此推出原版文本模式的显示地址 = 2^17×4B(512KB 孔径) + 0xe000×4B(224KB) = **0xB8000** ✓
    （标准 PC 文本缓冲区地址，反证上述单位推断正确）

移植版（我们）:
  · sdraddr 单位被改成 **2 字节**：cache 分支 `{..., 5'b00000}`（5 个零位）
    + top 里 `main_araddr = 0x0800_0000 + (ram_addr << 1)`
    （已由 devmem 证实：缓冲区 0x080F_0000、行距 64B ✓ 这个改动本身是对的，
      它让 CPU/cache 侧与 64KB 页映射自洽）
  · **但作者的 VGA 常量忘了跟着换算** ⇒ 在 2 字节单位下：
       每次 VGA 读地址只推进 16 字节（原版 32）、字符行只推进 80 字节（原版 160）
  · 而 AXI 侧一次 VGA 读却交了 **64 字节**（16 拍×4B，原版只交 32）
       ⇒ **交 64 / 记 16** ⇒ 相邻事务重叠 3/4 …… 但 FIFO 的门 `!col_counter[4]` 只收 16 个
         半字(32 字节) ⇒ 有效重叠 = 交 32 / 记 16 ⇒ **每 8 字符重复另 8 个**（板上症状 ✓）

⇒ 修法（β，字节级等同原版，且**不动基址**——基址是 BIOS 按移植版映射写进去的，
   已被"屏幕能显示出文本"证实是对的）：
   (1) ddr_186.v  vga_lnbytecount 步进 8 → 16 单位 (= 32 字节，原版 RD1) 
   (2) ddr_186.v  文本模式字符行步进 40 → 80 单位 (= 160 字节，真实 80 列文本行)
   (3) ddr_186.v  文本模式 vga_lnend 6 → 12  (保持"每扫描行 6 次 VGA 读"，192 字节/行)
   (4) top_zynq7010.v  VGA 读 AXI 突发 16 拍 → 8 拍 (= 32 字节 = 原版 RD1)
   作者的**逻辑**（计数语义、max_read、col_counter、FIFO 写门、lnend 计数含义）一个字未改，
   改的只是"数字"，因为它们原来所在的单位（4 字节）在移植时变成了 2 字节。

台架镜像：lnbytecount 步进 + rlast 7；lnend/stride 从命令行传 12 / 80。

用法: python sim/tools/patch_vga_unit_rescale.py [--revert]
"""

import os
import re
import shutil
import sys

T = [('ddr_186.v', 'sim/run/ddr_186.v.preUnitRescale'),
     ('top_zynq7010.v', 'sim/run/top_zynq7010.v.preUnitRescale'),
     ('sim/tb/ddr_pipe.v', 'sim/run/ddr_pipe.v.preUnitRescale')]


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

    # ---------- 1) ddr_186.v：三处"单位换算" ----------
    txt, eol = load('ddr_186.v')

    # (1) VGA 读的地址步进：8 单位 -> 16 单位 (= 32 字节 = 原版 RD1)
    old = ("                    //   正确方向：保持本行语义不变，改为限制 FIFO 每事务接受量 = max_read+1 个半字（待验证）。\n"
           "                    vga_lnbytecount <= vga_lnbytecount + max_read + 1'b1;")
    new = ("                    // ★★★ 104th（2026-09-27）：把\"单位\"补回来。\n"
           "                    //   作者的 vga_lnbytecount 是**4 字节单位**（原版 sdraddr 4 字节/单位，\n"
           "                    //   见 cache 分支的 4'b0000 与 PitchBits=1），所以 max_read+1 = 8 单位 = 32 字节\n"
           "                    //   —— 正是原版 SDRAM cmd10 (RD1 = 8'h10 = 16 个 16-bit 字 = 32 字节)。\n"
           "                    //   移植版把 sdraddr 改成 2 字节/单位后这里没换算 ⇒ 只推进 16 字节，\n"
           "                    //   而 AXI 交回 64 字节(16 拍) / FIFO 收 16 个半字(32 字节) ⇒ 每 8 字符重复。\n"
           "                    //   现在推进 16 单位 = 32 字节 = FIFO 实收量 ⇒ 取回 = 接受 = 推进。\n"
           "                    vga_lnbytecount <= vga_lnbytecount + {max_read, 1'b0} + 2'd2;   // 2*(max_read+1)")
    txt = sub1(txt, old, new, 'ddr stride')

    # (2) 文本模式字符行步进：40 -> 80 单位 (= 160 字节 = 真实 80 列文本行)
    #     注意：只改数字 + 行尾注释（不能把 // 插进语句中间，否则会把语句注释掉）
    old = "vga_ddr_row_col <= vga_ddr_row_col + (vgatext[0] ? 40 : {vga_offset, 1'b0});"
    new = ("vga_ddr_row_col <= vga_ddr_row_col + (vgatext[0] ? 80 : {vga_offset, 1'b0});"
           "   // ★ 104th: 40->80（作者单位=4B，40*4=160B 是 80 列文本行；移植后单位=2B）")
    txt = sub1(txt, old, new, 'ddr row stride')

    # (3) 文本模式 vga_lnend：6 -> 12（保持每扫描行 6 次读：6*16 = 96 单位 = 192 字节）
    old = "wire [4:0]vga_lnend = (vgatext[0] | half[0]) ? 6 : (vga13[0] | planar[0]) ? 11 : 21;"
    new = ("// ★★★ 104th：文本模式 6 -> 12。作者的 6 是\"每次读占 8 个 4 字节单位\"下的读次数门限\n"
           "//   （注释 \"multiple of 32 (SDRAM resolution = 32)\" = 每次读 32 字节）；单位变 2 字节后\n"
           "//   每次读占 16 单位，要保住同样的\"每扫描行 6 次读、共 192 字节\"就得用 12。\n"
           "wire [4:0]vga_lnend = (vgatext[0] | half[0]) ? 12 : (vga13[0] | planar[0]) ? 11 : 21;")
    txt = sub1(txt, old, new, 'ddr lnend')
    open('ddr_186.v', 'w', newline='').write(txt.replace('\n', eol))
    print('ddr_186.v: stride/row/lnend rescaled')

    # ---------- 2) top_zynq7010.v：VGA 读 8 拍 ----------
    txt, eol = load('top_zynq7010.v')
    pat = re.compile(r"[ \t]*main_arlen\s*<=\s*8'd15;")
    if len(pat.findall(txt)) != 1:
        sys.exit('ANCHOR FAIL (top arlen)')
    blk = ("// ★★★ 104th（2026-09-27，纯 AXI 接口侧）：VGA 读 = 8 拍 = 32 字节 = 16 个半字。\n"
           "                                //   原版 SDRAM cmd10 就是 \"read 32 bytes\"（sdram.v `RD1 = 8'h10`\n"
           "                                //   = 16 个 16-bit 字）；FIFO 的 col_counter 也正好收 16 个半字。\n"
           "                                //   cache 填充仍是 16 拍 = 64 字节（原版 RD2 = 8'h20）。\n"
           "                                main_arlen   <= (ram_cmd == 2'b10) ? 8'd7 : 8'd15;")
    txt = pat.sub(blk, txt, count=1)
    open('top_zynq7010.v', 'w', newline='').write(txt.replace('\n', eol))
    print('top_zynq7010.v: VGA read burst -> 8 beats')

    # ---------- 3) 台架镜像 ----------
    txt, eol = load('sim/tb/ddr_pipe.v')
    old = "                        vga_lnbytecount <= vga_lnbytecount + max_read + 1'b1;"
    new = "                        vga_lnbytecount <= vga_lnbytecount + {max_read, 1'b0} + 2'd2;   // [104th] mirror RTL"
    txt = sub1(txt, old, new, 'tb stride')
    old = "wire [4:0] rlast_at = (fix_100[1] && (ar_cmd_l == 2'b10)) ? 5'd3 : 5'd15;"
    new = "wire [4:0] rlast_at = (fix_100[1] && (ar_cmd_l == 2'b10)) ? 5'd7 : 5'd15;   // [104th] VGA read = 8 beats"
    txt = sub1(txt, old, new, 'tb rlast')
    open('sim/tb/ddr_pipe.v', 'w', newline='').write(txt.replace('\n', eol))
    print('tb mirrored: stride + rlast=7 (lnend/stride via CLI: 12 / 80)')


main()
