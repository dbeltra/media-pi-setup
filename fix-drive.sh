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

DRIVE="/dev/sda"

echo -e "${BLUE}🔧 Drive Recovery Tool${NC}"
echo "======================"

print_warning "This tool will attempt to recover a drive with I/O errors"
print_warning "WARNING: This will DESTROY ALL DATA on $DRIVE"
echo ""
read -p "Are you absolutely sure you want to continue? Type 'YES' to proceed: " confirm

if [[ "$confirm" != "YES" ]]; then
    print_error "Aborted by user"
    exit 1
fi

print_info "Starting drive recovery process..."

# Step 1: Try to clear any existing mounts
print_info "Step 1: Unmounting any existing mounts..."
sudo umount ${DRIVE}* 2>/dev/null || true

# Step 2: Try to zero out the beginning of the drive
print_info "Step 2: Clearing partition table..."
if sudo dd if=/dev/zero of=$DRIVE bs=1M count=100 2>/dev/null; then
    print_status "Successfully cleared first 100MB"
else
    print_warning "Failed to clear drive - continuing anyway"
fi

# Step 3: Wait for system to recognize changes
print_info "Step 3: Waiting for system to recognize changes..."
sleep 5
sudo partprobe $DRIVE 2>/dev/null || true

# Step 4: Create new partition table
print_info "Step 4: Creating new partition table..."
if sudo parted $DRIVE --script mklabel gpt 2>/dev/null; then
    print_status "Created GPT partition table"
else
    print_error "Failed to create partition table"
    exit 1
fi

# Step 5: Create partition
print_info "Step 5: Creating partition..."
if sudo parted $DRIVE --script mkpart primary ext4 0% 100% 2>/dev/null; then
    print_status "Created partition"
else
    print_error "Failed to create partition"
    exit 1
fi

# Step 6: Wait and probe
print_info "Step 6: Waiting for partition to be recognized..."
sleep 5
sudo partprobe $DRIVE 2>/dev/null || true

# Step 7: Format the partition
PARTITION="${DRIVE}1"
print_info "Step 7: Formatting $PARTITION as ext4..."
if sudo mkfs.ext4 -F $PARTITION 2>/dev/null; then
    print_status "Successfully formatted $PARTITION"
else
    print_error "Failed to format partition"
    exit 1
fi

# Step 8: Test mount
print_info "Step 8: Testing mount..."
TEMP_MOUNT="/tmp/test-mount"
sudo mkdir -p $TEMP_MOUNT

if sudo mount $PARTITION $TEMP_MOUNT 2>/dev/null; then
    print_status "Successfully mounted $PARTITION"
    
    # Test write
    if sudo touch $TEMP_MOUNT/test-file 2>/dev/null; then
        print_status "Write test successful"
        sudo rm $TEMP_MOUNT/test-file
    else
        print_warning "Write test failed"
    fi
    
    sudo umount $TEMP_MOUNT
    sudo rmdir $TEMP_MOUNT
else
    print_error "Failed to mount formatted partition"
    exit 1
fi

print_status "Drive recovery completed successfully!"
print_info "You can now run ./setup.sh and use $PARTITION"

# Show final status
echo -e "\n${BLUE}Final Drive Status:${NC}"
lsblk $DRIVE
