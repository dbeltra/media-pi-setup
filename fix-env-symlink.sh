#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

echo -e "${BLUE}🔗 Fix .env Symlink${NC}"
echo "=================="

# Remove any existing .env file in docker directory
if [[ -f "docker/.env" ]]; then
    rm -f "docker/.env"
    print_status "Removed existing docker/.env file"
fi

# Create symlink
if [[ -f ".env" ]]; then
    ln -s "../.env" "docker/.env"
    print_status "Created symlink: docker/.env -> ../.env"
    print_info "Now you only need to edit the root .env file"
else
    echo "No .env file found in root directory"
    echo "Please create one first or run ./setup.sh"
fi

# Verify symlink
if [[ -L "docker/.env" ]]; then
    print_status "Symlink verified successfully"
    ls -la docker/.env
else
    echo "Failed to create symlink"
fi
