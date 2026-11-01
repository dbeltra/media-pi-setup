#!/usr/bin/env python3
"""Measure external-subtitle offset vs. speech in the audio. Read-only.
  suboffset.py VIDEO [SUB.srt ...]   one video (default: every .srt next to it)
  suboffset.py --scan ROOT...         whole library, one TSV line per subtitle
Positive offset = subtitle shows LATER than the speech (fix: subshift.py SUB +offset)."""
import glob, os, re, statistics, subprocess, sys

FF = ["docker", "exec", "jellyfin", "/usr/lib/jellyfin-ffmpeg/"]
R = 10          # samples per second
WIN = int(os.environ.get("WIN", 600))  # window length, s
MAXOFF = 300    # search range, s
ts = lambda s: (lambda h, m, x: int(h) * 3600 + int(m) * 60 + float(x.replace(",", ".")))(*s.strip().split(":"))


def speech_prefix(video):
    cv = video.replace("/mnt/media/", "/data/")
    ch = subprocess.run(FF[:-1] + [FF[-1] + "ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
                        "stream=channels", "-of", "csv=p=0", cv], capture_output=True, text=True).stdout.strip()
    # dialogue lives in the centre channel on 5.1; stereo gets downmixed
    pan = "pan=mono|c0=FC," if ch.isdigit() and int(ch) > 2 else "pan=mono|c0=0.5*c0+0.5*c1,"
    log = subprocess.run(FF[:-1] + [FF[-1] + "ffmpeg", "-nostats", "-i", cv, "-map", "0:a:0", "-af",
                         pan + "highpass=f=200,lowpass=f=3000,silencedetect=n=-30dB:d=0.4", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", log)
    if not m: raise RuntimeError("ffmpeg could not read the file")
    n = int((int(m[1]) * 3600 + int(m[2]) * 60 + float(m[3])) * R)
    sp, cur = [1] * n, None
    for k, v in re.findall(r"silence_(start|end): ([\d.]+)", log):
        if k == "start": cur = float(v)
        elif cur is not None:
            for i in range(int(cur * R), min(int(float(v) * R), n)): sp[i] = 0
            cur = None
    if cur is not None:
        for i in range(int(cur * R), n): sp[i] = 0
    mean = sum(sp) / n
    if not 0.05 < mean < 0.95: raise RuntimeError(f"speech detection unusable (ratio {mean:.2f})")
    P = [0.0]
    for s in sp: P.append(P[-1] + s - mean)   # prefix sum of centred speech
    return n, P


def windows(n, P, sub):
    """Best offset per window. Score via prefix sums: O(cues x offsets), not O(samples x offsets)."""
    cues = [(int(ts(a) * R), int(ts(b) * R)) for a, b in
            re.findall(r"(\d+:\d+:\d+,\d+) --> (\d+:\d+:\d+,\d+)", open(sub, encoding="utf-8-sig", errors="ignore").read())]
    out = []
    for w0 in range(0, n, WIN * R):
        w1 = min(n, w0 + WIN * R)
        best = None
        near = [(a, b) for a, b in cues if b > w0 - MAXOFF * R and a < w1 + MAXOFF * R]
        for off in range(-MAXOFF * R, MAXOFF * R + 1):
            # cues whose shifted position lands in this window
            s = 0.0; k = 0
            for a, b in near:
                lo, hi = max(a - off, w0, 0), min(b - off, w1, n)
                if lo < hi: s += P[hi] - P[lo]; k += 1
            if k >= 5 and (best is None or s > best[0]): best = (s, off / R)
        if best: out.append((w0 // (60 * R), best[1], best[0]))
    return out


def verdict(ws):
    """ok / shift / unsure. ponytail: median + agreement; a real drift (fps mismatch) shows up as 'unsure'."""
    if len(ws) < 2: return "unsure", 0.0, "too little dialogue"
    offs = [o for _, o, _ in ws]
    med = statistics.median(offs)
    agree = sum(abs(o - med) <= 1.0 for o in offs) / len(offs)
    if agree < 0.6: return "unsure", med, f"windows disagree: {offs}"
    return ("ok" if abs(med) <= 0.5 else "shift"), med, f"{agree:.0%} of windows agree"


def fit(ws):
    """Linear drift: offset(t) = a + b*t (t = audio seconds). Drops music-window junk >3s off the line.
    Feed to: subshift.py SUB a b"""
    pts = [(m * 60 + WIN / 2, o) for m, o, _ in ws]
    a, b = statistics.median(o for _, o in pts), 0.0
    for _ in range(3):
        keep = [(t, o) for t, o in pts if abs(o - (a + b * t)) <= 3.0]
        if len(keep) < 3: return None
        mt, mo = statistics.mean(t for t, _ in keep), statistics.mean(o for _, o in keep)
        b = sum((t - mt) * (o - mo) for t, o in keep) / (sum((t - mt) ** 2 for t, _ in keep) or 1)
        a = mo - b * mt
    return a, b, len(keep)


VID = (".mkv", ".mp4", ".avi")
if sys.argv[1] == "--scan":
    print("status\toffset_s\tsubtitle\tnote", flush=True)
    for root in sys.argv[2:]:
        for d, _, fs in sorted(os.walk(root)):
            for f in sorted(fs):
                if not f.endswith(VID): continue
                v = os.path.join(d, f)
                subs = sorted(glob.glob(glob.escape(os.path.splitext(v)[0]) + ".*.srt"))
                if not subs: continue
                try: n, P = speech_prefix(v)
                except Exception as e:
                    for s in subs: print(f"error\t\t{s}\t{e}", flush=True)
                    continue
                for s in subs:
                    st, med, note = verdict(windows(n, P, s))
                    print(f"{st}\t{med:+.1f}\t{s}\t{note}", flush=True)
else:
    v = sys.argv[1]
    subs = sys.argv[2:] or sorted(glob.glob(glob.escape(os.path.splitext(v)[0]) + ".*.srt"))
    n, P = speech_prefix(v)
    for s in subs:
        ws = windows(n, P, s)
        print(os.path.basename(s))
        for m, o, sc in ws: print(f"  {m:4d} min: {o:+7.1f}s  (score {sc:.0f})")
        print("  =>", *verdict(ws))
        f = fit(ws)
        if f: print(f"  fit: offset {f[0]:+.2f}s + {f[1] * 1000:+.3f}ms/s  ({f[2]} windows)  -> subshift.py SUB {f[0]:.3f} {f[1]:.6f}")
