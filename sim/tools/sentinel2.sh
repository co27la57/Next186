#!/bin/sh
# Test v2: sentinel overwrite on 4 KeyCode rows.
# row5(w)=normal-key control, row17(g)/row20(j)/row26(p)=failing keys.
# If BIOS reads the table correctly, pressing the key shows the sentinel letter.
KC=0x080FFB7A
wr() { devmem $(($KC + $1*8)) 8 $2; }
rd() { devmem $(($KC + $1*8)) 8; }

echo "=== before ==="
echo "row5=$(rd 5) row17=$(rd 17) row20=$(rd 20) row26=$(rd 26)"

wr 5  0x57
wr 17 0x47
wr 20 0x4A
wr 26 0x50
echo "=== sentinels written ==="
echo "row5=$(rd 5)(W) row17=$(rd 17)(G) row20=$(rd 20)(J) row26=$(rd 26)(P)"
echo "now press w g j p on the guest keyboard"

i=0
while [ $i -lt 45 ]; do
  L=$(sh /home/workspace/vga_text_dump.sh 24 1 2>/dev/null | sed -n 's/^row24|//p' | sed 's/ *|$//')
  echo "t=${i}s |$L"
  sleep 1
  i=$((i+1))
done
wr 5  0x77
wr 17 0x67
wr 20 0x6A
wr 26 0x70
echo "=== restored ==="
echo "row5=$(rd 5) row17=$(rd 17) row20=$(rd 20) row26=$(rd 26)"
