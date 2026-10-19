oplvol.com —— 运行时调整 OPL3 音量（Next186 / FreeDOS）
================================================================

背景
----
新 OPL3（YMF262）核在 4 个通道 TL=0 时峰值就到 ±32672（99.7% 满幅），
而 soundwave 混音是直接相加、没有分压，容易削波。RTL 在端口 0x38C
加了一个运行时音量寄存器（真机 OPL3 只用 0x388..0x38B，0x38C 空闲）。

FreeDOS 精简版常常没有 DEBUG，所以提供这个 86 字节的 .COM 代替。


用法
----
    OPLVOL 3        设置衰减 ÷8，回显  V=3 ID=A
    OPLVOL 0        取消衰减
    OPLVOL          只回读当前值，不修改

输出固定是两段：

    V=<衰减值>  ID=<版本标识>

值的含义（右移位数）：

    0 = 不衰减（上电默认）
    1 = ÷2
    2 = ÷4
    3 = ÷8
    4 = ÷16
    5..8 = 继续右移（基本静音）
    超过 8 会被钳到 8

设置在复位前一直有效，游戏不会改动它（真机没有这个寄存器）。
所以：先设好 → 再启动游戏 → 听。


诊断价值（重要）
----------------
`ID=` 后面读的是端口 0x38D，RTL 里把它固定返回 0x41（字符 'A'）。
它存在的唯一目的就是区分"写入没生效"和"位流里根本没这段逻辑"——
因为**未译码的端口读出来也是 0**，光看 V=0 是分不清的。

    V=3 ID=A    ✔ 新位流，音量端口正常工作
    V=0 ID=     ✘ ID 后面是空的（读到 0）→ 这个位流里没有新代码，还是旧版
    V=3 ID=A 但 0..8 听不出差别 → 才是真的增益/混音问题

所以顺序一定是：先看 ID 是不是 A，再看 V 和听感。


怎么把文件放进 DOS 盘
----------------------
板子上 DOS 通常在一个 FAT 分区/镜像里。从 PetaLinux 侧：

    scp oplvol.com root@<板子IP>:/tmp/
    # 在板子上找到 DOS 分区并挂载，例如：
    ls /dev/mmcblk0p*          # 看有哪几个分区
    mkdir -p /mnt/dos
    mount /dev/mmcblk0p1 /mnt/dos      # 分区号按实际情况改
    cp /tmp/oplvol.com /mnt/dos/
    umount /mnt/dos

然后从 DOS 里 `OPLVOL 3` 即可。


备选：FreeDOS 完整版自带 DEBUG
------------------------------
如果你装的是 FreeDOS 1.3 完整版，`DEBUG` 位于 Base 包，
安装后一般在  C:\FREEDOS\BIN\DEBUG.EXE。有它就不用本程序：

    DEBUG
    -o 38C 3
    -i 38C
    -q


程序说明（86 字节，纯 8086 实模式）
----------------------------------
    mov  si,0081h      ; PSP 命令行参数
.skip: mov al,[si] / cmp al,' ' / jne .got / inc si / jmp .skip
.got:  cmp al,0Dh      ; 无参数 → 只读
       je  .read
       sub al,'0' / cmp al,8 / jbe .set / mov al,8
.set:  mov dx,038Ch / out dx,al
.read: mov dx,013Dh / mov ah,09h / int 21h    ; 打印 "V="
       mov dx,038Ch / in al,dx
       add al,'0' / mov dl,al / mov ah,02h / int 21h
       mov dx,MsgI / mov ah,09h / int 21h     ; " ID="
       mov dx,038Dh / in al,dx                ; 版本标识
       mov dl,al / mov ah,02h / int 21h
       ; CR LF
       int 20h
       db 'V=$'
       db ' ID=$'

跳转目标已用解码器逐条核对（12 / 3 / 28 / 24 全部正确），
并用一个小型 8086 解释器跑过：
    新位流  `3`→V=3 ID=A / `0`→V=0 ID=A / 无参→只读 / `9`→钳到 8
    旧位流  ID 读回 0 → 显示 "V=3 ID=" 后面空白
