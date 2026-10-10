#!/bin/bash
# =====================================================================
# Next186 上板测试集 v4
#   任务2：dump 0x0805C000，看字符串是否存在
#   任务3：测 CPU 当前状态 —— 卡在 int18 的 RS232 等待循环？还是已 BOOT 进 DOS？
#
# 用法（板子 petalinux 上）：
#   bash cpu_state_test_v4.sh
# 或只想要函数：source 进来后用 screendump <基址> <字数>
#
# 前提：devmem 只能单字读（devmem <addr> 32），不要带 count
# =====================================================================

# ---------- 通用工具：DDR 文本页 -> ASCII（字符在偶数字节，属性在奇数） ----------
# 用法: screendump <DDR基址> <32位字数>     1 个字 = 2 个字符，80 列自动换行
screendump() {
    base=$1; words=$2; col=0; a=$base; i=0
    while [ $i -lt $words ]; do
        w=$(( $(devmem $a 32) ))
        for s in 0 16; do
            c=$(( (w >> s) & 0xFF ))
            if [ $c -lt 32 ] || [ $c -gt 126 ]; then c=46; fi   # 非可打印 -> '.'
            printf "\\$(printf '%03o' $c)"
            col=$((col + 1))
            [ $col -eq 80 ] && { printf '\n'; col=0; }
        done
        a=$((a + 4)); i=$((i + 1))
    done
    printf '\n'
}


########################################################################
echo "################################################################"
echo "# [任务2] 0x0805C000 里到底有没有字符串？"
echo "################################################################"
echo "--- 2a) 原始 32 位字 (0x0805C000..+0xF0) ---"
for ((a=0x0805C000; a<=0x0805C0F0; a+=4)); do printf "%08x: " $a; devmem $a 32; done

echo
echo "--- 2b) 同一片当文本解（若无意义字符 => 该页不是文本页）---"
screendump 0x0805C000 60

echo
echo "--- 2c) 对照：CPU 真正写字的页 0x080B8000 (= B800:0) ---"
screendump 0x080B8000 60

echo
echo "--- 2d) 对照：屏上冻住的那串所在的页 0x08068000 ---"
screendump 0x08068000 60

echo
echo "判读："
echo "  0x0805C000 若有正常英文串 => 它才是文本页，我之前的地址推算要推翻"
echo "  0x0805C000 是乱码/全 0   => 确认文本页在 0x080B8000，VGA 读错页成立"


########################################################################
echo
echo "################################################################"
echo "# [任务3] CPU 当前状态：RS232 等待循环？还是已进 DOS？"
echo "################################################################"

echo "=== T1【最决定性】整屏 80x25 = 0x080B8000 起 1000 个字(4000 字节) ==="
screendump 0x080B8000 1000

echo
echo "=== T2 判读 RS232 循环 ==="
echo "  若 T1 里出现：'No boot device available, waiting on RS232 (115200bps, f000:100) ...'"
echo "    => CPU 卡在 int18 的 RS232 等待循环（BIOS_Next186.asm L3464 booterrmsg，"
echo "       int18 先 call prts 打印这句，再进 sloop 收 S-record）"
echo "  若 T1 是 FreeDOS 的 kernel 横幅 / 盘符提示符(如 C:\\>) => 已 BOOT 进 DOS"

echo
echo "=== T3 中断向量表（判断 DOS 是否已装载）==="
echo "  (IVT 在 0000:0000，INT n 向量在 0000:(n*4)；DDR = 0x08000000 + 线性地址)"
printf 'INT 13h(磁盘, 0000:004C) : '; devmem 0x0800004C 32
printf 'INT 16h(键盘, 0000:0058) : '; devmem 0x08000058 32
printf 'INT 18h(启动失败,0000:0060): '; devmem 0x08000060 32
printf 'INT 19h(引导, 0000:0064) : '; devmem 0x08000064 32
printf 'INT 21h(DOS API,0000:0084): '; devmem 0x08000084 32
echo "  判读：INT21h 段值若指向 DOS 装载段(低地址如 0x00xx/0x0xxx 且非 F000) => DOS 已装载"
echo "        INT21h 若仍指向 F000:xxxx( BIOS 默认处理) => 还没进 DOS"

