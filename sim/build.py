# -*- coding: ascii -*-
"""Minimal Verilator build driver for this machine (there is no 'make' here).

Flow:  verilator_bin --cc   ->   zig c++ compile + link   ->   run

Usage:
  python build.py --top blinky --out run/linkup --run \
      sim/linkup/blinky.v sim/linkup/sim_main.cpp
"""
import argparse
import glob
import os
import subprocess
import sys

SP    = r'C:/Users/Administrator/.workbuddy-ai/binaries/python/envs/default/Lib/site-packages'
VROOT = os.path.join(SP, 'verilator')
VBIN  = os.path.join(VROOT, 'bin', 'verilator_bin.exe')
ZIG   = os.path.join(SP, 'ziglang', 'zig.exe')


def run(cmd, **kw):
    print('>>', ' '.join(cmd), flush=True)
    r = subprocess.run(cmd, **kw)
    if r.returncode != 0:
        sys.exit('FAILED (rc=%d): %s' % (r.returncode, cmd[0]))
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--top', required=True, help='top module name')
    ap.add_argument('--out', required=True, help='object/output directory')
    ap.add_argument('--run', action='store_true', help='run the built exe')
    ap.add_argument('--extra', nargs='*', default=[],
                    help='extra verilator flags')
    ap.add_argument('files', nargs='+', help='.v and .cpp files')
    a = ap.parse_args()

    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)

    env = dict(os.environ)
    env['VERILATOR_ROOT'] = VROOT          # verilator_bin needs this
    env['PYTHON'] = sys.executable

    rtl = [os.path.abspath(f) for f in a.files]
    incs = []
    for f in rtl:
        d = '-I' + os.path.dirname(f)
        if d not in incs:
            incs.append(d)

    # ---- 1) verilate -------------------------------------------------
    cmd = [VBIN, '--cc', '--exe', '--Mdir', out, '--top-module', a.top,
           '-Wno-fatal', '-Wno-lint', '-Wno-style', '-Wno-width',
           '-Wno-UNOPTFLAT', '-Wno-DECLFILENAME', '-Wno-EOFNEWLINE',
           '--x-assign', '0', '--x-initial', '0']
    cmd += a.extra
    cmd += incs + rtl
    run(cmd, env=env)

    # ---- 2) compile + link with zig c++ ------------------------------
    srcs = sorted(glob.glob(os.path.join(out, '*.cpp')))
    for f in a.files:
        if f.endswith('.cpp'):
            srcs.append(os.path.abspath(f))
    here = os.path.dirname(os.path.abspath(__file__))
    srcs.append(os.path.join(here, 'tools', 'vl_stubs.cpp'))
    srcs.append(os.path.join(VROOT, 'include', 'verilated.cpp'))
    srcs.append(os.path.join(VROOT, 'include', 'verilated_threads.cpp'))

    exe = os.path.join(out, a.top + '.exe')
    cmd = [ZIG, 'c++', '-std=c++17', '-O1', '-w', '-o', exe,
           '-I' + out,
           '-I' + os.path.join(VROOT, 'include'),
           '-I' + os.path.join(VROOT, 'include', 'vltstd')] + srcs
    run(cmd, env=env)
    print('built:', exe, flush=True)

    # ---- 3) run ------------------------------------------------------
    if a.run:
        run([exe])


if __name__ == '__main__':
    main()
