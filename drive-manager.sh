#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

EXTERNAL_DRIVE_MOUNT="/mnt/media-drive"

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

show_help() {
    echo -e "${BLUE}External Drive Manager for Raspberry Pi${NC}"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  status      Show drive mount status and usage"
    echo "  mount       Mount the external drive"
    echo "  unmount     Safely unmount the external drive"
    echo "  list        List all available drives"
    echo "  space       Show detailed space usage"
    echo "  check       Check drive health (fsck)"
    echo "  help        Show this help message"
}

show_status() {
    echo -e "${BLUE}External Drive Status${NC}"
    echo "====================="
    
    if mountpoint -q "$EXTERNAL_DRIVE_MOUNT" 2>/dev/null; then
        local mounted_device=$(df "$EXTERNAL_DRIVE_MOUNT" | tail -1 | awk '{print $1}')
        local fs_type=$(df -T "$EXTERNAL_DRIVE_MOUNT" | tail -1 | awk '{print $2}')
        local total_space=$(df -h "$EXTERNAL_DRIVE_MOUNT" | tail -1 | awk '{print $2}')
        local used_space=$(df -h "$EXTERNAL_DRIVE_MOUNT" | tail -1 | awk '{print $3}')
        local available_space=$(df -h "$EXTERNAL_DRIVE_MOUNT" | tail -1 | awk '{print $4}')
        local usage_percent=$(df -h "$EXTERNAL_DRIVE_MOUNT" | tail -1 | awk '{print $5}')
        
        print_status "Drive is mounted"
        echo "  Device: $mounted_device"
        echo "  Mount Point: $EXTERNAL_DRIVE_MOUNT"
        echo "  Filesystem: $fs_type"
        echo "  Total Space: $total_space"
        echo "  Used Space: $used_space ($usage_percent)"
        echo "  Available: $available_space"
    else
        print_error "External drive is not mounted"
        echo "  Expected mount point: $EXTERNAL_DRIVE_MOUNT"
    fi
}

list_drives() {
    echo -e "${BLUE}Available Block Devices${NC}"
    echo "======================="
    
    # Show all block devices with details
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
    
    echo -e "\n${BLUE}USB Devices${NC}"
    echo "==========="
    lsusb | grep -i "mass storage\|disk" || echo "No USB storage devices found"
}

show_space_usage() {
    echo -e "${BLUE}Detailed Space Usage${NC}"
    echo "===================="
    
    if mountpoint -q "$EXTERNAL_DRIVE_MOUNT" 2>/dev/null; then
        echo -e "\n${BLUE}External Drive Usage:${NC}"
        df -h "$EXTERNAL_DRIVE_MOUNT"
        
        echo -e "\n${BLUE}Directory Sizes:${NC}"
        if [[ -d "$EXTERNAL_DRIVE_MOUNT/media" ]]; then
            du -h --max-depth=2 "$EXTERNAL_DRIVE_MOUNT/media" 2>/dev/null | sort -hr | head -10
        fi
        
        echo -e "\n${BLUE}Largest Files:${NC}"
        find "$EXTERNAL_DRIVE_MOUNT" -type f -size +1G 2>/dev/null | head -5 | while read file; do
            size=$(du -h "$file" | cut -f1)
            echo "  $size - $file"
        done
    else
        print_error "External drive not mounted"
    fi
    
    echo -e "\n${BLUE}Root Filesystem (Raspberry Pi SD Card):${NC}"
    df -h /
}

mount_drive() {
    if mountpoint -q "$EXTERNAL_DRIVE_MOUNT" 2>/dev/null; then
        print_status "Drive is already mounted"
        return 0
    fi
    
    echo -e "${BLUE}Available drives:${NC}"
    lsblk -dpno NAME,SIZE,TYPE | grep disk | grep -v loop
    
    echo ""
    read -p "Enter the device to mount (e.g., /dev/sda1): " device
    
    if [[ ! -b "$device" ]]; then
        print_error "Device $device not found"
        return 1
    fi
    
    # Create mount point if it doesn't exist
    if [[ ! -d "$EXTERNAL_DRIVE_MOUNT" ]]; then
        sudo mkdir -p "$EXTERNAL_DRIVE_MOUNT"
    fi
    
    # Try to mount
    if sudo mount "$device" "$EXTERNAL_DRIVE_MOUNT"; then
        print_status "Successfully mounted $device to $EXTERNAL_DRIVE_MOUNT"
        sudo chown -R 1000:1000 "$EXTERNAL_DRIVE_MOUNT"
    else
        print_error "Failed to mount $device"
        return 1
    fi
}

unmount_drive() {
    if ! mountpoint -q "$EXTERNAL_DRIVE_MOUNT" 2>/dev/null; then
        print_status "Drive is not mounted"
        return 0
    fi
    
    print_info "Stopping Docker services first..."
    if [[ -f "$(dirname "$0")/manage.sh" ]]; then
        "$(dirname "$0")/manage.sh" stop
    fi
    
    print_info "Unmounting external drive..."
    if sudo umount "$EXTERNAL_DRIVE_MOUNT"; then
        print_status "Successfully unmounted external drive"
    else
        print_error "Failed to unmount drive - may be in use"
        echo "Try: sudo fuser -km $EXTERNAL_DRIVE_MOUNT"
        return 1
    fi
}

check_drive() {
    if mountpoint -q "$EXTERNAL_DRIVE_MOUNT" 2>/dev/null; then
        print_error "Drive is mounted - unmount first for filesystem check"
        return 1
    fi
    
    echo -e "${BLUE}Available unmounted drives:${NC}"
    lsblk -dpno NAME,SIZE,FSTYPE | grep -v "^/dev/loop"
    
    echo ""
    read -p "Enter the device to check (e.g., /dev/sda1): " device
    
    if [[ ! -b "$device" ]]; then
        print_error "Device $device not found"
        return 1
    fi
    
    local fs_type=$(lsblk -no FSTYPE "$device")
    
    print_info "Running filesystem check on $device ($fs_type)..."
    case "$fs_type" in
        ext4|ext3|ext2)
            sudo fsck.ext4 -f "$device"
            ;;
        ntfs)
            sudo ntfsfix "$device"
            ;;
        exfat)
            sudo fsck.exfat "$device"
            ;;
        *)
            print_warning "Unsupported filesystem type: $fs_type"
            ;;
    esac
}

case "$1" in
    status)
        show_status
        ;;
    mount)
        mount_drive
        ;;
    unmount)
        unmount_drive
        ;;
    list)
        list_drives
        ;;
    space)
        show_space_usage
        ;;
    check)
        check_drive
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        show_status
        ;;
    *)
        print_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
