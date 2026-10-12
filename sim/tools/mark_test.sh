#!/bin/sh
# write distinctive marks into BOTH candidate framebuffers
# then ask the user where they appear on screen
B8=0x080B8000
F6=0x08068000
put() {  # $1=base $2=row $3=string
  base=$1; row=$2; s=$3
  a=$((base + row*160))
  i=0
  while [ $i -lt 8 ]; do
    c=$(printf "%d" "'$s")
    devmem $a 8 0x$(printf %02X $((65 + i))) >/dev/null 2>&1
    a=$((a+2)); i=$((i+1))
  done
}
# mark with 'A'+i sequence so each row is identifiable
mrow() {
  base=$1; row=$2; ch=$3
  a=$((base + row*160))
  i=0
  while [ $i -lt 8 ]; do
    devmem $((a + i*2)) 8 "0x$ch" >/dev/null 2>&1
    i=$((i+1))
  done
}
echo "writing marks..."
mrow $B8 0  41
mrow $B8 7  42
mrow $B8 18 43
mrow $B8 24 44
mrow $F6 0  45
mrow $F6 7  46
mrow $F6 18 47
mrow $F6 24 48
echo "done"
echo "0x080B8000 row0/7/18/24 = A B C D"
echo "0x08068000 row0/7/18/24 = E F G H"
