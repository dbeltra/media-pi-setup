#!/usr/bin/env python3
"""usage: subshift.py SUB.srt SECONDS [DRIFT]   — move every cue so it lands on the speech (drops cues ending before 0).
SECONDS: how late the sub is (from suboffset.py). DRIFT: extra lateness per second of video, from suboffset.py's
fit line, for subs timed at a different frame rate: new = (old - SECONDS) / (1 + DRIFT).
Backs up to ~/mediaserver/logs/<name>.bak first (never overwrites an existing backup)."""
import os, re, shutil, sys

p, off = sys.argv[1], float(sys.argv[2])
drift = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
bak = os.path.expanduser("~/mediaserver/logs/" + os.path.basename(p) + ".bak")
if not os.path.exists(bak): shutil.copy2(p, bak)
ts = lambda s: (lambda h, m, x: int(h) * 3600 + int(m) * 60 + float(x.replace(",", ".")))(*s.strip().split(":"))
def fmt(t):
    ms = round(t * 1000); h, ms = divmod(ms, 3600000); m, ms = divmod(ms, 60000); s, ms = divmod(ms, 1000)
    return f"{h:02}:{m:02}:{s:02},{ms:03}"
out = []
for b in re.split(r"\n\s*\n", open(p, encoding="utf-8-sig").read().strip()):
    lines = b.splitlines()
    i = next((k for k, x in enumerate(lines) if "-->" in x), None)
    if i is None: continue
    a, e = ((ts(x) - off) / (1 + drift) for x in lines[i].split("-->"))
    if e <= 0: continue
    out.append(f"{len(out) + 1}\n{fmt(max(a, 0))} --> {fmt(e)}\n" + "\n".join(lines[i + 1:]))
open(p, "w", encoding="utf-8").write("\n\n".join(out) + "\n")
print(f"shifted {-off:+}s drift {drift * 1000:+.3f}ms/s, {len(out)} cues, backup {bak}")
