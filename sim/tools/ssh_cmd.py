#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Drive the Zynq board over SSH (no more waiting for pasted console output).

Usage:
  python ssh_cmd.py "uname -a"
  python ssh_cmd.py -f sim/tools/vga_text_dump.sh        # upload only
  python ssh_cmd.py -f script.sh --run "sh /home/workspace/script.sh 0 8"

Credentials default to root/172.25.82.54/1133 and can be overridden by env:
  ZB_HOST / ZB_USER / ZB_PASS
"""
import argparse
import os
import sys

import paramiko

HOST = os.environ.get("ZB_HOST", "172.25.82.54")
USER = os.environ.get("ZB_USER", "root")
PASS = os.environ.get("ZB_PASS", "1133")
WORK = "/home/workspace"


def connect():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=20,
              look_for_keys=False, allow_agent=False)
    return c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", nargs="?", help="command to run on the board")
    ap.add_argument("-f", "--file", help="upload a local file into " + WORK)
    ap.add_argument("--run", dest="run", help="command to run after upload")
    ap.add_argument("-t", "--timeout", type=int, default=180)
    a = ap.parse_args()

    if not a.cmd and not a.file:
        ap.error("need a command or -f")

    c = connect()
    try:
        if a.file:
            local = a.file
            name = os.path.basename(local)
            dst = "%s/%s" % (WORK, name)
            sftp = c.open_sftp()
            sftp.put(local, dst)
            sftp.chmod(dst, 0o755)
            sftp.close()
            print("uploaded %s -> %s" % (local, dst))
            if not a.run:
                return 0
        cmd = a.cmd or a.run
        i, o, e = c.exec_command(cmd, timeout=a.timeout)
        out = o.read().decode("utf-8", "replace")
        err = e.read().decode("utf-8", "replace")
        sys.stdout.write(out)
        if err.strip():
            sys.stderr.write("--- stderr ---\n" + err)
        return 0
    finally:
        c.close()


if __name__ == "__main__":
    sys.exit(main())