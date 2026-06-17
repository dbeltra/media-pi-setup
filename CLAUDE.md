# CLAUDE.md — Media Server Project Context

This file contains all the context needed to continue helping with this project.

---

## Setup Summary

A self-hosted media server running on a **Dell Latitude 5420** laptop with a 500GB external HDD. Everything runs in Docker. The hostname is kept as `raspberrypi` for migration simplicity.

---

## Hardware

- **Device**: Dell Latitude 5420 (i7-1185G7 @ 3.0GHz, 4C/8T, 16GB RAM, Intel Iris Xe)
- **OS**: Ubuntu 26.04 LTS (Resolute Raccoon)
- **System disk**: 477GB NVMe (100GB LVM root partition)
- **External HDD**: 500GB, mounted at `/mnt/media`, formatted ext4
- **GPU**: Intel Iris Xe (Tiger Lake) — hardware transcoding via Quick Sync (`/dev/dri` passed to Jellyfin)
- **ISP**: ~60 Mbps down / ~15 Mbps up (asymmetric — upload is the bottleneck for remote streaming)

---

## Stack

| Service | Purpose | Port |
|---|---|---|
| Jellyfin | Media server | 8096 |
| Seerr | Request UI (Jellyfin fork of Overseerr) | 5055 |
| Sonarr | TV automation | 8989 |
| Radarr | Movie automation | 7878 |
| Prowlarr | Indexer manager | 9696 |
| qBittorrent | Torrent client (via NordVPN) | 8081 |
| Gluetun | NordVPN WireGuard gateway | — |
| Bazarr | Subtitle manager | 6767 |
| Maintainerr | Watched-media cleanup (rule-based) | 6246 |
| Pi-hole | DNS-level ad/tracker blocker | 53, 8082 |
| Dashboard | Static status page (Caddy-served) | 443 (`media.<DOMAIN>`) |
| Tailscale | Remote access with MagicDNS | — |

---

## Access URLs

All services accessible via MagicDNS hostname from any Tailscale device. See `CLAUDE.local.md` for specific IPs and credentials.

| Service | Hostname |
|---|---|
| Jellyfin | `http://raspberrypi:8096` |
| Seerr | `http://raspberrypi:5055` |
| Radarr | `http://raspberrypi:7878` |
| Sonarr | `http://raspberrypi:8989` |
| Prowlarr | `http://raspberrypi:9696` |
| Bazarr | `http://raspberrypi:6767` |
| Maintainerr | `http://raspberrypi:6246` |
| qBittorrent | `http://raspberrypi:8081` |
| Pi-hole admin | `http://raspberrypi:8082/admin` |
| Dashboard | `https://media.<DOMAIN>` (Caddy) |

---

## Key Paths

```
~/mediaserver/
├── docker-compose.yml
├── .env                  # Contains NORDVPN_PRIVATE_KEY, PIHOLE_PASSWORD, dashboard API keys, Mullvad backup keys
├── generate-config.sh    # Reads .env → writes www/config.json for the dashboard
├── www/
│   ├── index.html        # Dashboard (vanilla HTML/CSS/JS, ~25KB)
│   └── config.json       # Generated; contains API keys/passwords — gitignored
└── config/
    ├── bazarr/
    ├── jellyfin/
    ├── jellyseerr/       # Seerr config (kept as jellyseerr for migration compatibility)
    ├── sonarr/
    ├── radarr/
    ├── prowlarr/
    ├── qbittorrent/
    ├── gluetun/
    ├── pihole/           # etc-pihole/ + etc-dnsmasq.d/
    └── maintainerr/       # SQLite DB + rule definitions (UI-managed)

/srv/downloads/           # NVMe — active torrent downloads (avoids HDD I/O contention)

/mnt/media/               # External HDD — media library
├── movies/
└── tv/
```

---

## Cron Jobs

```
0 4 * * * cd $HOME/mediaserver && docker compose pull && docker compose up -d
0 4 * * 0 cd $HOME/mediaserver && docker compose restart gluetun && sleep 30 && docker compose restart qbittorrent
30 */6 * * * cd $HOME/mediaserver && /usr/bin/python3 $HOME/mediaserver/translate-missing-es.py >> $HOME/mediaserver/logs/translate-es.log 2>&1
```

