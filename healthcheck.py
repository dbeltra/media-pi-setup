#!/usr/bin/env python3
"""Health scan for the media server. Alert-only — never changes anything.

Runs from cron every 15 min. Pushes to ntfy only when a problem appears or
clears, so a persistent fault sends one message, not one per run.

  healthcheck.py            # normal run
  healthcheck.py --test     # send a test push, verify ntfy works
  healthcheck.py --selftest # assert the state-diff logic

The ntfy topic is a shared secret (topics are world-readable), so it lives in
.env as NTFY_TOPIC and messages deliberately carry no IPs, hostnames or keys.
"""

import json
import os
import re
import subprocess
import sys
import urllib.request
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home() / "mediaserver"
ENV = HOME / ".env"
STATE = HOME / ".healthcheck-state.json"

CONTAINERS = ["gluetun", "qbittorrent", "jellyfin", "seerr", "sonarr", "radarr",
              "prowlarr", "bazarr", "maintainerr", "pihole", "caddy"]

# name -> (port, api version)
ARR = {"radarr": (7878, "v3"), "sonarr": (8989, "v3"), "prowlarr": (9696, "v1")}

DISKS = {"/": 80, "/mnt/media": 85}      # mount -> warn at this use%
LOG_REPEAT_LIMIT = 20                     # identical error lines per hour
IP_SERVICES = ["https://api.ipify.org", "https://ifconfig.me/ip"]

ERRORISH = re.compile(r"error|warn|exception|fail|fatal", re.I)
# strip leading timestamps so the same message on different lines collapses
TIMESTAMP = re.compile(r"^[\d\-:.TZ/ \[\]|]{8,40}")


def env(key, default=""):
    try:
        for line in ENV.read_text().splitlines():
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return default


def sh(*args, timeout=30):
    """Run a command, return stdout. Never raises — a failing probe is a finding."""
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


def get_json(url, timeout=15):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return json.load(r)
    except Exception:
        return None


def notify(title, body, tags="warning", priority="default"):
    topic = env("NTFY_TOPIC")
    if not topic:
        return False
    req = urllib.request.Request(
        f"https://ntfy.sh/{topic}",
        data=body.encode(),
        headers={"Title": title, "Tags": tags, "Priority": priority},
    )
    try:
        urllib.request.urlopen(req, timeout=15).read()
        return True
    except Exception as e:
        log(f"ntfy push failed: {e}")
        return False


def log(msg):
    d = HOME / "logs"
    d.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with (d / "healthcheck.log").open("a") as f:
        f.write(f"{stamp} {msg}\n")


# ---------------------------------------------------------------- checks
# Each returns {key: human message}. The key is the alert identity used for
# state diffing, so it must stay stable across runs for the same fault.

def check_containers():
    out = sh("docker", "ps", "--format", "{{.Names}}")
    running = set(out.splitlines())
    return {f"container:{c}": f"{c} is not running" for c in CONTAINERS if c not in running}


def check_gluetun_health():
    status = sh("docker", "inspect", "--format", "{{.State.Health.Status}}", "gluetun")
    if status and status != "healthy":
        # container liveness is meaningless here — gluetun sat "Up 5 hours" while dead
        return {"vpn:health": f"VPN tunnel is {status}"}
    return {}


def public_ip(*docker_prefix):
    for svc in IP_SERVICES:
        out = sh(*docker_prefix, "curl", "-s", "--max-time", "10", svc, timeout=25)
        ip = out.strip()
        if re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", ip):
            return ip
    return ""


def check_vpn_leak():
    """qBittorrent must not share the host's egress IP.

    Compares live rather than hardcoding home IP, so it survives an ISP change.
    """
    qbt = public_ip("docker", "exec", "qbittorrent")
    if not qbt:
        return {"vpn:qbt_offline": "qBittorrent has no internet — cannot verify VPN"}
    host = public_ip()
    if not host:
        return {}  # can't compare; stay quiet rather than cry wolf
    if qbt == host:
        return {"vpn:leak": "LEAK — qBittorrent traffic is NOT going through the VPN"}
    return {}


