#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
EXTERNAL_DRIVE_MOUNT="/mnt/media-drive"  # Default mount point for external drive
MEDIA_ROOT="$EXTERNAL_DRIVE_MOUNT/media"
CONFIG_ROOT="$EXTERNAL_DRIVE_MOUNT/media-server-config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PATH="$SCRIPT_DIR/.venv"

echo -e "${BLUE}🎬 Media Server Setup Script (Raspberry Pi)${NC}"
echo "=============================================="

# Function to print status
print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   print_error "This script should not be run as root"
   exit 1
fi

# Function to detect external drives
detect_external_drives() {
    echo -e "\n${BLUE}Detecting external drives...${NC}"
    
    # List available block devices (excluding loop devices and the root partition)
    local drives=($(lsblk -dpno NAME,SIZE,TYPE | grep disk | grep -v loop | awk '{print $1}'))
    local root_device=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
    
    echo "Available drives:"
    for drive in "${drives[@]}"; do
        local size=$(lsblk -dno SIZE "$drive")
        local model=$(lsblk -dno MODEL "$drive" 2>/dev/null || echo "Unknown")
        if [[ "$drive" != "$root_device" ]]; then
            echo "  $drive ($size) - $model"
        fi
    done
}

# Function to setup external drive
setup_external_drive() {
    detect_external_drives
    
    echo -e "\n${YELLOW}External drive setup required for Raspberry Pi${NC}"
    echo "This script will help you mount an external drive for media storage."
    echo ""
    
    # Check if mount point already exists and is mounted
    if mountpoint -q "$EXTERNAL_DRIVE_MOUNT" 2>/dev/null; then
        local mounted_device=$(df "$EXTERNAL_DRIVE_MOUNT" | tail -1 | awk '{print $1}')
        local available_space=$(df -h "$EXTERNAL_DRIVE_MOUNT" | tail -1 | awk '{print $4}')
        print_status "External drive already mounted: $mounted_device ($available_space available)"
        return 0
    fi
    
    echo "Please specify your external drive device (e.g., /dev/sda1, /dev/sdb1):"
    echo "Or press Enter to auto-detect the largest non-root drive"
    read -p "Drive device: " drive_device
    
    if [[ -z "$drive_device" ]]; then
        # Auto-detect largest external drive
        local root_device=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
        drive_device=$(lsblk -dpno NAME,SIZE | grep -v "$root_device" | sort -k2 -hr | head -1 | awk '{print $1}')
        
        if [[ -z "$drive_device" ]]; then
            print_error "No external drive detected"
            exit 1
        fi
        
        # Check if it's a whole disk, if so, use first partition
        if [[ ! "$drive_device" =~ [0-9]$ ]]; then
            drive_device="${drive_device}1"
        fi
        
        print_status "Auto-detected drive: $drive_device"
    fi
    
    # Verify the device exists
    if [[ ! -b "$drive_device" ]]; then
        print_error "Device $drive_device not found"
        exit 1
    fi
    
    # Create mount point
    if [[ ! -d "$EXTERNAL_DRIVE_MOUNT" ]]; then
        sudo mkdir -p "$EXTERNAL_DRIVE_MOUNT"
        print_status "Created mount point: $EXTERNAL_DRIVE_MOUNT"
    fi
    
    # Check if the partition exists
    if [[ ! -b "$drive_device" ]]; then
        local base_device=$(echo "$drive_device" | sed 's/[0-9]*$//')
        print_warning "Partition $drive_device does not exist"
        
        # Check if base device has I/O errors
        if ! sudo fdisk -l "$base_device" >/dev/null 2>&1; then
            print_error "Cannot access $base_device - possible hardware issue"
            echo "This could indicate:"
            echo "  - Drive failure or corruption"
            echo "  - Insufficient power supply"
            echo "  - Bad USB cable or port"
            echo "  - Drive needs repair"
            echo ""
            echo "Troubleshooting steps:"
            echo "  1. Try a different USB port (preferably USB 3.0)"
            echo "  2. Use a powered USB hub"
            echo "  3. Try a different USB cable"
            echo "  4. Test the drive on another computer"
            echo "  5. Check: sudo dmesg | grep -i sda"
            exit 1
        fi
        
        echo "Available partitions on $base_device:"
        lsblk "$base_device" 2>/dev/null || echo "No partitions found"
        echo ""
        echo "Options:"
        echo "1) Create and format a new partition"
        echo "2) Specify a different existing partition"
        read -p "Choose option (1-2): " choice
        
        case $choice in
            1)
                print_warning "This will create a new partition and format the drive"
                echo "WARNING: This will erase all data on $base_device"
                read -p "Are you sure? Type 'yes' to continue: " confirm
                if [[ "$confirm" != "yes" ]]; then
                    print_error "Aborted by user"
                    exit 1
                fi
                
                # Create partition table and partition
                print_info "Creating partition on $base_device..."
                sudo parted "$base_device" --script mklabel gpt
                sudo parted "$base_device" --script mkpart primary ext4 0% 100%
                
                # Wait for partition to be recognized
                sleep 3
                sudo partprobe "$base_device"
                
                # Format as ext4
                print_info "Formatting $drive_device as ext4..."
                sudo mkfs.ext4 -F "$drive_device"
                ;;
            2)
                echo "Available devices:"
                lsblk -dpno NAME,SIZE,FSTYPE
                read -p "Enter the partition device: " drive_device
                if [[ ! -b "$drive_device" ]]; then
                    print_error "Device $drive_device not found"
                    exit 1
                fi
                ;;
        esac
    fi
    
    # Get filesystem type
    local fs_type=$(lsblk -no FSTYPE "$drive_device" 2>/dev/null)
    if [[ -z "$fs_type" ]]; then
        print_warning "Could not detect filesystem type for $drive_device"
        echo "The drive might not be formatted."
        echo "Do you want to format it as ext4? (recommended for Raspberry Pi)"
        read -p "Format as ext4? (yes/no): " format_choice
        
        if [[ "$format_choice" == "yes" ]]; then
            print_info "Formatting $drive_device as ext4..."
            sudo mkfs.ext4 -F "$drive_device"
            fs_type="ext4"
        else
            echo "Common filesystem types: ext4, ntfs, exfat, vfat"
            read -p "Enter filesystem type: " fs_type
        fi
    fi
    
    print_info "Using filesystem type: $fs_type"
    
    # Mount the drive
    if sudo mount -t "$fs_type" "$drive_device" "$EXTERNAL_DRIVE_MOUNT"; then
        print_status "Successfully mounted $drive_device to $EXTERNAL_DRIVE_MOUNT"
    else
        print_error "Failed to mount $drive_device"
        print_info "Recent kernel messages:"
        sudo dmesg | tail -5
        print_info "You may need to:"
        echo "  1. Check if the drive is properly connected"
        echo "  2. Try a different filesystem type"
        echo "  3. Format the drive first"
        exit 1
    fi
    
    # Add to fstab for persistent mounting
    local uuid=$(lsblk -no UUID "$drive_device")
    if [[ -n "$uuid" ]]; then
        local fstab_entry="UUID=$uuid $EXTERNAL_DRIVE_MOUNT $fs_type defaults,nofail,uid=1000,gid=1000 0 2"
        
        if ! grep -q "$uuid" /etc/fstab; then
            echo "$fstab_entry" | sudo tee -a /etc/fstab > /dev/null
            print_status "Added drive to /etc/fstab for automatic mounting"
        else
            print_status "Drive already in /etc/fstab"
        fi
    else
        print_warning "Could not get UUID for $drive_device - manual fstab entry may be needed"
    fi
    
    # Set proper ownership
    sudo chown -R 1000:1000 "$EXTERNAL_DRIVE_MOUNT"
    print_status "Set ownership of external drive to user 1000:1000"
}

