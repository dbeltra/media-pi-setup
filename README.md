# Raspberry Pi Media Server Setup

A complete guide to setting up a self-hosted media server on a Raspberry Pi 3B+ with Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent (via NordVPN), Seerr, Bazarr and Tailscale.

---

## Hardware

- Raspberry Pi 3B+
- External HDD (500GB, USB)
- SD Card (32GB+)

---

## Stack

| Service | Purpose | Port |
|---|---|---|
| Jellyfin | Media server | 8096 |
| Seerr | Request UI | 5055 |
| Sonarr | TV automation | 8989 |
| Radarr | Movie automation | 7878 |
| Prowlarr | Indexer manager | 9696 |
| qBittorrent | Torrent client | 8081 |
| Gluetun | NordVPN gateway | — |
| Tailscale | Remote access | — |
| Watchtower | Auto-updates containers | — |
| Bazarr | Subtitle manager | 6767 |

---

## Step 1 — Flash SD Card

1. Download and install [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Choose **Raspberry Pi OS Lite (64-bit)**
3. In the ⚙️ settings before writing:
   - Enable SSH
   - Set username/password
   - Set hostname (e.g. `raspberrypi`)
   - Set timezone to `Europe/Madrid`
4. Flash and boot the Pi

Connect via SSH:
```bash
ssh pi@raspberrypi.local
# or by IP
ssh YOUR_USERNAME@YOUR_PI_LOCAL_IP
```

---

## Step 2 — System Update

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git
```

Fix locale warning if present:
```bash
sudo sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen
sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
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

Note the UUID from the mkfs output, then mount:
```bash
sudo mkdir -p /mnt/media
sudo mount /dev/sda1 /mnt/media
```

Make permanent — add to `/etc/fstab`:
```
UUID=YOUR-UUID  /mnt/media  ext4  defaults,nofail  0  2
```

Create folder structure:
```bash
sudo mkdir -p /mnt/media/{movies,tv,downloads/{completed,incomplete}}
sudo chown -R $USER:$USER /mnt/media
sudo systemctl daemon-reload
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
# Returns your permanent Tailscale IP e.g. 100.x.x.x
```

Install Tailscale on all client devices (Mac, iPhone, Android, TV) and log in with the same account. All services will be accessible via the Tailscale IP from anywhere.

---

## Step 6 — Get NordVPN WireGuard Key

Install NordVPN CLI temporarily:
```bash
sudo apt install -y nordvpn wireguard-tools
newgrp nordvpn
nordvpn login --token  # Generate token at https://my.nordaccount.com/dashboard/nordvpn/access-tokens/
nordvpn set technology nordlynx
nordvpn connect
sudo wg showconf nordlynx  # Copy the PrivateKey value
nordvpn disconnect
sudo apt remove -y nordvpn wireguard-tools
sudo apt autoremove -y
```

---

## Step 7 — Docker Compose Setup

```bash
mkdir -p ~/mediaserver
cd ~/mediaserver
```

Create `.env` file:
```bash
nano .env
```
```
NORDVPN_PRIVATE_KEY=YOUR_WIREGUARD_PRIVATE_KEY
```

Create `docker-compose.yml`:
```yaml
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
      - SERVER_CATEGORIES=P2P
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
      - /mnt/media/downloads:/data/downloads
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
    volumes:
      - ./config/jellyfin:/config
      - /mnt/media/movies:/data/movies
      - /mnt/media/tv:/data/tv
    ports:
      - 8096:8096
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
    ports:
      - 8989:8989
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
    volumes:
      - ./config/radarr:/config
      - /mnt/media:/data
    ports:
      - 7878:7878
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
    restart: unless-stopped

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      - WATCHTOWER_CLEANUP=true
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

### Prowlarr (`http://YOUR_PI_LOCAL_IP:9696`)
1. Set up authentication
2. Add indexers: YTS, EZTV, The Pirate Bay, Knaben, Nyaa
3. Settings → Apps → Add Radarr and Sonarr:
   - Prowlarr server: `http://prowlarr:9696`
   - Radarr server: `http://radarr:7878` + API key from Radarr
   - Sonarr server: `http://sonarr:8989` + API key from Sonarr

### qBittorrent (`http://YOUR_PI_LOCAL_IP:8081`)
- Get temp password: `docker logs qbittorrent 2>&1 | grep -i password`
- Tools → Options → Downloads:
  - Default save path: `/data/downloads/completed`
  - Incomplete path: `/data/downloads/incomplete`
- Tools → Options → Web UI: set a permanent password
- Connection port: `6881`
- Enable DHT, PeX, Local Peer Discovery

### Radarr (`http://YOUR_PI_LOCAL_IP:7878`)
- Settings → Download Clients → Add qBittorrent:
  - Host: `YOUR_PI_LOCAL_IP`, Port: `8081`
  - Username/password from qBittorrent
- Settings → Media Management → Root Folders → `/data/movies`

### Sonarr (`http://YOUR_PI_LOCAL_IP:8989`)
- Same download client setup as Radarr
- Root folder: `/data/tv`

### Jellyfin (`http://YOUR_PI_LOCAL_IP:8096`)
- First run wizard → create admin account
- Add Movies library → `/data/movies`
- Add TV Shows library → `/data/tv`

### Seerr (`http://YOUR_PI_LOCAL_IP:5055`)
- Sign in with Jellyfin
- Jellyfin URL: `http://jellyfin:8096`
- External URL: `http://YOUR_TAILSCALE_IP:8096`
- Add Radarr and Sonarr with their API keys

---

## Step 10 — Quality Profiles

### Radarr & Sonarr — Block bad formats
Settings → Custom Formats → Add `Blocklist`:
- Condition: Release Title matches `x265`
- Condition: Release Title matches `HEVC`
- Condition: Release Title matches `10.?bit`

Set score to **-1000** in quality profile.

Add `Preferred` custom format:
- Condition: Release Title matches `x264`
- Condition: Release Title matches `H\.264`

Set score to **+500** in quality profile.

### Disable 4K and remux in Quality Definitions
Set max to `0 B` for:
- HDTV-2160p, WEBDL-2160p, WEBRip-2160p
- Bluray-2160p, Remux-2160p, Remux-1080p
- BR-DISK, Raw-HD

---

## Step 11 — Subtitles (Bazarr)

Bazarr handles all subtitle management automatically. Do NOT use Jellyfin's built-in subtitle download — disable it.

### Configure Bazarr (`http://YOUR_PI_LOCAL_IP:6767`)

1. Settings → Providers → add **OpenSubtitles.com** with your credentials
2. Settings → Sonarr:
   - Enable ✅, Host: `sonarr`, Port: `8989`, API key from Sonarr
3. Settings → Radarr:
   - Enable ✅, Host: `radarr`, Port: `7878`, API key from Radarr
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

Enable MagicDNS so you can use the Pi hostname instead of IP addresses from any Tailscale device:

1. Go to https://login.tailscale.com/admin/dns
2. Enable **MagicDNS**
3. Add global nameserver `100.100.100.100`

All services are now accessible as `http://raspberrypi:PORT` from any device on your Tailscale network.

---

```bash
# Check all containers
docker compose ps

# View logs for a service
docker logs jellyfin
docker logs gluetun

# Restart a single service
docker compose restart jellyfin

# Restart everything
docker compose down && docker compose up -d

# Fix stalled downloads (switch to fresh VPN server)
docker compose restart gluetun && sleep 30 && docker compose restart qbittorrent

# Check VPN is working
docker exec gluetun wget -qO- https://ipinfo.io

# Check disk usage
df -h /mnt/media

# Check CPU/RAM usage
docker stats --no-stream
```

---

## Cron Jobs

Weekly VPN refresh every Sunday at 4am — prevents stalled downloads from VPN server throttling:

```bash
crontab -e
```

Add:
```
0 4 * * 0 cd $HOME/mediaserver && docker compose restart gluetun && sleep 30 && docker compose restart qbittorrent
```

Verify:
```bash
crontab -l
```

---

## Directory Structure

```
~/mediaserver/
├── docker-compose.yml
├── .env                  # NordVPN key — never commit to git
└── config/
    ├── bazarr/
    ├── jellyfin/
    ├── jellyseerr/       # Seerr config (kept as jellyseerr for migration compatibility)
    ├── sonarr/
    ├── radarr/
    ├── prowlarr/
    ├── qbittorrent/
    └── gluetun/

/mnt/media/               # External HDD
├── movies/
├── tv/
└── downloads/
    ├── completed/
    └── incomplete/
```

---

## Access URLs

With MagicDNS enabled, use the hostname from any Tailscale device. Use the local IP when on the same network without Tailscale.

| Service | Hostname | Local IP |
|---|---|---|
| Jellyfin | `http://raspberrypi:8096` | `YOUR_PI_LOCAL_IP:8096` |
| Seerr | `http://raspberrypi:5055` | `YOUR_PI_LOCAL_IP:5055` |
| Radarr | `http://raspberrypi:7878` | `YOUR_PI_LOCAL_IP:7878` |
| Sonarr | `http://raspberrypi:8989` | `YOUR_PI_LOCAL_IP:8989` |
| Prowlarr | `http://raspberrypi:9696` | `YOUR_PI_LOCAL_IP:9696` |
| Bazarr | `http://raspberrypi:6767` | `YOUR_PI_LOCAL_IP:6767` |
| qBittorrent | `http://raspberrypi:8081` | `YOUR_PI_LOCAL_IP:8081` |

> ⚠️ For TV/media players at home, always use the **local IP** — routing through Tailscale adds latency and is limited by your home upload speed (typically 15-20 Mbps). Use Tailscale hostname only when away from home.

---

## Daily Workflow

1. **Request** content on Seerr (`http://raspberrypi:5055`)
2. Sonarr/Radarr finds and sends torrent to qBittorrent
3. qBittorrent downloads through NordVPN P2P server
4. File is moved to `/mnt/media/movies` or `/mnt/media/tv`
5. Jellyfin picks it up on next scan (automatic)
6. Bazarr automatically downloads Spanish + English subtitles
7. **Watch** on TV via Fladder app or mobile via Jellyfin app

---

## Recommended Client Apps

| Device | App |
|---|---|
| Android TV / Google TV | Fladder |
| iPhone / iPad | Jellyfin |
| Android | Jellyfin |
| Mac / PC | Browser or Jellyfin app |

---

## Common Fixes

| Problem | Fix |
|---|---|
| Stalled downloads | `docker compose restart gluetun && sleep 30 && docker compose restart qbittorrent` |
| Dead torrent | Remove + blocklist in Sonarr/Radarr, interactive search for better seeded release |
| VPN down | `docker compose restart gluetun` |
| qBittorrent WebUI unreachable | `docker compose restart qbittorrent` |
| qBittorrent password reset | `docker logs qbittorrent 2>&1 \| grep -i password` |
| Container won't start | `docker rm -f <name>` then `docker compose up -d` |
| No subtitles | Bazarr → System → Tasks → Search missing subtitles |
| Subtitles out of sync | Bazarr → find file → click sync icon |
| Hardcoded subtitles | Delete and re-download from Radarr/Sonarr, avoid `hardsub`/`subbed` releases |
| Buffering on TV | Check Dashboard → Active Streams — if transcoding, set client quality to max. If direct playing, use local IP not Tailscale |
| Fladder can't connect | Make sure Tailscale is running if using hostname, or switch to local IP `YOUR_PI_LOCAL_IP:8096` |