def check_disks():
    problems = {}
    for mount, limit in DISKS.items():
        out = sh("df", "--output=pcent", mount)
        lines = out.splitlines()
        if len(lines) < 2:
            continue
        used = int(lines[1].strip().rstrip("%"))
        if used >= limit:
            problems[f"disk:{mount}"] = f"disk {mount} is {used}% full"
    return problems


def check_arr_health():
    problems = {}
    for name, (port, ver) in ARR.items():
        key = env(f"{name.upper()}_API_KEY")
        if not key:
            continue
        data = get_json(f"http://127.0.0.1:{port}/api/{ver}/health?apikey={key}")
        if data is None:
            problems[f"arr:{name}:unreachable"] = f"{name} API not responding"
            continue
        for item in data:
            msg = item.get("message", "")
            # source is stable per fault, so the alert key is stable too
            ident = re.sub(r"[^a-z0-9]+", "-", msg.lower())[:40]
            problems[f"arr:{name}:{ident}"] = f"{name}: {msg[:150]}"
    return problems


def check_log_noise():
    """Catch runaway loops — the Radarr import loop ran 1440x/day for ~40 days."""
    problems = {}
    for c in CONTAINERS:
        out = sh("docker", "logs", "--since", "1h", c, timeout=60)
        if not out:
            continue
        counts = Counter()
        for line in out.splitlines():
            if not ERRORISH.search(line):
                continue
            counts[TIMESTAMP.sub("", line).strip()[:120]] += 1
        if not counts:
            continue
        line, n = counts.most_common(1)[0]
        if n >= LOG_REPEAT_LIMIT:
            problems[f"loop:{c}"] = f"{c} repeated an error {n}x in the last hour: {line[:90]}"
    return problems


CHECKS = [check_containers, check_gluetun_health, check_vpn_leak,
          check_disks, check_arr_health, check_log_noise]


# ---------------------------------------------------------------- state
def diff_state(previous, current):
    """Return (new_problems, recovered_keys). Only these are worth a push."""
    new = {k: v for k, v in current.items() if k not in previous}
    recovered = [k for k in previous if k not in current]
    return new, recovered


def load_state():
    try:
        return json.loads(STATE.read_text())
    except Exception:
        return None            # None means "never run before"


def selftest():
    prev = {"a": "x", "b": "y"}
    cur = {"b": "y", "c": "z"}
    new, gone = diff_state(prev, cur)
    assert new == {"c": "z"}, new
    assert gone == ["a"], gone
    # unchanged state must produce no noise — this is what stops 96 pushes/day
    assert diff_state(cur, cur) == ({}, [])
    assert diff_state({}, {}) == ({}, [])
    print("selftest ok")


def main():
    if "--selftest" in sys.argv:
        return selftest()

    if "--test" in sys.argv:
        ok = notify("Media server", "Test push — healthcheck.py is wired up.",
                    tags="white_check_mark")
        print("sent" if ok else "FAILED — is NTFY_TOPIC set in .env?")
        return sys.exit(0 if ok else 1)

    problems = {}
    for check in CHECKS:
        try:
            problems.update(check())
        except Exception as e:
            problems[f"check:{check.__name__}"] = f"check {check.__name__} crashed: {e}"

    previous = load_state()
    STATE.write_text(json.dumps(problems, indent=1))

    if previous is None:
        # first run: one summary instead of a burst of individual alerts
        if problems:
            notify("Media server: first scan",
                   f"{len(problems)} existing issue(s):\n" + "\n".join(problems.values()),
                   tags="mag")
        log(f"first run, {len(problems)} issue(s) recorded")
        return

    new, recovered = diff_state(previous, problems)
    if new:
        worst = "urgent" if any(k.startswith("vpn:leak") for k in new) else "high"
        notify(f"Media server: {len(new)} new issue(s)",
               "\n".join(new.values()), tags="rotating_light", priority=worst)
    if recovered:
        notify("Media server: recovered",
               "\n".join(f"resolved: {k}" for k in recovered),
               tags="white_check_mark", priority="low")

    log(f"{len(problems)} active, {len(new)} new, {len(recovered)} recovered")


if __name__ == "__main__":
    main()
