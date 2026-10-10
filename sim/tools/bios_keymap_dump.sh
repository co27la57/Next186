#!/bin/sh
# BIOS 键盘表区自检 —— 与本地 images/BIOS_Next186.bin 逐字对照
# 映像 F000:E000 -> 物理 0x080FE000 ; KeyIndex 偏移 0x1AD3 ; KeyCode 偏移 0x1B44
# 板端: sh bios_keymap_dump.sh   (纯 devmem; KeyIndex 用 8 位读避免未对齐, KeyCode 行 4 字节对齐)
chk8() { v=$(devmem $1 8); [ "$v" = "$2" ] && r=OK || r=DIFF; printf '%-12s act=%-6s exp=%-6s %s  %s\n' "$1" "$v" "$2" "$r" "$3"; }
chk32(){ v=$(devmem $1 32); [ "$v" = "$2" ] && r=OK || r=DIFF; printf '%-12s act=%-12s exp=%-12s %s  %s\n' "$1" "$v" "$2" "$r" "$3"; }
echo "==== [1] KeyIndex 表: 扫描码 -> 行号 (逐字节) ===="
chk8 0x080FFAD5 0x31  KI[02] '1'->49
chk8 0x080FFAD6 0x32  KI[03] '2'->50
chk8 0x080FFAE3 0x01  KI[10] 'q'->1
chk8 0x080FFAE8 0x12  KI[15] 'y'->18
chk8 0x080FFAF1 0x04  KI[1E] 'a'->4
chk8 0x080FFAF2 0x03  KI[1F] 's'->3
chk8 0x080FFAF5 0x11  KI[22] 'g'->17
chk8 0x080FFAF6 0x10  KI[23] 'h'->16
chk8 0x080FFAF7 0x14  KI[24] 'j'->20
chk8 0x080FFAF9 0x19  KI[26] 'l'->25
chk8 0x080FFAFF 0x02  KI[2C] 'z'->2
chk8 0x080FFB03 0x0F  KI[30] 'b'->15
chk8 0x080FFB04 0x0E  KI[31] 'n'->14
echo "==== [2] KeyCode 表: 行号 -> 字符 (每行 8 字节, 4 字节对齐) ===="
chk32 0x080FFB4C 0x10511071  row  1 norm/shft (AL=q)
chk32 0x080FFB50 0x10001011  row  1 ctrl/alt
chk32 0x080FFB54 0x2C5A2C7A  row  2 norm/shft (AL=z)
chk32 0x080FFB58 0x2C002C1A  row  2 ctrl/alt
chk32 0x080FFB5C 0x1F531F73  row  3 norm/shft (AL=s)
chk32 0x080FFB60 0x1F001F13  row  3 ctrl/alt
chk32 0x080FFB64 0x1E411E61  row  4 norm/shft (AL=a)
chk32 0x080FFB68 0x1E001E01  row  4 ctrl/alt
chk32 0x080FFB6C 0x11571177  row  5 norm/shft (AL=w)
chk32 0x080FFB70 0x11001117  row  5 ctrl/alt
chk32 0x080FFB74 0x2E432E63  row  6 norm/shft (AL=c)
chk32 0x080FFB78 0x2E002E03  row  6 ctrl/alt
chk32 0x080FFB7C 0x2D582D78  row  7 norm/shft (AL=x)
chk32 0x080FFB80 0x2D002D18  row  7 ctrl/alt
chk32 0x080FFB84 0x20442064  row  8 norm/shft (AL=d)
chk32 0x080FFB88 0x20002004  row  8 ctrl/alt
chk32 0x080FFB8C 0x12451265  row  9 norm/shft (AL=e)
chk32 0x080FFB90 0x12001205  row  9 ctrl/alt
chk32 0x080FFB94 0x2F562F76  row 10 norm/shft (AL=v)
chk32 0x080FFB98 0x2F002F16  row 10 ctrl/alt
chk32 0x080FFB9C 0x21462166  row 11 norm/shft (AL=f)
chk32 0x080FFBA0 0x21002106  row 11 ctrl/alt
chk32 0x080FFBA4 0x14541474  row 12 norm/shft (AL=t)
chk32 0x080FFBA8 0x14001414  row 12 ctrl/alt
chk32 0x080FFBAC 0x13521372  row 13 norm/shft (AL=r)
chk32 0x080FFBB0 0x13001312  row 13 ctrl/alt
chk32 0x080FFBB4 0x314E316E  row 14 norm/shft (AL=n)
chk32 0x080FFBB8 0x3100310E  row 14 ctrl/alt
chk32 0x080FFBBC 0x30423062  row 15 norm/shft (AL=b)
chk32 0x080FFBC0 0x30003002  row 15 ctrl/alt
chk32 0x080FFBC4 0x23482368  row 16 norm/shft (AL=h)
chk32 0x080FFBC8 0x23002308  row 16 ctrl/alt
chk32 0x080FFBCC 0x22472267  row 17 norm/shft (AL=g)
chk32 0x080FFBD0 0x22002207  row 17 ctrl/alt
chk32 0x080FFBD4 0x15591579  row 18 norm/shft (AL=y)
chk32 0x080FFBD8 0x15001519  row 18 ctrl/alt
chk32 0x080FFBDC 0x324D326D  row 19 norm/shft (AL=m)
chk32 0x080FFBE0 0x3200320D  row 19 ctrl/alt
chk32 0x080FFBE4 0x244A246A  row 20 norm/shft (AL=j)
chk32 0x080FFBE8 0x2400240A  row 20 ctrl/alt
chk32 0x080FFBEC 0x16551675  row 21 norm/shft (AL=u)
chk32 0x080FFBF0 0x16001615  row 21 ctrl/alt
chk32 0x080FFBF4 0x254B256B  row 22 norm/shft (AL=k)
chk32 0x080FFBF8 0x2500250B  row 22 ctrl/alt
chk32 0x080FFBFC 0x17491769  row 23 norm/shft (AL=i)
chk32 0x080FFC00 0x17001709  row 23 ctrl/alt
chk32 0x080FFC04 0x184F186F  row 24 norm/shft (AL=o)
chk32 0x080FFC08 0x1800180F  row 24 ctrl/alt
chk32 0x080FFC0C 0x264C266C  row 25 norm/shft (AL=l)
chk32 0x080FFC10 0x2600260C  row 25 ctrl/alt
chk32 0x080FFC14 0x19501970  row 26 norm/shft (AL=p)
chk32 0x080FFC18 0x19001910  row 26 ctrl/alt
chk32 0x080FFC1C 0x4F314F00  row 27 norm/shft (AL=?)
chk32 0x080FFC20 0x00027500  row 27 ctrl/alt
echo "==== 判读: row 1..16 全 OK 而 row 17+ 大量 DIFF => 表尾(>=0x1BCC)缺失/未载入 ===="
