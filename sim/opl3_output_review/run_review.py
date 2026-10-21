"""Test production I2S PCM and an offset-binary negative control.

This performs no production edit, synthesis, playback, board access, or commit.
"""
from pathlib import Path
import os
import sys
import subprocess
import json

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
sys.path.insert(0,str(ROOT/"sim"))
import build
os.environ.setdefault("ZIG_LIB_DIR",str(Path(build.ZIG).parent/"lib"))
os.environ.setdefault("ZIG_GLOBAL_CACHE_DIR",str(ROOT/"sim/run/opl3_led/zig-global"))
os.environ.setdefault("ZIG_LOCAL_CACHE_DIR",str(ROOT/"sim/run/opl3_led/zig-local"))
source=(ROOT/"soundwave.v").read_text(encoding="utf-8")
negative=source
for old,new in [(".L_data    (lpcm)",".L_data    (lclamp)"),
                (".R_data    (rpcm)",".R_data    (rclamp)")]:
    assert negative.count(old)==1, "Production I2S must use signed PCM"
    negative=negative.replace(old,new)
results=[]
for name,rtl,expected in [("baseline_negative_control",negative,1),("production",source,0)]:
    out=HERE/"run"/name
    out.mkdir(parents=True,exist_ok=True)
    inp=out/"soundwave.v"
    inp.write_text(rtl,encoding="utf-8")
    cmd=[sys.executable,str(ROOT/"sim/build.py"),"--top","soundwave","--out",str(out),
         str(inp),str(HERE/"output_models.v"),str(HERE/"i2s_main.cpp")]
    subprocess.run(cmd,check=True)
    result=subprocess.run([str(out/"soundwave.exe")],cwd=out,capture_output=True,text=True)
    (HERE/(name+".txt")).write_text(result.stdout+result.stderr,encoding="utf-8")
    print(name+":\n"+result.stdout,flush=True)
    results.append(dict(name=name,returncode=result.returncode,expected=expected,
                        expectation_met=result.returncode==expected))
(HERE/"summary.json").write_text(json.dumps(results,indent=2),encoding="utf-8")
raise SystemExit(0 if all(r["expectation_met"] for r in results) else 1)
