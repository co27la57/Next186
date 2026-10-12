#!/bin/sh
# Dump KeyCode 表 (F000:FB7A 起 26 行 * 8 字节 = 208 字节) 与 KeyIndex 表 (F000:FB09 起 0x80 字节)
echo "=== KeyCode 表: F000:FB7A 起 0xD0 字节 (物理 0x080FFB7A) ==="
i=0
while [ $i -lt 208 ]; do
  a=$(printf "0x%X" $((0x080FFB7A + i)))
  v=$(devmem $a 8)
  printf "%s " "$v"
  i=$((i+1))
  if [ $((i % 16)) -eq 0 ]; then echo ""; fi
done
echo ""
echo "=== KeyIndex 表: F000:FB09 起 0x80 字节 (物理 0x080FFB09) ==="
i=0
while [ $i -lt 128 ]; do
  a=$(printf "0x%X" $((0x080FFB09 + i)))
  v=$(devmem $a 8)
  printf "%s " "$v"
  i=$((i+1))
  if [ $((i % 16)) -eq 0 ]; then echo ""; fi
done
echo ""
echo "=== 表区前后各 0x40 字节 (查 0x36 偏移) ==="
echo "--- 0x080FFB3A..0x080FFB79 (KeyIndex 前) ---"
i=0
while [ $i -lt 64 ]; do
  a=$(printf "0x%X" $((0x080FFB3A + i)))
  v=$(devmem $a 8)
  printf "%s " "$v"
  i=$((i+1))
  if [ $((i % 16)) -eq 0 ]; then echo ""; fi
done
echo ""
