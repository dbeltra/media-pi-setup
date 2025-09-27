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

echo -e "${BLUE}🔍 Drive Diagnostic Tool${NC}"
echo "========================="

# Show all block devices
echo -e "\n${BLUE}All Block Devices:${NC}"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL

# Show disk information
echo -e "\n${BLUE}Disk Information:${NC}"
sudo fdisk -l 2>/dev/null | grep -E "^Disk /dev/(sd|nvme|mmcblk)"

# Check for USB devices
echo -e "\n${BLUE}USB Storage Devices:${NC}"
lsusb | grep -i "mass storage\|disk" || echo "No USB storage devices found"

# Check dmesg for recent drive events
echo -e "\n${BLUE}Recent Drive Events (last 20 lines):${NC}"
sudo dmesg | grep -i -E "(usb|sd[a-z]|error|fail)" | tail -20

# Check current mounts
echo -e "\n${BLUE}Current Mounts:${NC}"
mount | grep -E "^/dev/(sd|nvme|mmcblk)" | column -t

# Check fstab entries
echo -e "\n${BLUE}Fstab Entries:${NC}"
grep -v "^#" /etc/fstab | grep -v "^$"

# Suggest next steps
echo -e "\n${BLUE}Diagnostic Summary:${NC}"
echo "==================="

# Check if external drives are detected
EXTERNAL_DRIVES=$(lsblk -dpno NAME | grep -v "$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')" | wc -l)
if [[ $EXTERNAL_DRIVES -gt 0 ]]; then
    print_status "External drives detected: $EXTERNAL_DRIVES"
else
    print_error "No external drives detected"
    echo "  - Check USB connection"
    echo "  - Try a different USB port"
    echo "  - Check if drive has power"
fi

# Check if any drives need formatting
UNFORMATTED=$(lsblk -no NAME,FSTYPE | grep -E "sd[a-z][0-9]" | awk '$2=="" {print $1}' | wc -l)
if [[ $UNFORMATTED -gt 0 ]]; then
    print_warning "Unformatted partitions found: $UNFORMATTED"
    echo "  - These may need to be formatted before use"
    echo "  - Run setup.sh to format them"
fi

# Check mount point
if [[ -d "/mnt/media-drive" ]]; then
    if mountpoint -q "/mnt/media-drive" 2>/dev/null; then
        print_status "Media drive is mounted"
    else
        print_warning "Mount point exists but drive not mounted"
    fi
else
    print_info "Mount point /mnt/media-drive does not exist yet"
fi

echo -e "\n${BLUE}Next Steps:${NC}"
echo "1. If no external drives detected: Check physical connection"
echo "2. If drives detected but unformatted: Run ./setup.sh to format"
echo "3. If mount fails: Check filesystem type and drive health"
echo "4. For more help: Check 'sudo dmesg | tail -20' for error messages"
