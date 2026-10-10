#!/bin/sh
# =============================================================================
# afi_fix.sh — 把 Zynq AFI0 (S_AXI_HP0) 强制回 32 位模式
# -----------------------------------------------------------------------------
# 背景(2026-10-10 定位):
#   本设计 PL 侧 AXI 主机是 32 位 (top_zynq7010: m_axi_wdata[31:0]/wstrb[3:0]/rdata[31:0]),
#   因此 S_AXI_HP0 的 AFI 必须 n32BitEn=1。
#   证据: Vivado 从当前 BD 生成的 Network.ip_user_files/mem_init_files/ps7_init.tcl 里就是
#         mask_write 0XF8008000 0x00000001 0x00000001
#         mask_write 0XF8008014 0x00000001 0x00000001
#   —— 即设计要的是 32 位。
#   但板上有一个 systemd oneshot 服务在启动约 40 秒时把它改成 64 位:
#         "[ OK ] Finished Set S_AXI_HP0 (AFI0) to 64-bit mode (n32BitEn=0)."
#   ⇒ 宽度失配 ⇒ PL 经 HP0 读 DDR 时每个 32bit beat 被重复一次
#     ⇒ 屏幕"每 2 个字符重复"(每字符 16 位 ⇒ 32 位 = 2 字符)。
#   ⇒ 同时解释了"PS 先启动、后下位流就立刻花屏"(那时 AFI 已经是 64 位)。
#
# 寄存器(Xilinx 官方):
#   AFI_RDCHAN_CTRL @ 0xF8008000
#   AFI_WRCHAN_CTRL @ 0xF8008014
#   bit0 = n32BitEn :  1 = 32-bit enabled   0 = 64-bit enable
#
# 用法:  sudo sh afi_fix.sh
# =============================================================================
set -e

for reg in 0xF8008000 0xF8008014; do
    cur=$(devmem $reg 32)
    if [ $((cur & 1)) -eq 1 ]; then
        echo "AFI $reg = $cur  (已是 32-bit, 无需修改)"
    else
        new=$((cur | 1))
        printf 'AFI %s = %s  -> 写回 0x%X (n32BitEn=1)\n' "$reg" "$cur" "$new"
        devmem $reg 32 $new
        echo "AFI $reg 读回 = $(devmem $reg 32)"
    fi
done

echo "AFI0 已按 PL 的 32 位主机配置完成。"
