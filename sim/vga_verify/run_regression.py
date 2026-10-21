"""Run expected failures and candidate repairs; no synthesis or board access."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import json
import re
import subprocess

HERE = Path(__file__).resolve().parent
OUT = HERE / "results"
OUT.mkdir(exist_ok=True)
EXE = HERE / "run/vga_path.exe"
# flags: 1=drain/reset/ready, 2=complete frame state, 4=remove old -8,
# 8=inject one missed tail read, 16=enforce per-line read quota,
# 32=saturate completed col_counter, 64=separate short AXI experiment.
# The conservative production candidate is 55; AXI remains 16 beats.
cases = [
    ("baseline_text", False, [0,17,3,7,0,211,0,0,0,399]),
    ("baseline_blank", False, [0,17,3,7,0,211,0,1,0,399]),
    ("baseline_drop", False, [8,17,0,7,0,211,0,0,0,399]),
    ("baseline_short_counter", False, [7,17,0,7,0,0,0,0,5,399]),
    ("frame_only_drop", False, [15,17,0,7,0,211,0,0,0,399]),
    ("candidate_text", True, [55,17,3,9,0,211,0,0,0,399]),
    ("candidate_blank", True, [55,123,3,9,0,211,0,1,0,399]),
    ("candidate_drop", True, [63,17,3,9,0,211,0,0,0,399]),
    ("candidate_scroll", True, [55,17,3,9,0,211,0,0,5,399]),
    ("candidate_page", True, [55,17,0,7,0,0,0,0,40,399]),
    ("candidate_pan7", True, [55,17,3,7,0,211,7,0,0,399]),
    ("candidate_graph", True, [55,991,3,9,1,337,0,0,0,399]),
    ("candidate_graph_scroll", True, [55,42,3,7,1,337,0,0,5,399]),
    ("candidate_planar", True, [55,42,3,7,2,337,0,0,0,479]),
    ("candidate_graph_seed2", True, [55,12345,3,7,1,337,0,0,0,479]),
    # Excessive slave stalls remain an underflow, and must not falsely pass.
    ("bandwidth_limit", False, [55,991,15,7,1,337,0,0,0,399]),
    # Optional transport experiment, deliberately excluded from the patch.
    ("short_axi_experiment", True, [71,991,15,7,1,337,0,0,5,399]),
]

def run(case):
    name, expected, args = case
    p = subprocess.run([str(EXE), *map(str,args)], cwd=HERE / "run",
                       capture_output=True, text=True)
    (OUT / (name + ".txt")).write_text(p.stdout+p.stderr, encoding="utf-8")
    rows = re.findall(r"^(RESULT .*|CHECK .*)$", p.stdout, re.M)
    record = dict(name=name, args=args, returncode=p.returncode,
                  expected_pass=expected, expectation_met=(p.returncode==0)==expected,
                  summary=rows)
    print(name + ": " + ("OK" if record["expectation_met"] else "UNEXPECTED"), flush=True)
    return record

if __name__ == "__main__":
    with ThreadPoolExecutor(max_workers=4) as pool:
        records=list(pool.map(run,cases))
    (OUT / "summary.json").write_text(json.dumps(records,indent=2),encoding="utf-8")
    passed=sum(r["expectation_met"] for r in records)
    print(f"{passed}/{len(records)} regression expectations met")
    raise SystemExit(0 if passed==len(records) else 1)
