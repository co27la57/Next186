#!/bin/sh
# =============================================================================
# remove_afi_hp64.sh —— 删除 2026-10-07 遗留的 "AFI0 设成 64 位" 开机 oneshot
# -----------------------------------------------------------------------------
# 背景（2026-10-10 串口实测确认）:
#   /etc/systemd/system/afi0-hp64.service
#     Description=Set S_AXI_HP0 (AFI0) to 64-bit mode (n32BitEn=0)
#     ExecStart=/usr/local/sbin/afi0-hp64.sh
#   /usr/local/sbin/afi0-hp64.sh:
#     devmem 0xF8000008 32 0xDF0D      # SLCR unlock
#     devmem 0xF8008000 32 0x00000000  # AFI0_CTRL: n32BitEn = 0 (64-bit)
#     devmem 0xF8000004 32 0x767B      # SLCR lock
#
#   它是"当时的 PL 主机是 64 位"那一版设计留下的脚本，属于 rootfs 文件，
#   和 XSA 完全无关 ⇒ 你更新 XSA / 重编 BOOT.bin 都不可能把它删掉。
#
#   为什么它是 45 秒花屏的元凶:
#     · 本设计 PL 侧 AXI 主机是 32 位（确凿证据：本工程 ps7_init.tcl 里有
#           mask_write 0XF8008000 0x00000001 0x00000001
#           mask_write 0xF8008014 0x00000001 0x00000001
#       即 FSBL 启动时把 AFI0 设成 32 位 → 开机前 40 秒屏幕正常）
#     · 该服务在 ~40 秒时把它改回 64 位 ⇒ 宽度失配
#       ⇒ 每个 32-bit beat 被重复 ⇒ 每 2 个字符重复（字符=16bit，32bit=2字符）
#
#   它必须在 rootfs 上删掉（rootfs 在 SD 卡 /dev/mmcblk0p2 ext4，持久化）。
# =============================================================================
set -x

systemctl disable --now afi0-hp64.service 2>&1
systemctl stop afi0-hp64.service 2>&1

rm -f /etc/systemd/system/afi0-hp64.service
rm -f /usr/local/sbin/afi0-hp64.sh
rm -f /etc/systemd/system/multi-user.target.wants/afi0-hp64.service

systemctl daemon-reload
systemctl reset-failed 2>/dev/null

echo "--- 剩余 afi 相关 unit（应为空）---"
systemctl list-unit-files 2>/dev/null | grep -i afi
ls /etc/systemd/system/ | grep -i afi
ls /usr/local/sbin/ | grep -i afi

echo "--- AFI0 当前值（两行 bit0 都应为 1 = 32-bit）---"
devmem 0xF8008000 32
devmem 0xF8008014 32
echo "done: 重启后 AFI0 应一直保持 0x...01, 屏幕不再花屏"
