#!/bin/sh
# 哨兵保持 + 读屏: 写入 0x4B 后等待 25 秒, 每秒打印一次屏幕末行, 便于抓到按键瞬间
KC=0x080FFB7A
R20=$((KC + 20*8))
devmem $R20 8 0x4B
echo "哨兵已写入 row20 = 0x4B('K')，现在按 j"
i=0
while [ $i -lt 25 ]; do
  L=$(sh /home/workspace/vga_text_dump.sh 22 1 2>/dev/null | sed -n 's/^row22|//p' | sed 's/ *|$//')
  echo "t=${i}s | $L"
  sleep 1
  i=$((i+1))
done
devmem $R20 8 0x6A
echo "已还原 row20 = $(devmem $R20 8)"
