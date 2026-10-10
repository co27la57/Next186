#!/bin/sh
# ============================================================================
# kbd_keymatrix.sh —— 逐键实测: 每个键单独注入, 记录屏幕实际显示的字符
# ----------------------------------------------------------------------------
# 目的: 确定"哪些键能正常输入"这一集合, 并与 BIOS KeyCode 表的行号对应。
#       目前观察到能用的键其行号全部 <= 16, 不能用的全部 >= 17, 需要逐键确认。
#
# 做法: 对每个字母, 单独清 BDA -> 注入一次 -> 读屏幕该行 -> 记录
#   用法: sh kbd_keymatrix.sh
# ============================================================================
KEYS="abcdefghijklmnopqrstuvwxyz"

clr() {
    devmem 0x08000417 16 0        # 修饰键标志
    devmem 0x0800041A 16 0        # 头指针
    devmem 0x0800041C 16 0        # 尾指针
}

line() {
    sh /home/workspace/vga_text_dump.sh 24 1 | grep '^row24' | sed 's/^row24|C:\\>//; s/ *$//'
}

printf "键 扫描码 期望  实际显示  判定\n"
for k in $KEYS; do
    clr
    # 用 printf 送单个字符给注入器(交互模式), 再补一个回车结束该次注入
    printf '%s\n' "$k" | ./kbd_gpio_inject >/dev/null 2>&1
    sleep 1
    got=$(line)
    # 取最后一个字符
    last=$(printf '%s' "$got" | tail -c 2 | head -c 1)
    if [ "$last" = "$k" ]; then v="OK"; else v="BAD"; fi
    printf "%s  %s   '%s'   '%s'    %s\n" "$k" "-" "$k" "$last" "$v"
    # 追加一个换行, 让下次从新行开始
    clr
    printf '\n' | ./kbd_gpio_inject >/dev/null 2>&1
    sleep 1
done