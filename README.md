# Media Server Setup

A complete guide to setting up a self-hosted media server on a Dell Latitude 5420 (or any Ubuntu x86 machine) with Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent (via NordVPN), Seerr, Bazarr, Pi-hole, a status dashboard, and Tailscale.

> The hostname is kept as `raspberrypi` from a previous Pi 3B+ setup so that existing clients keep working. Everything in this guide is x86/Ubuntu.

---

## Hardware

- Dell Latitude 5420 (i7-1185G7, 16GB RAM, Intel Iris Xe GPU)
- 477GB NVMe (system + active torrent downloads)
- External 500GB HDD (USB, media library only)

The Iris Xe GPU is used for Jellyfin hardware transcoding via Intel Quick Sync (`/dev/dri`).

---

## Stack

| Service | Purpose | Port |
|---|---|---|
| Jellyfin | Media server (with QSV transcoding) | 8096 |
| Seerr | Request UI | 5055 |
| Sonarr | TV automation | 8989 |
| Radarr | Movie automation | 7878 |
| Prowlarr | Indexer manager | 9696 |
| qBittorrent | Torrent client | 8081 |
| Gluetun | NordVPN WireGuard gateway | — |
| Bazarr | Subtitle manager | 6767 |
| Maintainerr | Watched-media cleanup (rule-based) | 6246 |
| Pi-hole | DNS-level ad/tracker blocker | 53, 8082 |
| Dashboard | Static status page (Caddy-served) | 443 (`media.<DOMAIN>`) |
| Tailscale | Remote access with MagicDNS | — |

Container auto-updates are handled by a cron job (no Watchtower).

---

## Step 1 — Install Ubuntu

