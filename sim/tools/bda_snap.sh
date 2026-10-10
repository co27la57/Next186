#!/bin/sh
# ============================================================================
# bda_snap.sh —— 8086 BDA 前后快照对比(不假设任何偏移, 让数据自己说话)
# ----------------------------------------------------------------------------
# 用途: 注入一个扫描码, 前后各快照一次 BDA, 打印**发生变化的字**。
#   好处: 不需要预先知道 head/tail/buffer 各在哪个偏移 —— 变化本身就是答案。
#   这是本项目的教训: 之前多次因为假设 BDA 偏移而得出错误结论
#   (0x417 键盘标志、0x41A/0x41C 缓冲指针、0x430 缓冲内容都猜错过)。
#
# 已确认的唯一事实: 0x08000400 读到 0x03F8 = COM1 基址 => BDA 起点就是 0x08000400。
#
# 兼容性: 只用 busybox 自带的 sh/awk/devmem, 不用 paste/join。
#
# 用法: sh bda_snap.sh <scancode_hex> [重复次数]
#   例: sh bda_snap.sh 24
# ============================================================================
SC=${1:-24}
REPEAT=${2:-1}

BDA=134217728          # 0x08000400, 用十进制避免 sh 的 0x 解析差异
LO=0                   # 起始偏移(十进制)
HI=128                 # 结束偏移(十进制)

snap() {
    off=$LO
    while [ "$off" -le "$HI" ]; do
        a=$((BDA + off))
        v=$(devmem "$a" 16)
        printf '%d %s\n' "$off" "$v"
        off=$((off + 2))
    done
}

run_once() {
    echo "########## 注入扫描码 0x$SC ##########"
    snap > /tmp/bda_before.txt
    echo | ./kbd_gpio_inject -r "$SC" >/dev/null 2>&1
    snap > /tmp/bda_after.txt

    echo "--- 发生变化的字 (offset  old -> new) ---"
    awk 'NR==FNR { b[$1]=$2; next }
              { if ($2 != b[$1]) printf "  0x%s  %s -> %s\n", $1, b[$1], $2 }' \
        /tmp/bda_before.txt /tmp/bda_after.txt
    echo "--- (以上为空则本次注入未引起 BDA 任何变化) ---"
}

r=1
while [ "$r" -le "$REPEAT" ]; do
    echo
    echo "==================== 第 $r/$REPEAT 次 ===================="
    run_once
    r=$((r + 1))
    sleep 1
done

echo
echo "==================== 当前 BDA 快照(供人工核对) ===================="
snap | awk '{ printf "0x%04X=%s  ", $1, $2; if (++n%6==0) printf "\n" } END { printf "\n" }'