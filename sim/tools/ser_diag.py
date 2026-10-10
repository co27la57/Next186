#!/usr/bin/env python3
"""Zynq board serial console driver for COM7 diagnostics.

Usage:
  python ser_diag.py --log out.txt "uptime" "ls /sys/class/gpio/"

Opens the port, optionally logs in, sends each command, prints the reply.
"""
import argparse
import sys
import time

import serial


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='COM7')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--wait', type=int, default=1200, help='ms collected after each cmd')
    ap.add_argument('--idle', type=int, default=700, help='ms passive read before sending')
    ap.add_argument('--user', default='root')
    ap.add_argument('--passwd', default='1133')
    ap.add_argument('--no-login', action='store_true')
    ap.add_argument('--log', default=None)
    ap.add_argument('cmds', nargs='*')
    a = ap.parse_args()

    lines = []

    def w(s=''):
        lines.append(s)
        sys.stdout.write(s + '\n')
        sys.stdout.flush()

    ser = serial.Serial()
    ser.port = a.port
    ser.baudrate = a.baud
    ser.bytesize = serial.EIGHTBITS
    ser.parity = serial.PARITY_NONE
    ser.stopbits = serial.STOPBITS_ONE
    ser.timeout = 0.05
    ser.write_timeout = 3
    ser.dtr = True
    ser.rts = True
    try:
        ser.open()
    except Exception as e:
        w('OPEN FAIL: %r' % (e,))
        return 1
    time.sleep(0.2)
    ser.reset_input_buffer()

    def drain(ms):
        end = time.time() + ms / 1000.0
        buf = bytearray()
        while time.time() < end:
            n = ser.in_waiting
            if n:
                buf += ser.read(n)
            else:
                time.sleep(0.02)
        return buf.decode('ascii', 'replace')

    def send(s, ms):
        ser.write((s + '\r').encode('ascii', 'replace'))
        ser.flush()
        return drain(ms)

    w('[opened %s @ %d]' % (a.port, a.baud))
    idle = drain(a.idle)
    if idle.strip():
        w('--- idle ---')
        w(idle)

    if (not a.no_login) and ('login:' in idle):
        ser.write((a.user + '\r').encode('ascii'))
        time.sleep(0.1)
        w('--- user ---')
        w(drain(1500))
        ser.write((a.passwd + '\r').encode('ascii'))
        time.sleep(0.1)
        w('--- passwd ---')
        w(drain(3000))

    for c in a.cmds:
        w('\n>>> ' + c)
        w(send(c, a.wait))

    ser.close()
    w('[closed]')
    if a.log:
        with open(a.log, 'w', encoding='utf-8', errors='replace') as f:
            f.write('\n'.join(lines))
    return 0


if __name__ == '__main__':
    sys.exit(main())