echo
echo "=== T4 引导扇区是否被读入 0000:7C00 ==="
echo "--- 7C00 起 64 字节 ---"
for ((a=0x08007C00; a<=0x08007C3C; a+=4)); do printf "%08x: " $a; devmem $a 32; done
echo "--- 0x7DFC 高 16 位应为 0xAA55（引导扇区签名 55 AA）---"
printf '0x08007DFC : '; devmem 0x08007DFC 32
echo "  判读：有 0xAA55 => INT19 已把 SD 卡引导扇区读进 7C00 并 jmp 过去（ASM L3477）"
echo "        无签名   => 读盘失败，会走 int19err -> int 18h -> RS232 等待"

echo
echo "=== T5 屏是否在变 ==="
echo "  ★ 重要前提：DOS 停在 'C:\\>' 提示符等键盘输入时，帧缓冲本来就不变！"
echo "    光标闪烁是 CRTC 硬件用属性 blink 位做的，**不写显存** ⇒ devmem 看不出来。"
echo "    所以 '屏未变化' 是 DOS 空闲的正常表现，不能据此判卡死。要证活看 T6/T7/ILA。"
screendump 0x080B8000 1000 > /tmp/scr1.txt
sleep 5
screendump 0x080B8000 1000 > /tmp/scr2.txt
# 防假阴性：若 /tmp 不可写，两个文件都为空 → diff 必然"未变化"，结果无效
if [ ! -s /tmp/scr1.txt ] || [ ! -s /tmp/scr2.txt ]; then
    echo "  !! 抓取文件为空（/tmp 不可写？）⇒ 本次 T5 无效，请改用：screendump 0x080B8000 20"
elif diff -q /tmp/scr1.txt /tmp/scr2.txt >/dev/null; then
    echo "  屏未变化 —— 与'DOS 在提示符等键盘输入'一致，非卡死证据"
else
    echo "  屏有变化 => CPU 在活动输出"
fi

echo
echo "=== T7【决定性·证活】敲键盘测试（需 PS/2 键盘）==="
echo "  第1步 先看提示符尾部：  screendump 0x080B8000 1000 | tail -4"
echo "  第2步 在键盘上敲一个字母（或敲 dir 再回车）"
echo "  第3步 再读一次：        screendump 0x080B8000 1000 | tail -4"
echo "  判读：提示符后出现刚敲的字符 => CPU 活着、正在 DOS 提示符等输入"
echo "        敲 dir+回车能列目录     => 系统完全正常"
echo "  辅助：键盘缓冲头/尾(40:1A/40:1C)，按键被取走后会变化"
printf '  当前 40:1A(head)/40:1C(tail): '; devmem 0x08000418 32; printf '                                 '; devmem 0x0800041C 32

echo
echo "=== T6 活性复测（40:6C tick）==="
devmem 0x0800046C 32
sleep 5
devmem 0x0800046C 32
echo "  两次应差约 91（18.2Hz x 5s）；差值正常 => CPU/BIOS 活着"


########################################################################
echo
echo "################################################################"
echo "# 若上面仍判不出（想直接看 CPU 停在哪条指令）—— 用 ILA 探针"
echo "################################################################"
cat <<'PROBE'
Next186_CPU.v 里已有现成探针信号，无需自己造：

    L1844  reg [15:0] dbg_CS;      // L1931: dbg_CS    <= CS;
    L1845  reg [15:0] dbg_IP;      // L1932: dbg_IP    <= IP;
    L1846  reg [20:0] dbg_IADDR;   // L1933: dbg_IADDR <= IADDR;
    L1836  dbg_IFETCH (= IFETCH)
    L1855  dbg_MREQ   L1856  dbg_IORQ   L1837  dbg_HALT

做法：
  1) 在 Next186_CPU.v 里给 dbg_CS / dbg_IP / dbg_IADDR 加
         (* mark_debug = "true", keep = "true" *)
     （文件的 L1835-1856 已有大量同款被注释掉的模板，照抄即可）
  2) ILA 采样这几个信号；触发条件建议 dbg_IFETCH=1（取指有效）
  3) 读到的 CS:IP 直接就是 CPU 当前位置，对照判读：
       CS=0xF000 且 IP 落在 int18/sloop 区间   -> 卡在 RS232 等待循环
                                                （sloop 在 ASM L3455-3460）
       CS:IP = 0000:7C00 附近                  -> 正在跑引导扇区
       CS 指向 DOS 装载段(低段值)              -> 已进 DOS
       CS=0xF000 且 IP 在 E05B 之后很近        -> 卡在 BIOS 早期（不太可能，tick 已 916s）

提示：只用 devmem 时 T1(整屏) + T4(7C00 签名) 基本就能定性，
      建议先跑完上面再决定是否值得为探针重综合一次。
PROBE