Daily container update at 4am (replaces Watchtower). Weekly VPN refresh every Sunday at 4am to prevent stalled downloads. Every 6h, auto-translate any missing Spanish subtitles from English via Gemini (see **Subtitles** below).

---

## Configuration Decisions

**VPN**: NordVPN via gluetun using WireGuard, pinned to server `nl903.nordvpn.com`. Only qBittorrent routes through VPN via `network_mode: service:gluetun`. All other services use normal network. Gluetun's default server selection picks servers that don't pass traffic — always pin to a known-working hostname via `SERVER_HOSTNAMES`. A Mullvad VPN account exists as a backup (see `CLAUDE.local.md`).

**Quality profiles (Radarr + Sonarr)**:
- Custom format `Blocklist` (score 0): contains `x265`, `HEVC`, `10.?bit` — no longer penalized since Dell has QSV HW transcoding
- Custom format `Preferred` (score +500): prefers `x264`, `H\.264` — still preferred for Google TV direct play
- 4K and remux disabled entirely in Quality Definitions

**Subtitles**: Bazarr handles everything. Jellyfin's built-in subtitle download is disabled. OpenSubtitles plugin uninstalled. Language profile **"English + Spanish"** (profileId 1), cutoff `null` (wants both, never early-satisfied), series `minimum_score` 80 / movie 70.

