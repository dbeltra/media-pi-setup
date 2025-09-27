# Media Server Setup

A complete Docker-based media server setup with Radarr, Sonarr, Prowlarr, Transmission (with VPN), and Plex, plus automated JustWatch movie importing.

## Features

- **Radarr** - Movie collection management
- **Sonarr** - TV show collection management
- **Prowlarr** - Indexer management
- **Transmission** - Download client with VPN protection
- **Plex** - Media streaming server
- **JustWatch Integration** - Automatically import movies from your JustWatch lists

## Quick Start

1. **Connect your external drive** to the Raspberry Pi

2. **Run the setup script:**

   ```bash
   ./setup.sh
   ```

   The script will:

   - Detect and help mount your external drive
   - Create all necessary directories on the external drive
   - Set up automatic mounting in `/etc/fstab`
   - Configure Python environment and cron jobs

3. **Configure your environment:**
   Edit the `.env` file with your API keys and credentials:

   - TMDB API key (get from https://www.themoviedb.org/settings/api)
   - Radarr API key (generated after first run)
   - JustWatch list ID (from your public list URL)
   - VPN credentials (NordVPN)
   - Plex claim token (from https://account.plex.tv/en/claim)

4. **Start the services:**

   ```bash
   ./manage.sh start
   ```

5. **Configure your applications:**
   - Set up indexers in Prowlarr
   - Configure download client in Radarr/Sonarr (use `transmission:9091`)
   - Add your media libraries in Plex

## Management Commands

```bash
./manage.sh start      # Start all services
./manage.sh stop       # Stop all services
./manage.sh restart    # Restart all services
./manage.sh status     # Show service status
./manage.sh logs       # Show all logs
./manage.sh update     # Update to latest images
./manage.sh cleanup    # Clean up Docker resources
./manage.sh test-justwatch  # Test JustWatch import
```

## External Drive Management

```bash
./drive-manager.sh status    # Show drive status and usage
./drive-manager.sh mount     # Mount external drive
./drive-manager.sh unmount   # Safely unmount drive
./drive-manager.sh list      # List all available drives
./drive-manager.sh space     # Show detailed space usage
./drive-manager.sh check     # Check drive health (fsck)
```

## Health Monitoring

```bash
./health-check.sh      # Check system health and service status
```

## Service URLs

Once running, access your services at:

- **Radarr**: http://localhost:7878
- **Sonarr**: http://localhost:8989
- **Prowlarr**: http://localhost:9696
- **Transmission**: http://localhost:9091
- **Plex**: http://localhost:32400/web

## Directory Structure

**External Drive** (`/mnt/media-drive/`):

```
/mnt/media-drive/
├── media/
│   ├── downloads/
│   │   ├── completed/     # Finished downloads
│   │   ├── incomplete/    # In-progress downloads
│   │   └── watch/         # Watch folder for manual torrents
│   ├── movies/            # Movie library
│   └── tv/                # TV show library
└── media-server-config/
    ├── transmission/      # Transmission config
    ├── radarr/           # Radarr config
    ├── sonarr/           # Sonarr config
    ├── prowlarr/         # Prowlarr config
    ├── plex/             # Plex config
    └── scripts/          # Log files
```

**Raspberry Pi** (minimal storage):

```
~/raspberry/              # This project
├── scripts/              # Python scripts
├── docker/              # Docker compose files
└── .venv/               # Python virtual environment
```

## JustWatch Integration

The setup automatically configures a cron job that runs every 12 hours to import movies from your JustWatch list into Radarr.

### Manual JustWatch Import

```bash
./manage.sh test-justwatch
```

### Configure JustWatch List

1. Create a public list on JustWatch
2. Copy the list ID from the URL (e.g., `lst123456`)
3. Add it to your `.env` file as `JUSTWATCH_LIST_ID`

## Troubleshooting

### Check Service Health

```bash
./health-check.sh
```

### View Logs

```bash
./manage.sh logs [service_name]
```

### Common Issues

1. **VPN not working**: Check your NordVPN credentials in `.env`
2. **Downloads not moving**: Verify folder permissions and paths
3. **Services not accessible**: Check if ports are already in use
4. **Plex not claiming**: Make sure PLEX_CLAIM token is valid (expires in 4 minutes)

## Security Notes

- Services are bound to localhost only for security
- VPN is required for Transmission downloads
- All containers run with user ID 1000:1000

## Requirements

- **Raspberry Pi 4** (recommended) with Raspberry Pi OS
- **External USB drive** (for media storage - the Pi's SD card is too small)
- Docker and Docker Compose
- Python 3.x (for JustWatch script)
- VPN subscription (NordVPN configured by default)
- Stable internet connection

### Raspberry Pi Specific Notes

- **External Drive**: Essential due to limited SD card space. USB 3.0 drive recommended for better performance
- **Power Supply**: Ensure adequate power for Pi + external drive (official Pi power supply recommended)
- **Cooling**: Consider adding heatsinks or fan for continuous operation
- **Network**: Wired connection preferred for stability during large downloads

## Configuration

All configuration is done through the `.env` file. See `.env.example` for required variables.

## Updates

To update all services to the latest versions:

```bash
./manage.sh update
```
