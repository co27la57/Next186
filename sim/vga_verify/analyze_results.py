from pathlib import Path
import csv
import json

HERE=Path(__file__).resolve().parent
results=json.loads((HERE/"results/summary.json").read_text())
for r in results:
    print(r["name"], "PASS" if r["returncode"]==0 else "FAIL", *r["summary"],sep="\n  ")
wave=HERE/"results/flush_wave.csv"
rows=list(csv.DictReader(wave.open())) if wave.exists() else []
if not rows:
    print("No local flush_wave.csv; use the optional capture argument to generate it.")
last=None
started=False
finished=False
for row in rows:
    state=tuple(int(row[k]) for k in ("resync","fifo_reset","wr_busy","rd_busy"))
    if state!=last:
        print("FLUSH",row["cycle"],"resync/reset/wbusy/rbusy=",state,
              "ack=",row["ack"],"bridge=",row["bridge_state"])
        last=state
    if state[0]: started=True
    if started and not state[0]: finished=True
    if finished and int(row["wrreq"]) and not state[1] and not state[2]:
        print("FIRST_POST_FLUSH_WRITE",row["cycle"],"half_addr=",hex(int(row["write_addr"])))
        break
