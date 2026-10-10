#!/bin/sh
# BIOS 键盘表区自检 (第2版: 修正基址偏移)
#
# 纠正: 第1版用 images/BIOS_Next186.bin 的表偏移(KeyIndex 0x1AD3 / KeyCode 0x1B44),
#       比卡上实际布局小 0x36, 导致 67 条全部误报 DIFF。
# 卡上实测: KeyCode 表在映像偏移 0x1B7A, KeyIndex 在 0x1B09
#           == images/BIOS/BIOS_Next186.com 的布局 (BIOS_Next186.bin 是另一份构建)
# 映像 F000:E000 -> 物理 0x080FE000
# 板端: sh bios_keymap_dump.sh
OKN=0; BADN=0
chk8() {
  v=$(devmem $1 8)
  if [ "$v" = "$2" ]; then r=OK; OKN=$((OKN+1)); else r=DIFF; BADN=$((BADN+1)); fi
  printf "%-12s act=%-6s exp=%-6s %-4s %s\n" "$1" "$v" "$2" "$r" "$3"
}
chk32() {
  v=$(devmem $1 32)
  if [ "$v" = "$2" ]; then r=OK; OKN=$((OKN+1)); else r=DIFF; BADN=$((BADN+1)); fi
  printf "%-12s act=%-12s exp=%-12s %-4s %s\n" "$1" "$v" "$2" "$r" "$3"
}
echo "==== [1] KeyIndex: 扫描码 -> 行号 (8 位读, 地址未对齐) ===="
chk8 0x080FFB0B 0x31 "sc02 1->row49"
chk8 0x080FFB0C 0x32 "sc03 2->row50"
chk8 0x080FFB19 0x01 "sc10 q->row1"
chk8 0x080FFB1E 0x12 "sc15 y->row18"
chk8 0x080FFB27 0x04 "sc1E a->row4"
chk8 0x080FFB28 0x03 "sc1F s->row3"
chk8 0x080FFB2B 0x11 "sc22 g->row17"
chk8 0x080FFB2C 0x10 "sc23 h->row16"
chk8 0x080FFB2D 0x14 "sc24 j->row20"
chk8 0x080FFB2F 0x19 "sc26 l->row25"
chk8 0x080FFB35 0x02 "sc2C z->row2"
chk8 0x080FFB39 0x0F "sc30 b->row15"
chk8 0x080FFB3A 0x0E "sc31 n->row14"
echo "==== [2] KeyCode: 行号 -> 字符 (32 位对齐读) ===="
chk32 0x080FFB82 0x10511071 "row  1 norm AL=71h [q]"
chk32 0x080FFB86 0x10001011 "row  1 ctrl/alt"
chk32 0x080FFB8A 0x2C5A2C7A "row  2 norm AL=7Ah [z]"
chk32 0x080FFB8E 0x2C002C1A "row  2 ctrl/alt"
chk32 0x080FFB92 0x1F531F73 "row  3 norm AL=73h [s]"
chk32 0x080FFB96 0x1F001F13 "row  3 ctrl/alt"
chk32 0x080FFB9A 0x1E411E61 "row  4 norm AL=61h [a]"
chk32 0x080FFB9E 0x1E001E01 "row  4 ctrl/alt"
chk32 0x080FFBA2 0x11571177 "row  5 norm AL=77h [w]"
chk32 0x080FFBA6 0x11001117 "row  5 ctrl/alt"
chk32 0x080FFBAA 0x2E432E63 "row  6 norm AL=63h [c]"
chk32 0x080FFBAE 0x2E002E03 "row  6 ctrl/alt"
chk32 0x080FFBB2 0x2D582D78 "row  7 norm AL=78h [x]"
chk32 0x080FFBB6 0x2D002D18 "row  7 ctrl/alt"
chk32 0x080FFBBA 0x20442064 "row  8 norm AL=64h [d]"
chk32 0x080FFBBE 0x20002004 "row  8 ctrl/alt"
chk32 0x080FFBC2 0x12451265 "row  9 norm AL=65h [e]"
chk32 0x080FFBC6 0x12001205 "row  9 ctrl/alt"
chk32 0x080FFBCA 0x2F562F76 "row 10 norm AL=76h [v]"
chk32 0x080FFBCE 0x2F002F16 "row 10 ctrl/alt"
chk32 0x080FFBD2 0x21462166 "row 11 norm AL=66h [f]"
chk32 0x080FFBD6 0x21002106 "row 11 ctrl/alt"
chk32 0x080FFBDA 0x14541474 "row 12 norm AL=74h [t]"
chk32 0x080FFBDE 0x14001414 "row 12 ctrl/alt"
chk32 0x080FFBE2 0x13521372 "row 13 norm AL=72h [r]"
chk32 0x080FFBE6 0x13001312 "row 13 ctrl/alt"
chk32 0x080FFBEA 0x314E316E "row 14 norm AL=6Eh [n]"
chk32 0x080FFBEE 0x3100310E "row 14 ctrl/alt"
chk32 0x080FFBF2 0x30423062 "row 15 norm AL=62h [b]"
chk32 0x080FFBF6 0x30003002 "row 15 ctrl/alt"
chk32 0x080FFBFA 0x23482368 "row 16 norm AL=68h [h]"
chk32 0x080FFBFE 0x23002308 "row 16 ctrl/alt"
chk32 0x080FFC02 0x22472267 "row 17 norm AL=67h [g]"
chk32 0x080FFC06 0x22002207 "row 17 ctrl/alt"
chk32 0x080FFC0A 0x15591579 "row 18 norm AL=79h [y]"
chk32 0x080FFC0E 0x15001519 "row 18 ctrl/alt"
chk32 0x080FFC12 0x324D326D "row 19 norm AL=6Dh [m]"
chk32 0x080FFC16 0x3200320D "row 19 ctrl/alt"
chk32 0x080FFC1A 0x244A246A "row 20 norm AL=6Ah [j]"
chk32 0x080FFC1E 0x2400240A "row 20 ctrl/alt"
chk32 0x080FFC22 0x16551675 "row 21 norm AL=75h [u]"
chk32 0x080FFC26 0x16001615 "row 21 ctrl/alt"
chk32 0x080FFC2A 0x254B256B "row 22 norm AL=6Bh [k]"
chk32 0x080FFC2E 0x2500250B "row 22 ctrl/alt"
chk32 0x080FFC32 0x17491769 "row 23 norm AL=69h [i]"
chk32 0x080FFC36 0x17001709 "row 23 ctrl/alt"
chk32 0x080FFC3A 0x184F186F "row 24 norm AL=6Fh [o]"
chk32 0x080FFC3E 0x1800180F "row 24 ctrl/alt"
chk32 0x080FFC42 0x264C266C "row 25 norm AL=6Ch [l]"
chk32 0x080FFC46 0x2600260C "row 25 ctrl/alt"
chk32 0x080FFC4A 0x19501970 "row 26 norm AL=70h [p]"
chk32 0x080FFC4E 0x19001910 "row 26 ctrl/alt"
chk32 0x080FFC52 0x4F314F00 "row 27 norm AL=00h [?]"
chk32 0x080FFC56 0x00027500 "row 27 ctrl/alt"
echo "==== 汇总: OK=$OKN  DIFF=$BADN ===="
