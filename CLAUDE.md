# CLAUDE.md — Media Server Project Context

This file contains all the context needed to continue helping with this project.

---

## Setup Summary

A self-hosted media server running on a **Raspberry Pi 3B+** with a 500GB external HDD. Everything runs in Docker. The full setup guide is in `media-server-setup.md`.

---

## Hardware

- **Device**: Raspberry Pi 3B+
- **OS**: Raspberry Pi OS Lite 64-bit (Debian Bookworm)
- **External HDD**: 500GB, mounted at `/mnt/media`, formatted ext4
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
| Watchtower | Auto-updates containers at 4am daily | — |
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
| qBittorrent | `http://raspberrypi:8081` |

---

## Key Paths

```
~/mediaserver/
├── docker-compose.yml
├── .env                  # Contains only NORDVPN_PRIVATE_KEY
└── config/
    ├── bazarr/
    ├── jellyfin/
    ├── jellyseerr/       # Seerr config (kept as jellyseerr for migration compatibility)
    ├── sonarr/
    ├── radarr/
    ├── prowlarr/
    ├── qbittorrent/
    └── gluetun/

/mnt/media/
├── movies/
├── tv/
└── downloads/
    ├── completed/
    └: incomplete/
```

---

## Cron Jobs

```
0 4 * * 0 cd $HOME/mediaserver && docker compose restart gluetun && sleep 30 && docker compose restart qbittorrent
```

Weekly VPN refresh every Sunday at 4am to prevent stalled downloads.

---

## Configuration Decisions

**VPN**: NordVPN via gluetun using WireGuard + P2P servers. Only qBittorrent routes through VPN via `network_mode: service:gluetun`. All other services use normal network.

**Quality profiles (Radarr + Sonarr)**:
- Custom format `Blocklist` (score -1000): blocks `x265`, `HEVC`, `10.?bit` — these require transcoding on most devices
- Custom format `Preferred` (score +500): prefers `x264`, `H\.264`
- 4K and remux disabled entirely in Quality Definitions
- Reason: Pi 3B+ cannot transcode, Google TV needs direct play

**Subtitles**: Bazarr handles everything. Jellyfin's built-in subtitle download is disabled. OpenSubtitles plugin uninstalled. Bazarr downloads Spanish + English, uses audio track as sync reference.

**Tailscale MagicDNS**: Enabled. Pi accessible as `raspberrypi` from all Tailscale devices.

**TV playback**: Google TV uses Fladder app connected to local IP `192.168.1.47:8096` — NOT Tailscale, to avoid upload speed bottleneck (15 Mbps upload is not enough for reliable 1080p streaming via Tailscale).

---

## Known Issues & Solutions

- **Stalled downloads**: `docker compose restart gluetun && sleep 30 && docker compose restart qbittorrent`
- **VPN server throttling BitTorrent**: restart gluetun to switch to a fresh P2P server
- **qBittorrent "downloading metadata"**: usually DHT taking time, Force Reannounce helps. If persistent, restart gluetun
- **Hardcoded subtitles (anime)**: avoid releases with `hardsub`, `subbed`, `ASS` in name. Look for clean WEB-DL releases
- **Buffering on TV**: check Jellyfin Dashboard → Active Streams. If transcoding, force direct play. If direct playing, ensure TV uses local IP not Tailscale
- **Pi 3B+ USB bus saturation**: ethernet and HDD share USB 2.0 bus. Limit qBittorrent download speed to 3-4 MB/s if buffering occurs during active downloads

---

## Client Apps

| Device | App |
|---|---|
| Google TV | Fladder (local IP) |
| iPhone/iPad | Jellyfin |
| Android | Jellyfin |
| Mac/PC | Browser |