- **Providers** (`general.enabled_providers`): `opensubtitlescom`, `subtitulamostv`, `subf2m`, `podnapisi`, `gestdown`. `subf2m` needs a User-Agent string set in its config section or it errors with "User-agent config missing". **`subdivx` was removed from this Bazarr build** — it gets silently dropped if enabled (no error, just absent from the active provider set). `subtis` is movies-only; `subsource`/`subdl` need a free API key. Do not re-add the old Hungarian (`supersubtitles`) / movies-only (`yifysubtitles`) providers — they don't help Spanish TV.
- **`use_embedded_subs = False`** (deliberate). With it `True`, embedded English tracks satisfied "English" so Bazarr never downloaded an external `.srt` — leaving the translator with no source file. False forces external en+es sidecars for the whole library. After toggling it, run the `movies_full_scan_subtitles` + `series_full_scan_subtitles` tasks (via `POST /api/system/tasks?taskid=<id>`) to recompute missing status, then the wanted-search tasks.
- **Spanish-for-English-content via translation, NOT Whisper.** OpenAI Whisper (the `whisperai` provider) can only translate audio → English, never English → Spanish (verified in `whisperai.py`: "Only translations to English supported"). For English-audio movies/shows the only automated path to Spanish is translating an English subtitle. So Whisper is not used.
- **Translator = Gemini** (`translator.translator_type = gemini`, `gemini_model = gemini-2.5-flash`). **`gemini-2.0-flash` free tier is dead** (`limit: 0` → instant 429); `gemini-2.5-flash` / `-flash-lite` / `gemini-flash-latest` still have free quota (~250 req/day, ~10 RPM). Key in `translator.gemini_key` (see `CLAUDE.local.md`). `translator_info = False` (no on-screen "translated by" credit cue). Translated subs are logged in Bazarr history with a below-cutoff score, so the `upgrade_subtitles` task auto-replaces them with a real human Spanish sub if one appears within the 7-day window.
- **Auto-translate cron**: `translate-missing-es.py` (repo root, deployed to `~/mediaserver/`) finds movies/episodes wanting Spanish that have an external English `.srt`, and calls Bazarr's translate API (`PATCH /api/subtitles`, `action=translate`) for each. It **serializes** (waits for each async job to finish before the next) to avoid bursting past Gemini's free-tier RPM — firing requests in parallel causes 429s with no backoff (Bazarr's retry has none). Idempotent: once a Spanish file exists the item leaves the wanted list. Runs every 6h, logs to `~/mediaserver/logs/translate-es.log`. Reads `BAZARR_API_KEY` from `.env`.

**Tailscale MagicDNS**: Enabled. Laptop accessible as `raspberrypi` from all Tailscale devices (hostname kept from Pi for compatibility).

**Reverse proxy**: Caddy container fronts every service with HTTPS at `https://<service>.media.<DOMAIN>`. Certs are issued via Let's Encrypt **DNS-01** against Cloudflare (host has no public 443 — only Tailscale routes to it). Cloudflare DNS holds a single wildcard `*.media.<DOMAIN> → <tailscale-ip>` (DNS-only, gray cloud). Caddyfile and Dockerfile live under `caddy/` in the repo; `qbittorrent.*` proxies to `gluetun:8081` because qBittorrent shares gluetun's netns. Per-service quirks: Jellyfin needs Caddy's bridge IP in *Known Proxies*; qBittorrent needs its hostname added to *Server domains* or its DNS-rebinding-protection blocks the request.

**Pi-hole**: DNS-level ad/tracker blocker, used as the upstream resolver for Tailscale's MagicDNS. Container exposes DNS on `:53` (TCP+UDP) and admin UI on `:8082` (kept off the default :80 so Caddy owns it). Upstreams are `1.1.1.1` + `8.8.8.8`. Admin password lives in `.env` as `PIHOLE_PASSWORD`. Reached via `https://pihole.media.<DOMAIN>` (Caddy proxies `pihole:8082`). To make Tailscale clients use Pi-hole, add `<tailscale-ip>` as a global nameserver in the Tailscale admin DNS panel.

**Dashboard** (`https://media.<DOMAIN>`): A single static `www/index.html` (vanilla HTML/CSS/JS, ~25KB) served by Caddy from `/srv/www` (bind-mounted from `./www`). Shows Pi-hole stats (queries / blocked / block rate), qBittorrent active downloads, Jellyfin "now playing", library counts (movies, shows, missing eps, missing movies, wanted subtitles), Sonarr/Radarr queues, and Prowlarr indexer health. It calls each service's API directly from the browser using keys/URLs in `www/config.json`. For services that don't accept arbitrary CORS origins (Pi-hole, qBittorrent), Caddy provides two server-side proxies on the same vhost: `/pihole-api/*` → `pihole:8082`, `/qbt-api/*` → `gluetun:8081`. `www/config.json` is generated by `generate-config.sh` from `.env` — it pulls `SONARR_API_KEY`, `RADARR_API_KEY`, `PROWLARR_API_KEY`, `JELLYFIN_API_KEY`, `BAZARR_API_KEY`, `PIHOLE_PASSWORD`, `QBITTORRENT_PASSWORD`, `DOMAIN`. **Never commit `www/config.json`** — it's gitignored. Regenerate after rotating any of those secrets, then `docker compose restart caddy` (the bind-mount picks up the new file but a reload is harmless).

**TV playback**: Google TV uses Fladder app connected to local IP `192.168.1.47:8096` — NOT Tailscale, to avoid upload speed bottleneck (15 Mbps upload is not enough for reliable 1080p streaming via Tailscale).

**Watched-media cleanup (Maintainerr)**: Container at port 6246. Connects to Jellyfin/Sonarr/Radarr/Seerr (creds stored in `config/maintainerr/maintainerr.sqlite`, not env vars). A Jellyfin API key named `Maintainerr` exists in Jellyfin's `ApiKeys` table for this. Janitorr was tried first and rejected — its model is `age = max(import_date, last_watched_date)` with no "must have been watched" gate, so it would delete unwatched-but-old content. Maintainerr's rule engine has explicit `Jellyfin → isWatched` + `Jellyfin → lastViewedAt` predicates which can express "watched AND last viewed > 7 days ago" exactly. Two rule groups are configured (also via API — UI not needed unless you want to edit them):

- **"Watched movies older than 7d"** — library Movies, dataType `movie`, arrAction `DELETE` (0), `listExclusions: true` (adds to Radarr import-list exclusion so Seerr can't silently re-pull). Rule: `Jellyfin.isWatched == true AND Jellyfin.lastViewedAt > 604800 seconds ago`.
- **"Watched episodes older than 7d"** — library Shows, dataType `episode`, arrAction `DELETE` (0). Same rule. Sonarr's per-episode DELETE keeps the series monitored, so new episodes of ongoing shows still download.

Two-stage schedule: the rule executor (cron `0 0-23/8 * * *` = every 8h) re-scans the library and adds matching items to the collection; the collection handler (cron `0 0-23/12 * * *` = every 12h) processes additions older than `deleteAfterDays` (set to 0) and emits the *arr delete. Total grace ≈ rule's 7d + up to ~12h collection-handler lag. The Maintainerr API enums needed if you script more rules: `Application.JELLYFIN=6`, `RulePossibility.EQUALS=2`/`BEFORE=5`, `RuleType.NUMBER='0'`/`BOOL='3'`, `ServarrAction.DELETE=0`. Prop IDs for Jellyfin: `isWatched=42`, `lastViewedAt=7`. POST bodies require `notifications: []` or the create silently fails with a NOT NULL constraint on `notification_rulegroup.notificationId`.

---

## Known Issues & Solutions

- **Stalled downloads**: `docker compose restart gluetun && sleep 30 && docker compose restart qbittorrent`. Must recreate (not just restart) qbittorrent after gluetun recreate, since qbittorrent uses `network_mode: service:gluetun` and the network namespace reference breaks.
- **All torrents in error state at 0%**: Check that qBittorrent's save path (`/data/downloads/`) matches the Docker volume mount. The config file is at `config/qbittorrent/qBittorrent/qBittorrent.conf` — look for `Session\DefaultSavePath` and `Downloads\SavePath`. Both must be `/data/downloads/`.
- **VPN connected but no traffic (DNS timeouts in gluetun logs)**: Gluetun's server selection for NordVPN often picks dead servers. Pin to a known-working server via `SERVER_HOSTNAMES=nl903.nordvpn.com`. To find a new working server: install `nordvpn` CLI, run `nordvpn connect nl`, note the server name, then uninstall the CLI (it hijacks networking).
- **qBittorrent queue not starting downloads**: Check `max_active_torrents` setting — error/stalled torrents count toward the limit. Current setting: 10. Use qBittorrent API from inside container: `docker exec qbittorrent curl -s "http://localhost:8081/api/v2/app/preferences"`
- **qBittorrent "downloading metadata"**: usually DHT taking time, Force Reannounce helps. If persistent, restart gluetun
- **Hardcoded subtitles (anime)**: avoid releases with `hardsub`, `subbed`, `ASS` in name. Look for clean WEB-DL releases
- **Buffering on TV**: check Jellyfin Dashboard → Active Streams. If transcoding, check that QSV is being used (should show "(HW)" in transcode info). If direct playing, ensure TV uses local IP not Tailscale
- **Tailscale DNS blocks external hostnames**: Tailscale sets `/etc/resolv.conf` to `100.100.100.100` with an immutable flag. Some external APIs (e.g. NordVPN) can't resolve. To temporarily fix: `sudo chattr -i /etc/resolv.conf` then add `nameserver 1.1.1.1`. Rebooting restores Tailscale DNS.
- **NordVPN CLI hijacks networking**: Never leave the `nordvpn` package installed. It modifies routing tables and firewall rules, breaking SSH, Docker networking, and Tailscale. Install only to extract WireGuard keys, then immediately uninstall.
- **.NET services time out on external HTTP (Radarr / Sonarr / Jellyfin)**: Host has no IPv6 default route, but DNS returns AAAA records. .NET's `HttpClient` tries v6 first and waits for the full timeout. Compose disables IPv6 inside each .NET container via `sysctls: *no-ipv6` (anchor defined at the top of the compose file). If you add a new .NET service, attach the same anchor.
- **Radarr "timeout retrieving movie by TMDB ID" / Seerr requests fail**: Telefonica España (and possibly other ISPs) can't route Cloudflare prefix `188.114.0.0/22`, which is what public DNS returns for `api.radarr.video`. The compose pins `api.radarr.video` to a reachable `104.18.x.x` Cloudflare anycast IP via `extra_hosts` on the radarr service. Swap to any other reachable 104.18.x.x if it ever stops working. Test directly with `docker exec radarr curl -4 --max-time 5 https://api.radarr.video/v1/movie/imdb/tt0111161`.

---

## Client Apps

| Device | App |
|---|---|
| Google TV | Fladder (local IP) |
| iPhone/iPad | Jellyfin |
| Android | Jellyfin |
| Mac/PC | Browser |

