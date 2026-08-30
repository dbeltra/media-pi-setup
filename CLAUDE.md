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
├── .env                  # Contains NORDVPN_PRIVATE_KEY, PIHOLE_PASSWORD, dashboard API keys
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

/srv/downloads/           # NVMe — torrent data, kept for seeding (avoids HDD I/O contention)

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
*/15 * * * * cd $HOME/mediaserver && /usr/bin/python3 $HOME/mediaserver/healthcheck.py >> $HOME/mediaserver/logs/healthcheck-cron.log 2>&1
```

Health scan every 15 min (see **Monitoring** below). Daily container update at 4am (replaces Watchtower). Weekly VPN refresh every Sunday at 4am to prevent stalled downloads. Every 6h, auto-translate any missing Spanish subtitles from English via Gemini (see **Subtitles** below).

---

## Configuration Decisions

**VPN**: NordVPN via gluetun using WireGuard. Only qBittorrent routes through VPN via `network_mode: service:gluetun`. All other services use normal network. There is no backup VPN provider — the old Mullvad account expired 2026-05-03 and was removed 2026-08-30 to avoid paying two subscriptions. If NordVPN fails, recovery means finding a working NordVPN server (see **Known Issues**).

The gluetun service is configured with **`VPN_SERVICE_PROVIDER=custom`** and an explicit `VPN_ENDPOINT_IP` / `VPN_ENDPOINT_PORT` / `WIREGUARD_PUBLIC_KEY`, rather than `nordvpn` + `SERVER_HOSTNAMES`. Reason: gluetun's *bundled* server database is stale in every release — v3.41.3 rejects `nl1020`, and even `latest` rejects `nl1252` — so pinning by hostname fails outright on any recent server. The custom endpoint bypasses the database entirely.

The image is **pinned to `qmcgaw/gluetun:v3.41.3`**, not `latest`. The 4am cron runs `docker compose pull`, which previously swapped the VPN gateway to a brand-new nightly build without warning.

**Quality profiles (Radarr + Sonarr)**:
- ⚠️ Radarr has 6 profiles and **`qualityProfileId: 1` is the stock "Any" profile**, which permits `CAM`, `TELESYNC`, `BR-DISK`, `Remux-2160p` and every other junk tier. The intended profile is **`6` = "HD - 720p/1080p"**. Seerr's default is correctly set to 6, but movies added directly in Radarr can land on 1 — that is how a 24G 2160p HDR-DV release and a 1080p TELESYNC got grabbed. Audit with `GET /api/v3/movie` and check `qualityProfileId`; fix in bulk with `PUT /api/v3/movie/editor` `{"movieIds":[...],"qualityProfileId":6}`. Moving a movie that **already has a file** off profile 1 makes Radarr treat the existing file as out-of-profile and re-download it, so only switch file-less movies unless a replacement is wanted.
- To blocklist a bad release so it is never re-grabbed: find its `grabbed` event in `GET /api/v3/history`, then `POST /api/v3/history/failed/{id}`. This marks it failed and adds it to `/api/v3/blocklist`; the movie stays monitored and Radarr searches again for something else.
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

**Downloads vs library — they are separate copies, not hardlinks.** `/srv/downloads` is on the LVM root (`dev=64512`) and `/mnt/media` is on the external HDD (`dev=2049`). Hardlinks cannot span filesystems, so the *arr apps **copy** on import and the two files are fully independent. Deleting a torrent and its data never touches the library; only Maintainerr deletes library files, gated on `Jellyfin.isWatched == true`. The converse also matters: a download that **failed to import** exists only in `/srv/downloads`, so deleting it loses the only copy.

**Seeding limits (set 2026-08-30)**: **14 days only** (`max_seeding_time` is in *minutes* = 20160), then **remove the torrent and its files** (`max_ratio_act: 3`).

The ratio limit is deliberately **off**. It was briefly set to 2.0, but qBittorrent fires on ratio **or** time — whichever comes first — so a fast-seeding torrent could hit ratio 2.0 within minutes, before the *arr import poll runs, deleting the download out from under it. A time-only limit puts a 14-day floor under every removal and eliminates that race. Space still self-manages.

Sonarr will still show the health warning *"Download client qBittorrent is set to remove completed downloads"*. That check fires on **any** removal setting, not the ratio, so it cannot be cleared without disabling removal entirely. It is benign here — 14 days is far longer than any import delay. Leave it.

⚠️ **`max_ratio_act` enum changed in qBittorrent 5.x.** On this build (v5.2.3), `2` = **enable super seeding** and `3` = **remove torrent and its content**. Setting `2` (the 4.x value for "remove with content") silently flips `super_seeding: true` on every over-limit torrent and deletes nothing — no error, no log line. Verify after changing it: if torrents are not disappearing, check `super_seeding` in `/api/v2/torrents/info`; if it is `true`, the action is wrong. Read the value back from `/api/v2/app/preferences` — it echoes whatever you set, so a successful readback proves nothing about the semantics.

Two more notes: share limits apply only to **completed** torrents (an incomplete `stalledDL` with a high ratio is ignored), and per-torrent `ratio_limit` / `seeding_time_limit` of `-2` means "use global" while `-1` means "unlimited" — a torrent set to `-1` will ignore the global limit entirely.

**Historical — before 2026-08-30, qBittorrent had no seeding limits** — `max_ratio_enabled: False`, `max_seeding_time_enabled: False`, `max_inactive_seeding_time_enabled: False`. Torrents seed forever and nothing ages out, which is why `/srv/downloads` grows without bound (155G / 51 torrents as of 2026-08-30). To make the disk self-manage, set a share ratio and/or seeding time limit with the action "remove torrent and its files". Before enabling that, resolve any never-imported downloads or they will be deleted with nothing to re-grab them.

**Auditing what is safe to delete from `/srv/downloads`**: cross-reference each entry against `downloadFolderImported` / `movieFileImported` events in the Sonarr and Radarr history APIs (`/api/v3/history?pageSize=250`, paginate). An entry with a matching import event has a library copy; one without does not. Season packs need matching by hand — the fuzzy per-episode match misses them. **Also check qBittorrent first**: an entry that is still seeding is not an orphan, and removing it out from under qBittorrent leaves the torrent in `missingFiles`.

**Monitoring (`healthcheck.py`)**: runs every 15 min from cron, **alert-only — it never changes anything**. Pushes to [ntfy](https://ntfy.sh) on the topic in `.env` as `NTFY_TOPIC`; install the ntfy app and subscribe to that topic to receive alerts. Runs in ~3s, stdlib only, no extra containers.

Six checks, each chosen because it caught something that had been failing silently:

| Check | Why |
|---|---|
| Containers running | baseline |
| gluetun health status | container liveness is worthless here — gluetun sat `Up 5 hours` while the tunnel was stone dead |
| **VPN leak** | compares qBittorrent's egress IP against the host's, live. Recreating gluetun breaks qBittorrent's netns, so this is the check that matters most |
| Disk usage | root ≥80%, `/mnt/media` ≥85% |
| Radarr/Sonarr/Prowlarr `/health` | the *arr apps already do the analysis — this just forwards it. Covers indexers, download clients, root folders |
| Repeated error log lines | ≥20 identical error lines/hour in any container. Generic, so it catches loops nobody predicted — the Radarr import loop ran ~60/hour for 40 days unnoticed |

**It notifies only on state change.** Active problems are kept in `.healthcheck-state.json`; a new problem and a resolved one each send once. Without this a 15-min cron would send ~96 "still broken" pushes a day and you would learn to ignore it, which is worse than no alerting. First run sends one summary instead of a burst.

The ntfy topic is world-readable by anyone who knows it, so messages deliberately contain no IPs, hostnames or keys. `healthcheck.py --test` sends a test push; `--selftest` asserts the state-diff logic.

**TV playback**: Google TV uses Fladder app connected to local IP `192.168.1.47:8096` — NOT Tailscale, to avoid upload speed bottleneck (15 Mbps upload is not enough for reliable 1080p streaming via Tailscale).

**Watched-media cleanup (Maintainerr)**: Container at port 6246. Connects to Jellyfin/Sonarr/Radarr/Seerr (creds stored in `config/maintainerr/maintainerr.sqlite`, not env vars). A Jellyfin API key named `Maintainerr` exists in Jellyfin's `ApiKeys` table for this. Janitorr was tried first and rejected — its model is `age = max(import_date, last_watched_date)` with no "must have been watched" gate, so it would delete unwatched-but-old content. Maintainerr's rule engine has explicit `Jellyfin → isWatched` + `Jellyfin → lastViewedAt` predicates which can express "watched AND last viewed > 7 days ago" exactly. Two rule groups are configured (also via API — UI not needed unless you want to edit them):

- **"Watched movies older than 7d"** — library Movies, dataType `movie`, arrAction `DELETE` (0), `listExclusions: true` (adds to Radarr import-list exclusion so Seerr can't silently re-pull). Rule: `Jellyfin.isWatched == true AND Jellyfin.lastViewedAt > 604800 seconds ago`.
- **"Watched episodes older than 7d"** — library Shows, dataType `episode`, arrAction `DELETE` (0). Same rule. Sonarr's per-episode DELETE keeps the series monitored, so new episodes of ongoing shows still download.

Two-stage schedule: the rule executor (cron `0 0-23/8 * * *` = every 8h) re-scans the library and adds matching items to the collection; the collection handler (cron `0 0-23/12 * * *` = every 12h) processes additions older than `deleteAfterDays` (set to 0) and emits the *arr delete. Total grace ≈ rule's 7d + up to ~12h collection-handler lag. The Maintainerr API enums needed if you script more rules: `Application.JELLYFIN=6`, `RulePossibility.EQUALS=2`/`BEFORE=5`, `RuleType.NUMBER='0'`/`BOOL='3'`, `ServarrAction.DELETE=0`. Prop IDs for Jellyfin: `isWatched=42`, `lastViewedAt=7`. POST bodies require `notifications: []` or the create silently fails with a NOT NULL constraint on `notification_rulegroup.notificationId`.

---

## Known Issues & Solutions

- **Stalled downloads**: `docker compose restart gluetun && sleep 30 && docker compose restart qbittorrent`. Must recreate (not just restart) qbittorrent after gluetun recreate, since qbittorrent uses `network_mode: service:gluetun` and the network namespace reference breaks.
- **All torrents in error state at 0%**: Check that qBittorrent's save path (`/data/downloads/`) matches the Docker volume mount. The config file is at `config/qbittorrent/qBittorrent/qBittorrent.conf` — look for `Session\DefaultSavePath` and `Downloads\SavePath`. Both must be `/data/downloads/`.
- **VPN connected but no traffic (DNS timeouts in gluetun logs)**: The tunnel interface comes up and looks correct, but `docker exec gluetun ip -s link show tun0` shows **TX > 0 and RX = 0** — handshakes leave, nothing comes back. Cause: the NordVPN server is not answering WireGuard. **Nord's API advertises `wireguard_udp` on servers that do not actually serve it** — `nl1020`, `nl1082` and `nl1044` all ping fine and accept TCP 443 while never answering a handshake. Picking servers from `api.nordvpn.com/v1/servers` by load is therefore unreliable.

  Diagnostic shortcut: `RX = 0` means server or key; anything else (DNS errors with RX > 0) means routing. Before blaming the ISP, note that ICMP and TCP 443 succeeding proves nothing about UDP 51820.

  **To find a server that genuinely works, run the NordVPN CLI inside a throwaway container** — this avoids the host-networking hijack entirely, since the container has its own netns:
  ```bash
  docker run -d --name nordkey --cap-add=NET_ADMIN --device /dev/net/tun ubuntu:24.04 sleep infinity
  docker exec nordkey bash -c 'apt-get update -qq && apt-get install -y -qq curl iproute2 wireguard-tools iptables'
  docker exec nordkey bash -c 'curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh -o /tmp/i.sh && sh /tmp/i.sh -n'
  docker exec -d nordkey bash -c 'mkdir -p /run/nordvpn && /usr/sbin/nordvpnd > /var/log/nordvpnd.log 2>&1'
  docker exec nordkey nordvpn set analytics off      # REQUIRED: login hangs forever without consent
  docker exec nordkey nordvpn login --token <TOKEN>
  docker exec nordkey nordvpn connect Netherlands
  docker exec nordkey wg show nordlynx               # gives working endpoint + peer public key
  docker rm -f nordkey                               # `nordvpn logout` REVOKES the API token — skip it
  ```
  Feed the resulting endpoint IP and peer public key into gluetun's `VPN_ENDPOINT_IP` / `WIREGUARD_PUBLIC_KEY`. Note NordVPN shares one WireGuard public key across whole server clusters (22 distinct keys across 800 servers), so an identical key on several servers is normal, not a parsing bug.
- **Talking to the qBittorrent API**: the WebUI user is **`admin`**, not `david` (there is no `WebUI\Username` key in `qBittorrent.conf`, so it uses the default). Password is `QBITTORRENT_PASSWORD` in `.env`. On v5.2.3 `POST /api/v2/auth/login` answers **HTTP 204 with an empty body** on success — older versions returned the literal `Ok.`, so any script asserting `body == "Ok."` reports a false failure and every later call then returns `403 Forbidden`. Check for the `QBT_SID_*` cookie, not the body. Works from the host and from inside the container:
  ```bash
  P=$(grep -E '^QBITTORRENT_PASSWORD=' ~/mediaserver/.env | cut -d= -f2-)
  curl -s -c /tmp/ck -d "username=admin&password=$P" http://127.0.0.1:8081/api/v2/auth/login
  curl -s -b /tmp/ck "http://127.0.0.1:8081/api/v2/torrents/info?filter=all"
  ```
- **qBittorrent queue not starting downloads**: Check `max_active_torrents` setting — error/stalled torrents count toward the limit. Current setting: 10. Use qBittorrent API from inside container: `docker exec qbittorrent curl -s "http://localhost:8081/api/v2/app/preferences"`
- **qBittorrent "downloading metadata"**: usually DHT taking time, Force Reannounce helps. If persistent, restart gluetun
- **Hardcoded subtitles (anime)**: avoid releases with `hardsub`, `subbed`, `ASS` in name. Look for clean WEB-DL releases
- **Buffering on TV**: check Jellyfin Dashboard → Active Streams. If transcoding, check that QSV is being used (should show "(HW)" in transcode info). If direct playing, ensure TV uses local IP not Tailscale
- **Server unreachable at `192.168.1.47` but pings, SSH refused, all services dead**: another device took the IP. `.47` is set **statically** on the server (netplan, `proto static`) but sits inside the router's DHCP pool (`192.168.1.33–199`), so the router is free to lease it to anyone. Diagnosed by comparing the MAC answering the address against the server's real one:
  ```bash
  arp -d 192.168.1.47; ping -c2 192.168.1.47; arp -n 192.168.1.47
  # server's ethernet MAC is a0:29:19:3c:d3:ac — anything else is a squatter
  ```
  From the server's side everything looks perfect (it keeps the address and keeps serving), so `healthcheck.py` cannot see this — it is only visible from another host on the LAN. The server stays reachable on its **Wi-Fi** interface meanwhile; verify the SSH host key fingerprint matches before trusting that path.

  **Fixed 2026-08-30** in the router: *Configuration → LAN Setting → LAN DHCP → index 2 → Reserved IP* → `192.168.1.47` with netmask **`255.255.255.255`**. The /32 is essential — the field defaults to `255.255.255.0`, which would reserve the entire subnet and stop DHCP for every device on the network. Use **Reserved IP**, not *Static Lease*: the server never sends a DHCP request, so a MAC binding would never fire; the goal is only to stop the router handing the address to others. Persist it with *Management → Maintenance → Configuration → Save*, then reboot the squatting device — a reservation does not revoke a lease already issued (12h here).

- **Tailscale DNS blocks external hostnames**: Tailscale sets `/etc/resolv.conf` to `100.100.100.100` with an immutable flag. Some external APIs (e.g. NordVPN) can't resolve. To temporarily fix: `sudo chattr -i /etc/resolv.conf` then add `nameserver 1.1.1.1`. Rebooting restores Tailscale DNS.
- **NordVPN CLI hijacks networking**: Never install the `nordvpn` package **on the host**. It modifies routing tables and firewall rules, breaking SSH, Docker networking, and Tailscale. Run it in a disposable container instead (see above) — the container's own netns makes the hijack harmless.
- **After recreating gluetun, always recreate qbittorrent**: `network_mode: service:gluetun` means the netns reference breaks, and the *arr apps then report "All download clients are unavailable". Force a re-test afterwards by POSTing the download client config to `/api/v3/downloadclient/test`, or the health error stays cached.
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

