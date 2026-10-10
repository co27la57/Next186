"""patch_top_zynq7010_vga4beat.py — 候选 B：把 VGA 读的 AXI 突发缩短为 4 拍（103rd）

为什么是这个改法（全部落在 AXI 接口侧）：
  作者的行推进量是 `vga_lnbytecount += max_read + 1` = 8 个半字 = 16 字节。
  而 AXI 侧对 VGA 读一直发 **16 拍（64 字节）**，同一个 FIFO 却被 `!col_counter[4]` 收下 16 个半字
  ⇒ "取回 16 / 记账 8" 的 2:1 错配 ⇒ 相邻事务重叠一半 ⇒ 屏幕"每 8 个字符截断并重复另 8 个"。
  102nd 台架实测（忠实流控模型）：
    · 现状      : 水位带 58~366, s_prog_empty 高占比 0.17%  -> 复现板上"大多数时候满"
    · 候选 A(限流): 水位带  31~84,           高占比 84.5%   -> 余量打掉 4 倍（否决）
    · 候选 B(4拍) : 水位带 54~358,           高占比 10.7%   -> 余量保留（采纳）
  A 之所以崩，是因为它把 16 拍 burst 里 3/4 的数据丢掉却照样付总线时间
  ⇒ 每个有用半字要付 4 倍总线带宽 ⇒ FSM 来不及回填 ⇒ 水位被钉在门限下。
  B 只取需要的 8 个半字：取回 = 接受 = 推进，且总线按需付费。

改动（一行）：
  top_zynq7010.v:311
    -  main_arlen <= 8'd15;
    +  main_arlen <= (ram_cmd == 2'b10) ? 8'd3 : 8'd15;   // VGA 读 4 拍；cache 填充仍 16 拍
  位置就在 IDLE 采样的 `if (ram_cmd == 2'b10 || ram_cmd == 2'b11)` 分支里，
  `ram_cmd` 正是此刻被接受的命令类型，因此 arlen 与命令同沿确定，不需要额外锁存。

已知残余（不阻塞，记录在案）：
  作者侧 `max_read` 在跨 256 半字边界时会被夹小（`&sdraddr[7:3] ? ~sdraddr[2:0] : 7`），
  那时步进 < 8，而 B 固定取回 8 ⇒ 该笔会多带几个半字（局部重叠）。
  一个帧的地址记账扫描显示该夹取情形在 VGA 行扫地址序列里没有出现（0/2880 事务），
  且它是移植代码自己的保护性夹取、不是作者逻辑；若将来确实出现，正确做法是把 `max_read`
  引出到顶层，令 arlen = max_read>>1（同属 AXI 接口改动）。

用法：
  python sim/tools/patch_top_zynq7010_vga4beat.py            # 应用
  python sim/tools/patch_top_zynq7010_vga4beat.py --revert   # 回退
"""

import os
import shutil
import sys

TOP = 'top_zynq7010.v'
BAK = 'sim/run/top_zynq7010.v.preVga4Beat'

OLD = "                                main_arlen   <= 8'd15;"
NEW = ("                                // ★★★ 103rd（2026-09-27，纯 AXI 接口侧）：VGA 读只取 4 拍\n"
       "                                //   = 16 字节 = 8 个半字 = max_read+1，正好是作者\n"
       "                                //   `vga_lnbytecount += max_read+1` 记账的量。\n"
       "                                //   原来一律发 16 拍(64B)，FIFO 却只收 16 个半字、地址只推进 8\n"
       "                                //   ⇒ 相邻事务重叠一半 ⇒ 屏幕\"每 8 个字符截断并重复另 8 个\"。\n"
       "                                //   台架(102nd 流控模型)实测：本改法保住水位余量，A(把 16 拍里\n"
       "                                //   多出的数据丢掉)会把每个有用半字的总线开销放大 4 倍、余量崩掉。\n"
       "                                main_arlen   <= (ram_cmd == 2'b10) ? 8'd3 : 8'd15;")


def load(path):
    raw = open(path, 'r', newline='').read()
    crlf = raw.count('\r\n')
    bare = raw.count('\n') - crlf
    return raw.replace('\r\n', '\n'), ('\r\n' if crlf >= bare else '\n')


def main():
    if '--revert' in sys.argv:
        if os.path.exists(BAK):
            shutil.copyfile(BAK, TOP)
            print('reverted %s <- %s' % (TOP, BAK))
        else:
            print('no backup %s' % BAK)
        return

    txt, eol = load(TOP)
    if txt.count(OLD) != 1:
        sys.exit('ANCHOR FAIL: main_arlen <= 8\'d15; found %d times' % txt.count(OLD))
    if not os.path.exists(BAK):
        shutil.copyfile(TOP, BAK)
        print('backup: %s' % BAK)
    txt = txt.replace(OLD, NEW, 1)
    open(TOP, 'w', newline='').write(txt.replace('\n', eol))
    print('applied 103rd to %s' % TOP)


main()
