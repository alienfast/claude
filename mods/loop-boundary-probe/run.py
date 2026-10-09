#!/usr/bin/env python3
"""Three-prompt `claude -p` conversation over stream-json with the loop-boundary-probe mod loaded.

Each prompt is sent only after the previous turn's result arrives. The probe compacts at the end of every turn
but the first, so the third turn's row shows the context the second compaction left behind. The ledger lands in tmp/ and is printed at the end.

Usage: run.py [model]      model defaults to the fleet's opus[1m]
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

here = Path(__file__).resolve().parent
root = here.parent.parent
model = sys.argv[1] if len(sys.argv) > 1 else "opus[1m]"
(root / "tmp").mkdir(exist_ok=True)
out = root / "tmp" / f"loop-boundary-probe-{time.strftime('%Y%m%dT%H%M%S')}.jsonl"
env = dict(os.environ, LOOP_PROBE_OUT=str(out))
cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
       "--plugin-dir", str(here), "--model", model, "--effort", "low", "--max-turns", "4", "--allowedTools", "Read"]
proc = subprocess.Popen(cmd, cwd=str(here), env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=open(f"{out}.stderr", "w"), text=True)


def send(text):
    proc.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": text}}) + "\n")
    proc.stdin.flush()


def wait_result():
    for line in proc.stdout:
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "result":
            return ev
    return None


results = []
for word in ("ONE", "TWO", "THREE"):
    send(f"Reply with exactly the one word: {word}")
    r = wait_result()
    results.append(r and r.get("subtype"))
proc.stdin.close()
proc.wait(timeout=120)
print(f"claude exit {proc.returncode}; results: {results}")
print(out)
print(out.read_text() if out.exists() else "(no ledger written)")
