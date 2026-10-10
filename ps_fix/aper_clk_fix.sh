#!/bin/sh
# =============================================================================
# aper_clk_fix.sh —— 打开 PS GEM0 的 APER(APB) 时钟门控
# -----------------------------------------------------------------------------
# 实测记录(2026-10-10, COM7):
#   开机后  devmem 0xF8000110 32             -> 0x000FA220
#   直接写  devmem 0xF8000110 32 0x004FA260  -> 读回 0x000FA220   ★写入被丢弃!
#   解锁后  devmem 0xF8000008 32 0xDF0D
#           devmem 0xF8000110 32 0x004FA260  -> 读回 0x000FA260   ★bit6 生效
#           devmem 0xF8000004 32 0x767B
#
# 两个结论:
#   1) SLCR 寄存器组(0xF8000000~0xF8000FFF)是写保护的, 必须先 unlock。
#      本工程遗留的 afi0-hp64.sh 正是用 `devmem 0xF8000004 32 0x767B` 锁上的。
#   2) bit22(GPIO_CPU_1XCLKACT) 在这颗 Zynq-7010 上不可写:
#      写 0x004FA260 只读回 0x000FA260 ⇒ 实际可写掩码 = 0x003FFFF0
#      (正是 ps7_init 里用的那个 mask), bit22 恒 0。
#      ⇒ GPIO "读恒 0 / 写无效" 的根因不是这个门控位, 而是:
#        **PL 未配置(PCFG_DONE=0)时 EMIO 通路不存在**。以太网(ENET0/MDIO 走 EMIO)
#        与 EMIO GPIO(bank2/3) 会一起失效, 烧完位流后两者同时恢复。
#
# 位域(UG585 25.4.11 / 14.4.1):
#   APER_CLK_CTRL @ 0xF8000110
#     bit 6  GEM0_CPU_1XCLKACT   Gigabit Ethernet 0 AMBA Clock control
#     bit 22 GPIO_CPU_1XCLKACT   (本芯片不可写, 一并写入无害)
#
# 幂等。易失性配置, 每次开机需重做 → 配合 pl-bootfix.service。
# =============================================================================
set -e

SLCR_UNLOCK=0xF8000008
SLCR_LOCK=0xF8000004
REG=0xF8000110
BIT_GEM0=0x40          # bit6
BIT_GPIO=0x400000      # bit22 (不可写, 仅为完整性)

cur=$(devmem $REG 32)
curd=$((cur))
newd=$(( curd | BIT_GEM0 | BIT_GPIO ))

if [ "$curd" = "$newd" ]; then
    echo "APER_CLK_CTRL 已是 $cur, 无需修改"
else
    printf 'APER_CLK_CTRL %s -> 0x%X\n' "$cur" "$newd"
    devmem $SLCR_UNLOCK 32 0xDF0D      # 关键: 先解锁 SLCR
    devmem $REG 32 $newd
    devmem $SLCR_LOCK 32 0x767B        # 复原锁定
fi

after=$(devmem $REG 32)
afterd=$((after))
echo "APER_CLK_CTRL 读回 = $after"
if [ $(( afterd & BIT_GEM0 )) -ne 0 ]; then
    echo "OK: GEM0(bit6) 的 APB 时钟已打开"
else
    echo "WARN: bit6 没置上, 检查 SLCR 解锁是否生效"
fi
if [ $(( afterd & BIT_GPIO )) -eq 0 ]; then
    echo "NOTE: bit22 读回仍为 0 (本芯片该位不可写, 属正常)"
fi

echo "提醒: ENET0 与 MDIO 都走 EMIO, 必须先烧位流(PL 配置)它们才通。"
