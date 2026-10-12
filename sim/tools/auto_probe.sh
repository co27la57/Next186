#!/bin/sh
# FULL-AUTO sentinel test: inject scancode, read screen, no human timing.
# Baseline: clear screen line, inject 0x24 (j), dump line.
# Repeat with sentinel written into KeyCode row20 (the row for j).
KC=0x080FFB7A
INJ=/home/workspace/kbd_gpio_inject

line() {
  sh /home/workspace/vga_text_dump.sh 24 1 2>/dev/null | sed -n 's/^row24|//p' | sed 's/ *|$//'
}
send() {
  $INJ -k $1 >/dev/null 2>&1
}

echo "### inject help/usage test with -k 0x24"
echo "--- row20 before: $(devmem $((KC+20*8)) 8)"
BEFORE=$(line)
echo "line before: [$BEFORE]"
send 0x24
sleep 2
AFTER=$(line)
echo "line after : [$AFTER]"

if [ "$BEFORE" = "$AFTER" ]; then
  echo "NO CHANGE -> injection path did not reach guest"
else
  echo "CHANGED -> injection works"
fi
