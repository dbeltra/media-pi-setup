#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

echo -e "${BLUE}🧹 Cleanup and Reset Script${NC}"
echo "============================"

print_warning "This will clean up all Docker containers, images, and media files on the Pi"
print_warning "Make sure your external drive is properly mounted first!"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    print_error "Aborted by user"
    exit 1
fi

# Check if external drive is mounted
if ! mountpoint -q "/mnt/media-drive" 2>/dev/null; then
    print_error "External drive is not mounted at /mnt/media-drive"
    print_info "Please mount it first with: sudo mount /dev/sda1 /mnt/media-drive"
    exit 1
fi

print_status "External drive is mounted"

# Stop all containers
print_info "Stopping all Docker containers..."
docker stop $(docker ps -aq) 2>/dev/null || true

# Remove all containers
print_info "Removing all Docker containers..."
docker rm $(docker ps -aq) 2>/dev/null || true

# Clean up Docker system
print_info "Cleaning up Docker system..."
docker system prune -af

# Remove media directories from Pi's filesystem (they should be on external drive)
print_info "Removing media directories from Pi's SD card..."
sudo rm -rf /media/downloads /media/movies /media/tv 2>/dev/null || true

# Remove any config directories from Pi's home
print_info "Removing config directories from Pi's home..."
rm -rf ~/media-server-config 2>/dev/null || true

# Show current disk usage
print_info "Current disk usage on Pi:"
df -h /

print_info "Current disk usage on external drive:"
df -h /mnt/media-drive

print_status "Cleanup completed!"
print_info "You can now run ./setup.sh to start fresh"
