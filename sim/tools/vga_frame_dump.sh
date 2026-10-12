#!/bin/sh
# dump VGA 帧缓冲物理区, 用于判断"旋转"是显示侧算错还是帧缓冲内容错
FB=0x08068000
echo "=== 帧缓冲物理基址 $FB 前 24 行 (每行 160B) 的首字符 ==="
i=0
while [ $i -lt 24 ]; do
  a=$((FB + i*160))
  c=$(devmem $a 8)
  # devmem 返回 0x.. 格式
  printf "row%-3d @0x%08X  first=0x%s  " $i $a $(echo $c | sed 's/0x//')
  # 打印前 16 字节作为 ascii
  j=0
  line=""
  while [ $j -lt 16 ]; do
    b=$(devmem $(($a + j)) 8)
    v=$(echo $b | sed 's/0x//')
    d=$((0x$v))
    if [ $d -ge 32 ] && [ $d -lt 127 ]; then line="$line$(printf \\$(printf '%03o' $d))"; else line="$line."; fi
    j=$((j+1))
  done
  echo "| $line"
  i=$((i+1))
done
