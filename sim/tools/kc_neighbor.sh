#!/bin/sh
# 判别: 读到的 '4'(0x34) 是不是 KeyCode 表里偏 N 字节的某个键?
# 若 j(row20, 期望 0x6A) 却显示 0x34, 则真实读到的可能是 row20-? 行的首字节.
echo "=== 各行首字节(正常字符) 便于找 0x34 出现在哪一行 ==="
echo "row首字节表: r1=71(q) r2=7A(z) r3=73(s) r4=61(a) r5=77(w) r6=63(c) r7=78(x)"
echo "            r8=64(d) r9=65(e) r10=76(v) r11=66(f) r12=74(t) r13=72(r)"
echo "            r14=6E(n) r15=62(b) r16=68(h) r17=67(g) r18=79(y) r19=6D(m)"
echo "            r20=6A(j) r21=75(u) r22=6B(k) r23=69(i) r24=6F(o) r25=6C(l) r26=70(p)"
echo ""
echo "=== 表内是否含 0x34 ? (若含 -> 偏移读; 若不含 -> 数据总线/缓存问题) ==="
i=0
found=0
while [ $i -lt 208 ]; do
  a=$(printf "0x%X" $((0x080FFB7A + i)))
  v=$(devmem $a 8)
  if [ "$v" = "0x34" ]; then echo "  FOUND 0x34 at KeyCode+0x$(printf %X $i) (row $((i/8)) +$((i%8)))"; found=1; fi
  i=$((i+1))
done
[ $found -eq 0 ] && echo "  表内 208 字节中没有 0x34  <-- 关键结论"
echo ""
echo "=== 逐行 16 位对齐读 (CPU 用的就是 16 位读) row16/17/20 ==="
for r in 16 17 20; do
  a=$(printf "0x%X" $((0x080FFB7A + r*8)))
  echo "  row$r @ $a : $(devmem $a 16)"
done
echo ""
echo "=== 非对齐 16 位读 (bx 为奇数时 CPU 会拆成两次) ==="
for off in 0 1 2 3; do
  a=$(printf "0x%X" $((0x080FFB7A + 20*8 + off)))
  echo "  row20+$off @ $a : $(devmem $a 16)"
done
