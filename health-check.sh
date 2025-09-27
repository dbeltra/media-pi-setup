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

echo -e "${BLUE}🏥 Media Server Health Check${NC}"
echo "================================"

# Check if services are running
SERVICES=("transmission" "radarr" "sonarr" "prowlarr" "plex")
PORTS=("9091" "7878" "8989" "9696" "32400")

echo -e "\n${BLUE}Checking Docker containers...${NC}"
for service in "${SERVICES[@]}"; do
    if docker ps --format "table {{.Names}}" | grep -q "^$service$"; then
        print_status "$service container is running"
    else
        print_error "$service container is not running"
    fi
done

echo -e "\n${BLUE}Checking service connectivity...${NC}"
for i in "${!SERVICES[@]}"; do
    service="${SERVICES[$i]}"
    port="${PORTS[$i]}"
    
    if curl -s --connect-timeout 5 "http://localhost:$port" > /dev/null; then
        print_status "$service is responding on port $port"
    else
        print_error "$service is not responding on port $port"
    fi
done

# Check disk space
echo -e "\n${BLUE}Checking disk space...${NC}"
EXTERNAL_DRIVE="/mnt/media-drive"
if mountpoint -q "$EXTERNAL_DRIVE" 2>/dev/null; then
    USAGE=$(df -h "$EXTERNAL_DRIVE" | awk 'NR==2 {print $5}' | sed 's/%//')
    AVAILABLE=$(df -h "$EXTERNAL_DRIVE" | awk 'NR==2 {print $4}')
    if [[ $USAGE -gt 90 ]]; then
        print_error "External drive usage is ${USAGE}% ($AVAILABLE available) - consider cleaning up"
    elif [[ $USAGE -gt 80 ]]; then
        print_warning "External drive usage is ${USAGE}% ($AVAILABLE available) - monitor closely"
    else
        print_status "External drive usage is ${USAGE}% ($AVAILABLE available) - healthy"
    fi
else
    print_error "External drive not mounted at $EXTERNAL_DRIVE"
fi

# Check root filesystem (should stay low)
ROOT_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
if [[ $ROOT_USAGE -gt 80 ]]; then
    print_warning "Root filesystem usage is ${ROOT_USAGE}% - may need cleanup"
else
    print_status "Root filesystem usage is ${ROOT_USAGE}% - healthy"
fi

# Check VPN status (if transmission is running)
echo -e "\n${BLUE}Checking VPN status...${NC}"
if docker ps --format "table {{.Names}}" | grep -q "^transmission$"; then
    VPN_STATUS=$(docker exec transmission curl -s ifconfig.me 2>/dev/null || echo "failed")
    if [[ "$VPN_STATUS" != "failed" ]]; then
        print_status "VPN is active - External IP: $VPN_STATUS"
    else
        print_warning "Could not verify VPN status"
    fi
else
    print_warning "Transmission not running - cannot check VPN"
fi

# Check crontab
echo -e "\n${BLUE}Checking scheduled tasks...${NC}"
if crontab -l 2>/dev/null | grep -q "import_justwatch.py"; then
    print_status "JustWatch import cron job is configured"
else
    print_warning "JustWatch import cron job not found"
fi

# Check log files
echo -e "\n${BLUE}Checking log files...${NC}"
LOG_DIR="/mnt/media-drive/media-server-config/scripts"
if [[ -f "$LOG_DIR/import_justwatch.log" ]]; then
    LOG_SIZE=$(du -h "$LOG_DIR/import_justwatch.log" | cut -f1)
    print_status "JustWatch log exists ($LOG_SIZE)"
    
    # Show last few lines
    echo -e "\n${BLUE}Recent JustWatch activity:${NC}"
    tail -5 "$LOG_DIR/import_justwatch.log" 2>/dev/null || echo "No recent activity"
else
    print_warning "JustWatch log file not found"
fi

echo -e "\n${GREEN}Health check completed!${NC}"
