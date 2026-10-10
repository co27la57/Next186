"""patch_vgaunit2x.py — 103rd 修正版：补齐"移植时 sdraddr 单位从 4 字节改成 2 字节"后
                          VGA 侧漏掉的两处换算（RTL + 台架镜像）

研究结论（原版 Next186_SoC-master 对照）：
  原版 sdram.v : `RD1 = 8'h10 = 16` 个 16-bit 字 = **32 字节**  -> 注释直接写 "10 = read 32 bytes"
                 `RD2 = 8'h20 = 32` 个 16-bit 字 = **64 字节**  -> cmd 11 / 01（cache 一整行）
  原版 ddr_186.v: sdraddr 的 cache 分支 = `{..., cache_hi_addr[9:0], 4'b0000}` -> **单位 = 4 字节**
                 （`PitchBits=1` + SDRAM 控制器 `{colAddr, 1'b0}` 与此一致）
  移植版        : sdraddr 的 cache 分支 = `{..., 5'b00000}` + `main_araddr = 0x0800_0000 + (ram_addr<<1)`
                 -> **单位 = 2 字节**（已被 devmem 证实：缓冲区在 0x080F_0000、行距 64B ✓）
  原版作者的 VGA 常量全是按 4 字节单位写的，且注释点名了：
                 `vga_lnend = ... ? 6 : ...;  // multiple of 32 (SDRAM resolution = 32)`
                 —— [7:3] 每 +1 就是一次 **32 字节** 的 VGA 读。
  移植后这些常量没跟着换算 ⇒ 在 2 字节单位下：
                 · 每次 VGA 读的地址推进只有 16 字节（原版 32）⇒ 整个 VGA 地址空间压缩 2 倍
                 · 而 AXI 侧一次 VGA 读却交 64 字节（16 拍 × 4 字节，原版只交 32）
                 ⇒ **交付 = 记账的 2 倍** ⇒ 相邻事务重叠 ⇒ "每 8 个字符截断并重复另 8 个"

  ⇒ 正确修法 = 把这两处 AXI/地址侧的换算补齐，作者其它常量（max_read / col_counter /
    vga_lnbytecount 步进 / vga_lnend=6 / 行步进 40 / FIFO 写门）**一个字都不用改**：
      (1) VGA 读的 AXI 突发 = 8 拍 = 32 字节 = 16 个半字（= 原版 RD1）→ top_zynq7010.v
      (2) sdraddr 的 VGA 分支 ×2（补上单位换算）→ ddr_186.v + 台架镜像

用法：
  python sim/tools/patch_vgaunit2x.py            # 应用
  python sim/tools/patch_vgaunit2x.py --revert   # 回退
"""

import os
import re
import shutil
import sys

TARGETS = [
    ('ddr_186.v', 'sim/run/ddr_186.v.preUnit2x'),
    ('top_zynq7010.v', 'sim/run/top_zynq7010.v.preUnit2x'),
    ('sim/tb/ddr_pipe.v', 'sim/run/ddr_pipe.v.preUnit2x'),
]

OLD_VGA_BRANCH = "{6'b000001, vga_ddr_row_col + vga_lnbytecount}"
NEW_VGA_BRANCH = "{5'b00001, vga_ddr_row_col + vga_lnbytecount, 1'b0}"

OLD_ARLEN = "main_arlen   <= (ram_cmd == 2'b10) ? 8'd3 : 8'd15;"
NEW_BLOCK = """// ★★★ 103rd 修正版（2026-09-27，纯 AXI 接口侧）：VGA 读取 8 拍
                                //   = 32 字节 = 16 个半字 —— 正是原版 SDRAM 的 cmd10/RD1
                                //   （sdram.v: `RD1 = 8'h10` = 16 个 16-bit 字 = 32 字节，
                                //     ddr_186.v 注释 "10=read 32 bytes"）。
                                //   原版：交 32 字节 / 记账 32 字节（vga_lnbytecount += 8，
                                //         单位 4 字节）= 一致；FIFO 的 col_counter 也正好收 16 个半字。
                                //   移植版曾一律发 16 拍(64B)：交 64 / 记账只有 16 字节（单位变 2 字节
                                //         但常量没换算）⇒ 交付是记账的 2 倍 ⇒ 每 8 字符重叠重复。
                                //   配合 ddr_186.v 的 VGA 地址分支 ×2（patch_vgaunit2x.py），
                                //   交付 = 接受 = 推进 = 32 字节，与原版字节级等价。
                                main_arlen   <= (ram_cmd == 2'b10) ? 8'd7 : 8'd15;"""


def load(path):
    raw = open(path, 'r', newline='').read()
    crlf = raw.count('\r\n')
    bare = raw.count('\n') - crlf
    return raw.replace('\r\n', '\n'), ('\r\n' if crlf >= bare else '\n')


def main():
    if '--revert' in sys.argv:
        for p, b in TARGETS:
            if os.path.exists(b):
                shutil.copyfile(b, p)
                print('reverted %s <- %s' % (p, b))
            else:
                print('no backup for %s' % p)
        return

    for p, b in TARGETS:
        if not os.path.exists(b):
            shutil.copyfile(p, b)
            print('backup: %s' % b)

    # ---- 1) VGA 地址分支 ×2：ddr_186.v + 台架镜像 -------------------------
    # 注意：台架的注释里也出现过同一串，因此锚点带上行尾的 " :"（只出现在代码行）
    OLD_CODE = OLD_VGA_BRANCH + " :"
    NEW_CODE = NEW_VGA_BRANCH + " :"
    for p in ('ddr_186.v', 'sim/tb/ddr_pipe.v'):
        txt, eol = load(p)
        if NEW_CODE in txt and OLD_CODE not in txt:
            print('unit x2 already applied: %s' % p)
            continue
        n = txt.count(OLD_CODE)
        if n != 1:
            sys.exit('ANCHOR FAIL (%s): VGA branch code line found %d times' % (p, n))
        txt = txt.replace(OLD_CODE, NEW_CODE, 1)
        open(p, 'w', newline='').write(txt.replace('\n', eol))
        print('unit x2 applied: %s' % p)

    # ---- 2) top_zynq7010.v：VGA 读 4 拍 -> 8 拍 --------------------------
    txt, eol = load('top_zynq7010.v')
    pat = re.compile(r"[ \t]*// ★★★ 103rd[\s\S]*?main_arlen\s*<=\s*\(ram_cmd == 2'b10\)\s*\?\s*8'd3\s*:\s*8'd15;")
    if len(pat.findall(txt)) != 1:
        sys.exit("ANCHOR FAIL (top_zynq7010.v): 103rd block not found")
    txt = pat.sub(NEW_BLOCK, txt, count=1)
    open('top_zynq7010.v', 'w', newline='').write(txt.replace('\n', eol))
    print('arlen 3 -> 7 applied: top_zynq7010.v')

    # ---- 3) 台架：VGA(4 拍模型) -> 8 拍模型 ------------------------------
    txt, eol = load('sim/tb/ddr_pipe.v')
    old = "wire [4:0] rlast_at = (fix_100[1] && (ar_cmd_l == 2'b10)) ? 5'd3 : 5'd15;"
    if txt.count(old) != 1:
        sys.exit('ANCHOR FAIL (tb): rlast_at not found')
    txt = txt.replace(old, "wire [4:0] rlast_at = (fix_100[1] && (ar_cmd_l == 2'b10)) ? 5'd7 : 5'd15;", 1)
    open('sim/tb/ddr_pipe.v', 'w', newline='').write(txt.replace('\n', eol))
    print('tb mirror: VGA burst model 4 -> 8 beats')


main()