1. Download Ubuntu 26.04 LTS (Server or Desktop)
2. Flash to a USB stick with [balenaEtcher](https://etcher.balena.io/) or `dd`
3. Boot from USB, install Ubuntu, partition as desired (this guide assumes ~100GB LVM root)
4. During install: create user, set hostname to `raspberrypi`, enable OpenSSH

Connect via SSH:
```bash
ssh YOUR_USERNAME@YOUR_SERVER_LOCAL_IP
```

---

## Step 2 — System Update

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git
```

---

## Step 3 — Install Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

Verify:
```bash
docker --version
docker run hello-world
```

---

## Step 4 — Set Up External HDD

Find the drive:
```bash
lsblk
```

Partition and format (replace `sda` if different):
```bash
sudo parted /dev/sda mklabel gpt
sudo parted /dev/sda mkpart primary ext4 0% 100%
sudo mkfs.ext4 /dev/sda1
```

Mount:
```bash
sudo mkdir -p /mnt/media
sudo mount /dev/sda1 /mnt/media
```

Make permanent — add to `/etc/fstab` (get UUID with `blkid /dev/sda1`):
```
UUID=YOUR-UUID  /mnt/media  ext4  defaults,nofail  0  2
```

Create media folders:
```bash
sudo mkdir -p /mnt/media/{movies,tv}
sudo chown -R $USER:$USER /mnt/media
```

Create the downloads folder on the NVMe (faster I/O, keeps HDD spun down when not streaming):
```bash
sudo mkdir -p /srv/downloads
sudo chown -R $USER:$USER /srv/downloads
```

---

## Step 5 — Install Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Follow the auth URL printed in the terminal. Once connected:
```bash
tailscale ip -4
```

Install Tailscale on all client devices and log in with the same account.

> ⚠️ Tailscale sets `/etc/resolv.conf` to `100.100.100.100` with an immutable flag. Some external APIs (e.g. NordVPN) may fail to resolve. Temporary fix: `sudo chattr -i /etc/resolv.conf` then add `nameserver 1.1.1.1`. Reboot restores Tailscale DNS.

---

## Step 6 — Get NordVPN WireGuard Key

The NordVPN CLI hijacks routing and breaks SSH, Docker, and Tailscale, so install it only briefly to extract the key, then uninstall.

```bash
sudo apt install -y nordvpn wireguard-tools
newgrp nordvpn
nordvpn login --token  # Generate at https://my.nordaccount.com/dashboard/nordvpn/access-tokens/
nordvpn set technology nordlynx
nordvpn connect nl                # pick a country with good P2P, e.g. Netherlands
nordvpn status                    # note the server hostname, e.g. nl903.nordvpn.com
sudo wg showconf nordlynx         # copy the PrivateKey value
nordvpn disconnect
sudo apt remove -y nordvpn wireguard-tools
sudo apt autoremove -y
```

Keep both the **private key** and the **server hostname** — gluetun's automatic server selection often picks dead NordVPN servers, so we pin to a known-working one.

---

## Step 7 — Docker Compose Setup

```bash
mkdir -p ~/mediaserver
cd ~/mediaserver
```

Create `.env`:
```
NORDVPN_PRIVATE_KEY=YOUR_WIREGUARD_PRIVATE_KEY
```

Create `docker-compose.yaml`:
```yaml
x-no-ipv6: &no-ipv6
  # Host has no IPv6 default route. Without this, .NET HTTP clients
  # (Radarr/Sonarr/Jellyfin) try AAAA addresses first and hang for the
  # full timeout before falling back to IPv4.
  - net.ipv6.conf.all.disable_ipv6=1
  - net.ipv6.conf.default.disable_ipv6=1

services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=nordvpn
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=${NORDVPN_PRIVATE_KEY}
      - WIREGUARD_ADDRESSES=10.5.0.2/32
      - SERVER_HOSTNAMES=nl903.nordvpn.com   # pin to a known-working server
      - FIREWALL_INPUT_PORTS=6881
    ports:
      - 8080:8000
      - 8081:8081
      - 6881:6881
      - 6881:6881/udp
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    network_mode: "service:gluetun"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
      - WEBUI_PORT=8081
    volumes:
      - ./config/qbittorrent:/config
      - /srv/downloads:/data/downloads
    depends_on:
      - gluetun
    restart: unless-stopped

  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
    devices:
      - /dev/dri:/dev/dri          # Intel Quick Sync hardware transcoding
    volumes:
      - ./config/jellyfin:/config
      - /mnt/media/movies:/data/movies
      - /mnt/media/tv:/data/tv
    ports:
      - 8096:8096
    sysctls: *no-ipv6
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
    volumes:
      - ./config/sonarr:/config
      - /mnt/media:/data
      - /srv/downloads:/data/downloads
    ports:
      - 8989:8989
    sysctls: *no-ipv6
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
    extra_hosts:
      # If your ISP can't route Cloudflare prefix 188.114.0.0/22 (e.g. Telefonica
      # España), DNS will return those IPs for api.radarr.video and Radarr will
      # hang on TMDB lookups. Pin to a reachable 104.18.x anycast IP instead.
      - "api.radarr.video:104.18.114.5"
    volumes:
      - ./config/radarr:/config
      - /mnt/media:/data
      - /srv/downloads:/data/downloads
    ports:
      - 7878:7878
    sysctls: *no-ipv6
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
    volumes:
      - ./config/prowlarr:/config
    ports:
      - 9696:9696
    sysctls: *no-ipv6
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
    volumes:
      - ./config/bazarr:/config
      - /mnt/media:/data
    ports:
      - 6767:6767
    sysctls: *no-ipv6
    restart: unless-stopped

  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    init: true
    container_name: seerr
    environment:
      - TZ=Europe/Madrid
    volumes:
      - ./config/jellyseerr:/app/config
    ports:
      - 5055:5055
    sysctls: *no-ipv6
    restart: unless-stopped

  # Watched-media cleanup. See Step 15 for rule configuration.
  maintainerr:
    image: ghcr.io/maintainerr/maintainerr:latest
    container_name: maintainerr
    user: "1000:1000"
    environment:
      - TZ=Europe/Madrid
    volumes:
      - ./config/maintainerr:/opt/data
    ports:
      - 6246:6246
    sysctls: *no-ipv6
    restart: unless-stopped

  # DNS-level ad/tracker blocker. See Step 16.
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    environment:
      - TZ=Europe/Madrid
      - FTLCONF_webserver_api_password=${PIHOLE_PASSWORD}
      - FTLCONF_dns_upstreams=1.1.1.1;8.8.8.8
      - FTLCONF_webserver_port=8082    # 80 is reserved for Caddy
      - FTLCONF_dns_listeningMode=all
    volumes:
      - ./config/pihole/etc-pihole:/etc/pihole
      - ./config/pihole/etc-dnsmasq.d:/etc/dnsmasq.d
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "8082:8082"
    restart: unless-stopped
```

Start everything:
```bash
docker compose up -d
```

---

## Step 8 — Autostart on Boot

```bash
sudo systemctl enable docker
sudo systemctl enable containerd
sudo nano /etc/systemd/system/mediaserver.service
```

Paste:
```ini
[Unit]
Description=Media Server
Requires=docker.service
After=docker.service mnt-media.mount

[Service]
WorkingDirectory=/home/YOUR_USERNAME/mediaserver
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always
User=YOUR_USERNAME

[Install]
WantedBy=multi-user.target
```

Enable:
```bash
sudo systemctl daemon-reload
sudo systemctl enable mediaserver
```

---

## Step 9 — Configure Services

### Prowlarr (`http://SERVER:9696`)
1. Set up authentication
2. Add indexers: YTS, EZTV, The Pirate Bay, Knaben, Nyaa
3. Settings → Apps → Add Radarr and Sonarr:
   - Prowlarr server: `http://prowlarr:9696`
   - Radarr server: `http://radarr:7878` + API key from Radarr
   - Sonarr server: `http://sonarr:8989` + API key from Sonarr

### qBittorrent (`http://SERVER:8081`)
- Get temp password: `docker logs qbittorrent 2>&1 | grep -i password`
- Tools → Options → Downloads:
  - Default save path: `/data/downloads/`
  - Incomplete path: `/data/downloads/incomplete/`
- Tools → Options → Web UI: set a permanent password
- Connection port: `6881`
- Enable DHT, PeX, Local Peer Discovery

### Radarr (`http://SERVER:7878`)
- Settings → Download Clients → Add qBittorrent:
  - Host: `gluetun`, Port: `8081` (qBittorrent shares gluetun's network namespace)
- Settings → Media Management → Root Folders → `/data/movies`

### Sonarr (`http://SERVER:8989`)
- Same download client setup as Radarr
- Root folder: `/data/tv`

### Jellyfin (`http://SERVER:8096`)
- First run wizard → create admin account
- Add Movies library → `/data/movies`
- Add TV Shows library → `/data/tv`
- Dashboard → Playback → Transcoding:
  - Hardware acceleration: **Intel QuickSync (QSV)**
  - Enable VAAPI/QSV options as needed

### Seerr (`http://SERVER:5055`)
- Sign in with Jellyfin
- Jellyfin URL: `http://jellyfin:8096`
- External URL: `http://YOUR_TAILSCALE_IP:8096`
- Add Radarr and Sonarr with their API keys

---

## Step 10 — Quality Profiles

With Intel QSV hardware transcoding, x265/HEVC is no longer painful — but x264 is still preferred for direct play on Google TV.

### Radarr & Sonarr custom formats

`Blocklist` (score **0** — neutral, kept around for tuning):
- Release Title matches `x265`
- Release Title matches `HEVC`
- Release Title matches `10.?bit`

`Preferred` (score **+500** — favors x264 direct play):
- Release Title matches `x264`
- Release Title matches `H\.264`

### Disable 4K and remux in Quality Definitions
Set max to `0 B` for:
- HDTV-2160p, WEBDL-2160p, WEBRip-2160p
- Bluray-2160p, Remux-2160p, Remux-1080p
- BR-DISK, Raw-HD

---

## Step 11 — Subtitles (Bazarr)

Bazarr handles all subtitle management. Disable Jellyfin's built-in subtitle download.

### Configure Bazarr (`http://SERVER:6767`)

1. Settings → Providers → add **OpenSubtitles.com** with your credentials
2. Settings → Sonarr: Enable, Host `sonarr`, Port `8989`, API key
3. Settings → Radarr: Enable, Host `radarr`, Port `7878`, API key
4. Settings → Languages:
   - Enable Spanish and English in Languages Filter
   - Create a Language Profile `Spanish + English` with both languages
   - Set as default for Series and Movies
5. Series and Movies tabs → select all → set Language Profile to `Spanish + English`
6. System → Tasks → run **Search for missing subtitles**
7. Settings → Subtitles → enable **Always use Audio Track as Reference for Syncing**

### Disable Jellyfin's built-in subtitles
- Dashboard → Libraries → edit each library → uncheck **Download missing subtitles**
- Dashboard → Scheduled Tasks → **Download missing subtitles** → Disable
- Dashboard → Plugins → Uninstall **OpenSubtitles** if installed

---

## Step 12 — Tailscale MagicDNS

1. Go to https://login.tailscale.com/admin/dns
2. Enable **MagicDNS**
3. Under **Global nameservers**, add a real public resolver like `1.1.1.1` (and optionally `8.8.8.8`). Leave **Override local DNS** off.

> ⚠️ Do **not** add `100.100.100.100` as a global nameserver — that is Tailscale's own resolver, and using it as its own upstream creates a forwarding loop that breaks resolution for every non-tailnet hostname (e.g. anything you add later via Cloudflare).

All services are now reachable as `http://raspberrypi:PORT` from any Tailscale device.

---

## Step 13 — Cron Jobs

```bash
crontab -e
```

Add:
```
# Daily container updates at 4am (replaces Watchtower)
0 4 * * * cd $HOME/mediaserver && docker compose pull && docker compose up -d

# Weekly VPN refresh every Sunday at 4am — prevents stalled downloads
0 4 * * 0 cd $HOME/mediaserver && docker compose restart gluetun && sleep 30 && docker compose restart qbittorrent
```

Verify:
```bash
crontab -l
```

---

## Step 14 — Custom Domain with HTTPS (Cloudflare + Caddy)

Replace `http://raspberrypi:PORT` and `http://100.104.85.26:PORT` with pretty HTTPS URLs like `https://jellyfin.media.<yourdomain>`, while keeping access **Tailscale-only** (no public exposure).

How it works:
- Cloudflare DNS holds a wildcard A record pointing at your Tailscale IP. Only Tailscale-connected devices can route to that address.
- A Caddy container on the laptop terminates HTTPS for each service.
- Certificates are issued via the **DNS-01 challenge** against Cloudflare's API — the host doesn't need to be publicly reachable on port 80/443.

### Cloudflare side

1. **Wildcard A record** under a `media` subdomain of your existing zone:
   - Type `A`, Name `*.media`, Content `YOUR_TAILSCALE_IP` (e.g. `100.104.85.26`), Proxy status **DNS only** (gray cloud), TTL Auto.
2. **API token** (My Profile → API Tokens → Create Token → Custom):
   - Permissions: `Zone → Zone → Read`, `Zone → DNS → Edit`
   - Zone resources: Include → Specific zone → your domain
   - Save the token — Caddy uses it for the DNS-01 challenge.

### Caddy container

The repo ships with `caddy/Dockerfile` (Caddy + Cloudflare DNS plugin via `xcaddy`) and `caddy/Caddyfile` (one site block per service, with hostnames templated via `{$DOMAIN}`).

Add to `~/mediaserver/.env`:
```
CLOUDFLARE_API_TOKEN=YOUR_TOKEN
DOMAIN=yourdomain.com
ACME_EMAIL=you@yourdomain.com
```

Bring it up:
```bash
cd ~/mediaserver
docker compose --env-file .env up -d --build caddy
docker logs -f caddy   # watch first-run ACME issuance
```

You should see `obtained certificate` for each hostname. After that:
- `https://jellyfin.media.yourdomain.com`
- `https://seerr.media.yourdomain.com`
- `https://sonarr.media.yourdomain.com`
- `https://radarr.media.yourdomain.com`
- `https://prowlarr.media.yourdomain.com`
- `https://bazarr.media.yourdomain.com`
- `https://qbittorrent.media.yourdomain.com`
- `https://pihole.media.yourdomain.com` (admin UI — added in Step 16)
- `https://media.yourdomain.com` (status dashboard — added in Step 17)

> qBittorrent is reverse-proxied to `gluetun:8081`, not `qbittorrent:8081`, because qBittorrent shares gluetun's network namespace (`network_mode: service:gluetun`).

### Service-specific settings

Without these, services either reject the proxied request or log the wrong client IP.

The Caddy container sits on the default Compose bridge network, typically `172.18.0.0/16`. Find its exact IP with `docker inspect caddy --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'`.

- **Jellyfin** — Dashboard → Networking:
  - Add the Caddy container's bridge IP to **Known proxies**.
  - Add `https://jellyfin.media.yourdomain.com` to **Published server URLs**.
- **qBittorrent** — Tools → Options → Web UI:
  - In **Trusted proxies list**, add `172.18.0.0/16` (the whole subnet — Caddy's IP can change on rebuild).
  - In **Server domains**, add `qbittorrent.media.yourdomain.com` (or `*`) — otherwise its DNS-rebinding-protection returns `401 Unauthorized`.
- **Sonarr / Radarr / Prowlarr / Bazarr** — no URL base needed (each gets its own hostname). Optionally turn off their own SSL setting since Caddy already handles TLS.
- **Seerr** — works out of the box; optionally update the Jellyfin URL under Settings → Jellyfin to the new HTTPS hostname so shared links point to it.

### Verification

From a Tailscale-connected device:
```bash
dig +short jellyfin.media.yourdomain.com   # → YOUR_TAILSCALE_IP
```
Open `https://jellyfin.media.yourdomain.com` — padlock should be valid, cert issuer **Let's Encrypt**.

From a non-Tailscale device (e.g. phone on cellular with Tailscale off): the hostname resolves but the connection times out — confirms no public exposure.

---

## Step 15 — Watched-Media Cleanup (Maintainerr)

Self-hosted libraries fill up fast. Maintainerr deletes already-watched content (after a configurable grace period) by combining a Jellyfin rule engine with Sonarr/Radarr APIs for the actual file removal — and adds movies to Radarr's import-list exclusion list so Seerr can't silently re-pull them.

### Why not Janitorr

Janitorr looks simpler at first glance, but its deletion model is `age = max(import_date, last_watched_date)`. There's no "must have been watched" gate — anything sitting on disk longer than the threshold gets deleted whether you watched it or not. That makes it a generic age-based cleaner, not a watched-cleanup tool. Maintainerr's rule engine exposes `Jellyfin → isWatched` and `Jellyfin → lastViewedAt` as first-class predicates, which can express "watched AND last viewed > 7 days ago" exactly.

### Create a Jellyfin API key for Maintainerr

Jellyfin Dashboard → API Keys → **+** → name it `Maintainerr` → copy the key. (Or if you don't have admin web access handy, you can insert one directly: `sqlite3 ~/mediaserver/config/jellyfin/data/data/jellyfin.db "INSERT INTO ApiKeys (DateCreated, DateLastActivity, Name, AccessToken) VALUES (datetime('now'), '0001-01-01 00:00:00', 'Maintainerr', '<hex-key>');"` then `docker restart jellyfin`.)

### Connect Maintainerr to your services

Open `http://SERVER:6246` and walk the setup wizard, or POST settings via its REST API:

```bash
# Sonarr
curl -X POST -H "Content-Type: application/json" \
  -d '{"serverName":"sonarr","url":"http://sonarr:8989","apiKey":"<SONARR_KEY>"}' \
  http://localhost:6246/api/settings/sonarr

# Radarr
curl -X POST -H "Content-Type: application/json" \
  -d '{"serverName":"radarr","url":"http://radarr:7878","apiKey":"<RADARR_KEY>"}' \
  http://localhost:6246/api/settings/radarr

# Seerr
curl -X POST -H "Content-Type: application/json" \
  -d '{"url":"http://seerr:5055","api_key":"<SEERR_KEY>"}' \
  http://localhost:6246/api/settings/seerr
```

Jellyfin is configured under Settings → Jellyfin (URL `http://jellyfin:8096`, the API key from above).

### Get the Jellyfin library IDs

```bash
curl -s http://localhost:6246/api/media-server/libraries | jq
# → [{"id":"<MOVIES_ID>","title":"Movies","type":"movie"},
#    {"id":"<SHOWS_ID>","title":"Shows","type":"show"}]
```

### Create the two rules via API

Maintainerr's web UI works for this, but a scripted POST is faster and reproducible. The rule JSON references property IDs that Maintainerr exposes at `GET /api/rules/constants` — for Jellyfin (app `6`): `isWatched=42`, `lastViewedAt=7`. Operators: `EQUALS=2`, `BEFORE=5`. `ServarrAction.DELETE=0`. `RuleOperators.AND="0"`.

**Movies rule** — delete watched movies, remove from Radarr, add to import exclusion list:

```bash
curl -X POST -H "Content-Type: application/json" \
  -d '{
    "libraryId":"<MOVIES_ID>",
    "name":"Watched movies older than 7d",
    "description":"isWatched AND lastViewedAt > 7d ago",
    "isActive":true,
    "arrAction":0,
    "useRules":true,
    "listExclusions":true,
    "forceSeerr":false,
    "radarrSettingsId":1,
    "dataType":"movie",
    "notifications":[],
    "collection":{
      "visibleOnRecommended":false,
      "visibleOnHome":false,
      "deleteAfterDays":0,
      "manualCollection":false,
      "manualCollectionName":"",
      "keepLogsForMonths":3
    },
    "rules":[
      {"firstVal":[6,42],"action":2,"operator":null,"customVal":{"ruleTypeId":3,"value":"1"},"section":0},
      {"firstVal":[6,7],"action":5,"operator":"0","customVal":{"ruleTypeId":0,"value":"604800"},"section":0}
    ]
  }' \
  http://localhost:6246/api/rules
```

**TV episode rule** — delete individual watched episodes; series stays monitored so new episodes still download:

```bash
curl -X POST -H "Content-Type: application/json" \
  -d '{
    "libraryId":"<SHOWS_ID>",
    "name":"Watched episodes older than 7d",
    "description":"isWatched AND lastViewedAt > 7d ago (per episode)",
    "isActive":true,
    "arrAction":0,
    "useRules":true,
    "listExclusions":false,
    "forceSeerr":false,
    "sonarrSettingsId":1,
    "dataType":"episode",
    "notifications":[],
    "collection":{
      "visibleOnRecommended":false,
      "visibleOnHome":false,
      "deleteAfterDays":0,
      "manualCollection":false,
      "manualCollectionName":"",
      "keepLogsForMonths":3
    },
    "rules":[
      {"firstVal":[6,42],"action":2,"operator":null,"customVal":{"ruleTypeId":3,"value":"1"},"section":0},
      {"firstVal":[6,7],"action":5,"operator":"0","customVal":{"ruleTypeId":0,"value":"604800"},"section":0}
    ]
  }' \
  http://localhost:6246/api/rules
```

> **Gotcha**: `POST /api/rules` returns `HTTP 201` but silently fails with `Rules - Action failed` if you omit `"notifications": []`. The hidden cause is `NOT NULL constraint failed: notification_rulegroup.notificationId`. Enable DEBUG logging via `POST /api/logs/settings` `{"level":"debug",...}` if you need to see the underlying error.

### How deletion timing works

Two cron schedules combine:

- **Rule executor** runs every 8h (`0 0-23/8 * * *`) → scans Jellyfin, adds matching items to a collection.
- **Collection handler** runs every 12h (`0 0-23/12 * * *`) → for items in the collection older than `deleteAfterDays` (set to `0` above), emits the *arr DELETE.

So total grace ≈ rule's 7-day predicate + up to ~12h handler lag. Hit the play icon on a rule in the UI to trigger an immediate scan if you want to preview matches.

### Opt out of cleanup

- **Per-item** — favorite (heart) an item in Jellyfin; the `isWatched=true` test still matches but you can extend the rule to filter favorites if needed.
- **Per-show / per-movie permanent keep** — tag the entry in Sonarr/Radarr and add a rule section that excludes that tag.

---

## Step 16 — Pi-hole (DNS ad-blocker)

Network-wide ad/tracker blocking for every device on the tailnet (and, optionally, the LAN).

Pi-hole is included in the compose snippet above. Two things to know up front:

- The admin UI listens on `:8082`, not `:80`, because Caddy owns `:80`/`:443`.
- DNS listens on `:53` (TCP+UDP). If `systemd-resolved` is bound to `:53` on the host, free it first:
  ```bash
  sudo sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  sudo systemctl restart systemd-resolved
  ```

Add to `~/mediaserver/.env`:
```
PIHOLE_PASSWORD=choose_a_strong_password
```

Bring it up:
```bash
docker compose --env-file .env up -d pihole
```

Add to `caddy/Caddyfile`:
```caddyfile
pihole.media.{$DOMAIN} {
    reverse_proxy pihole:8082
}
```
Then `docker compose restart caddy`. Admin UI is at `https://pihole.media.<DOMAIN>/admin`.

### Point Tailscale clients at Pi-hole

In the Tailscale admin DNS panel (https://login.tailscale.com/admin/dns):

1. Under **Global nameservers**, replace `1.1.1.1` with your **Tailscale IP** (the laptop's tailnet address).
2. Leave **Override local DNS** off (so MagicDNS still resolves tailnet hostnames).

Verify from another tailnet device:
```bash
dig @100.100.100.100 doubleclick.net   # should return 0.0.0.0 (blocked)
```

> ⚠️ Don't list Pi-hole as a global nameserver under its **own** IP — that creates a forwarding loop. Use the Tailscale IP of the host running Pi-hole.

---

## Step 17 — Status Dashboard

A single static page at `https://media.<DOMAIN>` that aggregates live status across the stack:

- Pi-hole — queries today / blocked / block rate / blocklist size / clients
- qBittorrent — active downloads with progress and ETA
- Jellyfin — "now playing" sessions
- Library — movie / show counts, missing episodes, missing movies, wanted subtitles
- Sonarr / Radarr — current queue
- Prowlarr — indexer health (total / enabled / healthy)

All API calls happen in the browser using values from `www/config.json`. Pi-hole and qBittorrent don't allow arbitrary CORS origins, so Caddy reverse-proxies them on the dashboard vhost (`/pihole-api/*` and `/qbt-api/*`).

### Wire up Caddy

Add the dashboard volume to the Caddy service in `docker-compose.yml`:
```yaml
  caddy:
    # ...existing config...
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./config/caddy/data:/data
      - ./config/caddy/config:/config
      - ./www:/srv/www:ro                  # ← add this
```

Add a site block to `caddy/Caddyfile`:
```caddyfile
media.{$DOMAIN} {
    handle /pihole-api/* {
        uri strip_prefix /pihole-api
        reverse_proxy pihole:8082
    }

    handle /qbt-api/* {
        uri strip_prefix /qbt-api
        reverse_proxy gluetun:8081
    }

    handle {
        root * /srv/www
        file_server
    }
}
```

### Get API keys

Pull the **API Key** from each service (mostly under Settings → General):

- Sonarr, Radarr, Prowlarr, Bazarr — settings → general → API key.
- Jellyfin — Dashboard → API Keys → **+** → name it `Dashboard`.

Add all of them, plus the existing `PIHOLE_PASSWORD` and your qBittorrent Web UI password, to `~/mediaserver/.env`:
```
SONARR_API_KEY=...
RADARR_API_KEY=...
PROWLARR_API_KEY=...
JELLYFIN_API_KEY=...
BAZARR_API_KEY=...
PIHOLE_PASSWORD=...           # already set in Step 16
QBITTORRENT_PASSWORD=...
DOMAIN=yourdomain.com         # already set in Step 14
```

### Generate the config and bring it up

```bash
cd ~/mediaserver
./generate-config.sh           # writes www/config.json from .env
docker compose --env-file .env up -d --build caddy
```

Open `https://media.<DOMAIN>` — every panel should populate within a few seconds.

> `www/config.json` contains every API key in cleartext, so the repo gitignores it. Anyone who can reach `https://media.<DOMAIN>` can read it — that hostname only resolves to your Tailscale IP, so access is already gated by the tailnet, but **don't** make this hostname public.

Re-run `generate-config.sh` whenever you rotate a key or password; Caddy serves the file directly from the bind mount, so no container restart is needed.

---

## Directory Structure

```
~/mediaserver/
├── docker-compose.yaml
├── .env                  # NordVPN + API keys + passwords — never commit to git
├── generate-config.sh    # Builds www/config.json from .env (Step 17)
├── www/
│   ├── index.html        # Dashboard
│   └── config.json       # Generated — gitignored, contains API keys
└── config/
    ├── bazarr/
    ├── jellyfin/
    ├── jellyseerr/       # Seerr config (kept as jellyseerr for migration compatibility)
    ├── sonarr/
    ├── radarr/
    ├── prowlarr/
    ├── qbittorrent/
    ├── gluetun/
    ├── pihole/           # etc-pihole/ + etc-dnsmasq.d/ (Step 16)
    └── maintainerr/      # SQLite DB + rule definitions (Step 15)

/srv/downloads/           # NVMe — active torrent downloads
└── incomplete/

/mnt/media/               # External HDD — library only
├── movies/
└── tv/
```

The repo also contains a `caddy/` folder (Dockerfile + Caddyfile) used by the optional Step 14 reverse proxy.

Keeping downloads on the NVMe means the HDD only spins up for completed-file moves and playback, reducing wear and I/O contention.

---

## Access URLs

With MagicDNS enabled, use the hostname from any Tailscale device. Use the local IP when on the same network without Tailscale.

| Service | Hostname | Local IP |
|---|---|---|
| Jellyfin | `http://raspberrypi:8096` | `SERVER_IP:8096` |
| Seerr | `http://raspberrypi:5055` | `SERVER_IP:5055` |
| Radarr | `http://raspberrypi:7878` | `SERVER_IP:7878` |
| Sonarr | `http://raspberrypi:8989` | `SERVER_IP:8989` |
| Prowlarr | `http://raspberrypi:9696` | `SERVER_IP:9696` |
| Bazarr | `http://raspberrypi:6767` | `SERVER_IP:6767` |
| Maintainerr | `http://raspberrypi:6246` | `SERVER_IP:6246` |
| qBittorrent | `http://raspberrypi:8081` | `SERVER_IP:8081` |
| Pi-hole admin | `http://raspberrypi:8082/admin` | `SERVER_IP:8082/admin` |
| Dashboard | `https://media.<DOMAIN>` | — |

> ⚠️ For TV/media players at home, use the **local IP**, not Tailscale. Tailscale streaming is bottlenecked by home upload speed (~15 Mbps), which is not enough for reliable 1080p playback.

---

## Daily Workflow

1. **Request** content on Seerr
2. Sonarr/Radarr finds the release and sends it to qBittorrent
3. qBittorrent downloads through NordVPN to `/srv/downloads` on the NVMe
4. On completion, file is moved to `/mnt/media/movies` or `/mnt/media/tv`
5. Jellyfin picks it up on next scan
6. Bazarr downloads Spanish + English subtitles
7. **Watch** on TV via Fladder, or mobile via Jellyfin

---

## Recommended Client Apps

| Device | App |
|---|---|
| Google TV / Android TV | Fladder (use local IP) |
| iPhone / iPad | Jellyfin |
| Android | Jellyfin |
| Mac / PC | Browser or Jellyfin app |

---

## Common Fixes

| Problem | Fix |
|---|---|
| Stalled downloads | `docker compose restart gluetun && sleep 30 && docker compose restart qbittorrent` |
| VPN connected but no traffic (DNS timeouts in gluetun) | Gluetun picked a dead server. Pin a new one via `SERVER_HOSTNAMES=...` (see Step 6 to find a working server) |
| Torrents all error at 0% | Check `Session\DefaultSavePath` and `Downloads\SavePath` in `config/qbittorrent/qBittorrent/qBittorrent.conf` both equal `/data/downloads/` |
| qBittorrent queue not starting | Errored torrents count toward `max_active_torrents`. Remove them or raise the limit |
| Dead torrent | Remove + blocklist in Sonarr/Radarr, interactive-search for a better seeded release |
| qBittorrent password reset | `docker logs qbittorrent 2>&1 \| grep -i password` |
| Container won't start | `docker rm -f <name>` then `docker compose up -d` |
| No subtitles | Bazarr → System → Tasks → Search missing subtitles |
| Subtitles out of sync | Bazarr → find file → click sync icon |
| Hardcoded subtitles (anime) | Avoid `hardsub`/`subbed`/`ASS` releases; prefer clean WEB-DL |
| Buffering on TV | Dashboard → Active Streams. If transcoding, confirm `(HW)` tag (QSV active). If direct playing, switch client to local IP |
| Fladder can't connect | Make sure Tailscale is running if using hostname, or switch to local IP |
| Tailscale broke external DNS | `sudo chattr -i /etc/resolv.conf` and add a public nameserver; reboot restores Tailscale DNS |
| Seerr request fails, Radarr "timeout retrieving movie by TMDB ID" | Telefonica España can't route Cloudflare prefix `188.114.0.0/22`, which is what DNS returns for `api.radarr.video`. The compose pins `api.radarr.video` to a reachable Cloudflare anycast IP via `extra_hosts`. If Cloudflare ever rotates that IP, swap it for any other reachable `104.18.x.x` |
| .NET-based service (Radarr/Sonarr/Jellyfin) hangs on external HTTP requests | Likely AAAA records being returned for hosts with no IPv6 connectivity. The compose already disables IPv6 in those containers via `sysctls`. If you add a new .NET service, attach `sysctls: *no-ipv6` (the YAML anchor defined at the top) |

---

## Useful Commands

```bash
# Container status
docker compose ps

# Logs
docker logs jellyfin
docker logs gluetun

# Restart single service
docker compose restart jellyfin

# Restart everything
docker compose down && docker compose up -d

# Verify VPN public IP
docker exec gluetun wget -qO- https://ipinfo.io

# Disk usage
df -h /mnt/media /srv

# Resource usage
docker stats --no-stream
```
