#!/usr/bin/env python3
"""
Auto-translate missing Spanish subtitles from existing English subtitles via Bazarr.

Why this exists: Bazarr has no "auto-translate on missing" hook, and OpenAI Whisper
can only translate audio -> English (never English -> Spanish). For English-language
content the only automated path to Spanish is translating an English .srt.

Flow: find movies/episodes that want Spanish but don't have it, locate an external
English .srt for each, and call Bazarr's translate API (configured backend = Gemini)
to produce the Spanish track. Idempotent: once a Spanish file exists the item leaves
the "wanted" list, so re-runs skip it.

Requires: external English .srt files to exist as the source. That means Bazarr must
download external English (general.use_embedded_subs = False), since the translate
API needs a real file, not an embedded track.

Run from cron. Reads BAZARR_API_KEY from ~/mediaserver/.env.
"""
import json
import os
import sys
import time
import urllib.request
import urllib.parse

BASE = "http://localhost:6767"
ENV_PATH = os.path.expanduser("~/mediaserver/.env")
DRY_RUN = "--dry-run" in sys.argv


def log(msg):
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}", flush=True)


def load_api_key():
    with open(ENV_PATH) as f:
        for line in f:
            if line.startswith("BAZARR_API_KEY="):
                return line.strip().split("=", 1)[1]
    raise SystemExit("BAZARR_API_KEY not found in .env")


KEY = load_api_key()
HEADERS = {"X-API-KEY": KEY}


def api_get(path):
    req = urllib.request.Request(BASE + path, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def api_translate(path, dest_lang, media_type, media_id, forced, hi):
    body = urllib.parse.urlencode({
        "action": "translate",
        "language": dest_lang,
        "path": path,
        "type": media_type,            # "movie" or "episode"
        "id": media_id,
        "forced": "True" if forced else "False",
        "hi": "True" if hi else "False",
    }).encode()
    req = urllib.request.Request(BASE + "/api/subtitles", data=body,
                                 headers=HEADERS, method="PATCH")
    with urllib.request.urlopen(req, timeout=600) as r:
        return r.status


def best_english_source(subtitles):
    """Pick an external English .srt to translate from. Prefer plain (non-HI,
    non-forced); fall back to HI English if that's all there is."""
    plain = [s for s in subtitles
             if s.get("code2") == "en" and s.get("path")
             and not s.get("hi") and not s.get("forced")]
    if plain:
        return plain[0]
    any_en = [s for s in subtitles if s.get("code2") == "en" and s.get("path")]
    return any_en[0] if any_en else None


def has_spanish(kind, detail_q, mid):
    detail = api_get(f"/api/{kind}?{detail_q}[]={mid}")["data"]
    if not detail:
        return True
    return any(s.get("code2") == "es" and s.get("path")
               for s in detail[0].get("subtitles", []))


def wait_for_spanish(kind, detail_q, mid, timeout=300, interval=10):
    """Block until the item has an external Spanish file. Translations run as
    async Bazarr jobs; waiting here serializes them so we never fire parallel
    requests at Gemini's rate-limited free tier."""
    waited = 0
    while waited < timeout:
        time.sleep(interval)
        waited += interval
        try:
            if has_spanish(kind, detail_q, mid):
                return True
        except Exception:
            pass
    return False


def process(kind):
    """kind: 'movies' or 'episodes'"""
    if kind == "movies":
        wanted = api_get("/api/movies/wanted?length=10000")["data"]
        id_field, detail_q, media_type = "radarrId", "radarrid", "movie"
    else:
        wanted = api_get("/api/episodes/wanted?length=10000")["data"]
        id_field, detail_q, media_type = "sonarrEpisodeId", "episodeid", "episode"

    translated = skipped_no_en = 0
    for w in wanted:
        if not any(m.get("code2") == "es" for m in w.get("missing_subtitles", [])):
            continue
        mid = w[id_field]
        title = w.get("title") or w.get("seriesTitle", "?")
        detail = api_get(f"/api/{kind}?{detail_q}[]={mid}")["data"]
        if not detail:
            continue
        subs = detail[0].get("subtitles", [])
        # already has external Spanish? skip
        if any(s.get("code2") == "es" and s.get("path") for s in subs):
            continue
        src = best_english_source(subs)
        if not src:
            skipped_no_en += 1
            log(f"  SKIP (no external English yet): {title}")
            continue
        if DRY_RUN:
            log(f"  WOULD translate {title}  <- {os.path.basename(src['path'])}")
            translated += 1
            continue
        try:
            api_translate(src["path"], "es", media_type, mid,
                          forced=src.get("forced", False), hi=src.get("hi", False))
            # Serialize: wait for this async job to finish before the next item,
            # so we never burst parallel requests at the free-tier rate limit.
            if wait_for_spanish(kind, detail_q, mid):
                translated += 1
                log(f"  translated {title}")
            else:
                log(f"  TIMEOUT waiting for {title} (check Gemini quota/logs)")
        except Exception as e:
            log(f"  ERROR translating {title}: {e}")
    return translated, skipped_no_en


def main():
    log(f"=== translate-missing-es start{' (DRY RUN)' if DRY_RUN else ''} ===")
    total_t = total_s = 0
    for kind in ("movies", "episodes"):
        t, s = process(kind)
        log(f"{kind}: translated={t} skipped_no_english={s}")
        total_t += t
        total_s += s
    log(f"=== done: translated={total_t} skipped_no_english={total_s} ===")


if __name__ == "__main__":
    main()