# Setup external drive first
setup_external_drive

# Create media directories
echo -e "\n${BLUE}Creating media directories...${NC}"
MEDIA_DIRS=(
    "$MEDIA_ROOT/downloads/completed"
    "$MEDIA_ROOT/downloads/incomplete" 
    "$MEDIA_ROOT/downloads/watch"
    "$MEDIA_ROOT/movies"
    "$MEDIA_ROOT/tv"
)

for dir in "${MEDIA_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
        if sudo mkdir -p "$dir"; then
            print_status "Created $dir"
            # Set permissions for media user (1000:1000)
            sudo chown -R 1000:1000 "$dir"
            sudo chmod -R 755 "$dir"
        else
            print_error "Failed to create $dir"
            exit 1
        fi
    else
        print_status "$dir already exists"
    fi
done

# Create config directories
echo -e "\n${BLUE}Creating config directories...${NC}"
CONFIG_DIRS=(
    "$CONFIG_ROOT/transmission"
    "$CONFIG_ROOT/radarr"
    "$CONFIG_ROOT/sonarr"
    "$CONFIG_ROOT/prowlarr"
    "$CONFIG_ROOT/plex"
    "$CONFIG_ROOT/scripts"
)

for dir in "${CONFIG_DIRS[@]}"; do
    if [[ ! -d "$dir" ]]; then
        if mkdir -p "$dir"; then
            print_status "Created $dir"
        else
            print_error "Failed to create $dir"
            exit 1
        fi
    else
        print_status "$dir already exists"
    fi
