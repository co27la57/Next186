#!/bin/sh
# ============================================================================
# kbd_buf_probe.sh —— 键盘缓冲容量实测
# ----------------------------------------------------------------------------
# 目的: 确认"前 N 个字符能进、之后进不去"里的 N 到底是多少, 以及卡住时
#       缓冲里到底存着哪些字符。这样就不需要再猜是键位问题还是容量问题。
#
# 做法:
#   1) 清 BDA: 键盘标志(0040:0017)、头尾指针(001A/001C)、缓冲本体(0030-004F)
#   2) 注入一串**互不相同**的字符
#   3) 立刻 dump 缓冲, 逐槽位打印
#
# 映射已由实测确认: 物理 = 0x08000000 + (段<<4) + 偏移, BDA 起点 = 0x08000400
#   (0x08000400 读到 0x03F8 = COM1 基址, 与 BDA 0040:0000 吻合)
#
# 缓冲每槽 2 字节: 低字节 = ASCII, 高字节 = 扫描码(标准 PC BIOS 布局)
#
# 用法: sh kbd_buf_probe.sh "<要输入的字符串>"
# ============================================================================
STR=${1:-abcdefghijklmnopqrstuvwx}

FLAGS=0x08000417
HEAD=0x0800041A
TAIL=0x0800041C
BUF=0x08000430

clear_bda() {
    devmem $FLAGS 16 0
    devmem $HEAD  16 0
    devmem $TAIL  16 0
    i=0
    while [ $i -lt 16 ]; do
        devmem $((BUF + i*2)) 16 0
        i=$((i+1))
    done
}

show() {
    h=$(devmem $HEAD 16)
    t=$(devmem $TAIL 16)
    echo "head=0x$h  tail=0x$t  (pending = $(( h - t )) entries)"
    echo "槽位  偏移    word   char       scancode"
    i=0
    while [ $i -lt 16 ]; do
        a=$((BUF + i*2))
        w=$(devmem $a 16)
        lo=$(printf '%d' 0x$(printf '%02x' $(($w & 255))))
        hi=$(printf '%d' 0x$(printf '%02x' $(($w >> 8))))
        # 可打印则显示字符, 否则显示点
        if [ "$lo" -ge 32 ] && [ "$lo" -le 126 ]; then
            c=$(printf "\\$(printf '%03o' $lo)")
        else
            c="."
        fi
        printf "%2d  0x%04X  0x%04X   '%s'(0x%02X)  0x%02X\n" \
               $i $((a - 0x08000000)) "$w" "$c" $lo $hi
        i=$((i+1))
    done
}

echo "########## 清空 BDA ##########"
clear_bda
show
echo
echo "########## 注入字符串: '$STR' (长度 ${#STR}) ##########"
printf '%s\n' "$STR" | ./kbd_gpio_inject -g 0 >/dev/null 2>&1
sleep 1
echo
echo "########## 注入后 ##########"
show
echo
echo "########## guest 屏幕最后一行 ##########"
sh /home/workspace/vga_text_dump.sh 24 1 | grep '^row24'