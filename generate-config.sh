#!/usr/bin/env bash
# generate-config.sh — reads .env, writes www/config.json for the media dashboard.
# Run once after setup, and again whenever you rotate keys or passwords.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
OUT_DIR="$SCRIPT_DIR/www"
OUT_FILE="$OUT_DIR/config.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at $ENV_FILE"; exit 1
fi

set -o allexport
source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')
set +o allexport

mkdir -p "$OUT_DIR"

required=(SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY JELLYFIN_API_KEY BAZARR_API_KEY PIHOLE_PASSWORD QBITTORRENT_PASSWORD DOMAIN)
missing=()
for key in "${required[@]}"; do
  [[ -z "${!key:-}" ]] && missing+=("$key")
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required .env variables: ${missing[*]}"; exit 1
fi

cat > "$OUT_FILE" <<JSONEOF
{
  "domain": "${DOMAIN}",
  "services": {
    "jellyfin":    { "url": "https://jellyfin.media.${DOMAIN}",    "apiKey": "${JELLYFIN_API_KEY}" },
    "sonarr":      { "url": "https://sonarr.media.${DOMAIN}",      "apiKey": "${SONARR_API_KEY}" },
    "radarr":      { "url": "https://radarr.media.${DOMAIN}",      "apiKey": "${RADARR_API_KEY}" },
    "prowlarr":    { "url": "https://prowlarr.media.${DOMAIN}",    "apiKey": "${PROWLARR_API_KEY}" },
    "bazarr":      { "url": "https://bazarr.media.${DOMAIN}",      "apiKey": "${BAZARR_API_KEY}" },
    "qbittorrent": { "url": "https://qbittorrent.media.${DOMAIN}", "password": "${QBITTORRENT_PASSWORD}" },
    "pihole":      { "url": "https://pihole.media.${DOMAIN}",      "password": "${PIHOLE_PASSWORD}" },
    "maintainerr": { "url": "http://raspberrypi:6246" },
    "seerr":       { "url": "https://seerr.media.${DOMAIN}" }
  }
}
JSONEOF

echo "✓ Written to $OUT_FILE"
echo "  Run: docker compose restart caddy"