done

# Check for .env file
echo -e "\n${BLUE}Checking environment configuration...${NC}"
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
        cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
        print_warning "Created .env from .env.example - please edit it with your API keys"
        print_warning "Required: TMDB_API_KEY, RADARR_API_KEY, JUSTWATCH_LIST_ID, OPENVPN_USERNAME, OPENVPN_PASSWORD"
    else
        print_error ".env.example not found"
        exit 1
    fi
else
    print_status ".env file exists"
fi

# Setup Python virtual environment
echo -e "\n${BLUE}Setting up Python environment...${NC}"
if [[ ! -d "$VENV_PATH" ]]; then
    if python3 -m venv "$VENV_PATH"; then
        print_status "Created Python virtual environment"
    else
        print_error "Failed to create virtual environment"
        exit 1
    fi
else
    print_status "Virtual environment already exists"
fi

# Install Python requirements
if [[ -f "$SCRIPT_DIR/requirements.txt" ]]; then
    if source "$VENV_PATH/bin/activate" && pip install -r "$SCRIPT_DIR/requirements.txt"; then
        print_status "Installed Python requirements"
    else
        print_error "Failed to install Python requirements"
        exit 1
    fi
else
    print_warning "requirements.txt not found"
fi

# Make script executable
if [[ -f "$SCRIPT_DIR/scripts/import_justwatch.py" ]]; then
    chmod +x "$SCRIPT_DIR/scripts/import_justwatch.py"
    print_status "Made import_justwatch.py executable"
fi

# Setup crontab
echo -e "\n${BLUE}Setting up crontab...${NC}"
CRON_JOB="0 */12 * * * $VENV_PATH/bin/python $SCRIPT_DIR/scripts/import_justwatch.py >> $CONFIG_ROOT/scripts/import_justwatch.log 2>&1"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "import_justwatch.py"; then
    print_status "Crontab entry already exists"
else
    # Add cron job
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    if [[ $? -eq 0 ]]; then
        print_status "Added crontab entry (runs every 12 hours)"
    else
        print_error "Failed to add crontab entry"
        exit 1
    fi
fi

# Check Docker and Docker Compose
echo -e "\n${BLUE}Checking Docker installation...${NC}"
if command -v docker &> /dev/null; then
    print_status "Docker is installed"
    if docker info &> /dev/null; then
        print_status "Docker daemon is running"
    else
        print_warning "Docker daemon is not running - start it with: sudo systemctl start docker"
    fi
else
    print_error "Docker is not installed"
    exit 1
fi

if command -v docker-compose &> /dev/null || docker compose version &> /dev/null; then
    print_status "Docker Compose is available"
else
    print_error "Docker Compose is not installed"
    exit 1
fi

# Final instructions
echo -e "\n${GREEN}🎉 Setup completed successfully!${NC}"
echo -e "\n${BLUE}Next steps:${NC}"
echo "1. Edit .env file with your API keys and credentials"
echo "2. Get your Plex claim token from: https://account.plex.tv/en/claim"
echo "3. Start the services: cd docker && docker-compose up -d"
echo "4. Configure your services:"
echo "   - Radarr: http://localhost:7878"
echo "   - Sonarr: http://localhost:8989" 
echo "   - Prowlarr: http://localhost:9696"
echo "   - Transmission: http://localhost:9091"
echo "   - Plex: http://localhost:32400/web"
echo ""
echo -e "${YELLOW}Important:${NC} Make sure to configure Radarr/Sonarr to use 'transmission:9091' as download client"
echo -e "${YELLOW}Note:${NC} JustWatch import will run automatically every 12 hours via cron"

# Show current crontab
echo -e "\n${BLUE}Current crontab entries:${NC}"
crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$" || echo "No crontab entries found"
