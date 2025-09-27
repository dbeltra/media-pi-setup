#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/docker"

print_status() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

show_help() {
    echo -e "${BLUE}Media Server Management Script${NC}"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  start     Start all services"
    echo "  stop      Stop all services"
    echo "  restart   Restart all services"
    echo "  status    Show service status"
    echo "  logs      Show logs for all services"
    echo "  logs [service]  Show logs for specific service"
    echo "  update    Pull latest images and restart"
    echo "  cleanup   Remove unused Docker resources"
    echo "  test-justwatch  Test the JustWatch import script"
    echo "  help      Show this help message"
    echo ""
    echo "Services: transmission, radarr, sonarr, prowlarr, plex"
}

check_docker_dir() {
    if [[ ! -d "$DOCKER_DIR" ]]; then
        print_error "Docker directory not found: $DOCKER_DIR"
        exit 1
    fi
    if [[ ! -f "$DOCKER_DIR/docker-compose.yaml" ]]; then
        print_error "docker-compose.yaml not found in $DOCKER_DIR"
        exit 1
    fi
}

case "$1" in
    start)
        check_docker_dir
        print_info "Starting media server services..."
        cd "$DOCKER_DIR" && docker-compose up -d
        if [[ $? -eq 0 ]]; then
            print_status "All services started"
            echo ""
            echo "Services available at:"
            echo "  Radarr:      http://localhost:7878"
            echo "  Sonarr:      http://localhost:8989"
            echo "  Prowlarr:    http://localhost:9696"
            echo "  Transmission: http://localhost:9091"
            echo "  Plex:        http://localhost:32400/web"
        else
            print_error "Failed to start services"
            exit 1
        fi
        ;;
    stop)
        check_docker_dir
        print_info "Stopping media server services..."
        cd "$DOCKER_DIR" && docker-compose down
        print_status "All services stopped"
        ;;
    restart)
        check_docker_dir
        print_info "Restarting media server services..."
        cd "$DOCKER_DIR" && docker-compose restart
        print_status "All services restarted"
        ;;
    status)
        check_docker_dir
        print_info "Service status:"
        cd "$DOCKER_DIR" && docker-compose ps
        ;;
    logs)
        check_docker_dir
        if [[ -n "$2" ]]; then
            print_info "Showing logs for $2..."
            cd "$DOCKER_DIR" && docker-compose logs -f "$2"
        else
            print_info "Showing logs for all services..."
            cd "$DOCKER_DIR" && docker-compose logs -f
        fi
        ;;
    update)
        check_docker_dir
        print_info "Pulling latest images..."
        cd "$DOCKER_DIR" && docker-compose pull
        print_info "Restarting services with new images..."
        cd "$DOCKER_DIR" && docker-compose up -d
        print_status "Update completed"
        ;;
    cleanup)
        print_info "Cleaning up unused Docker resources..."
        docker system prune -f
        docker volume prune -f
        print_status "Cleanup completed"
        ;;
    test-justwatch)
        SCRIPT_DIR="$(dirname "$0")"
        if [[ -f "$SCRIPT_DIR/.venv/bin/python" && -f "$SCRIPT_DIR/scripts/import_justwatch.py" ]]; then
            print_info "Testing JustWatch import script..."
            "$SCRIPT_DIR/.venv/bin/python" "$SCRIPT_DIR/scripts/import_justwatch.py"
        else
            print_error "JustWatch script or virtual environment not found"
            print_error "Run ./setup.sh first"
            exit 1
        fi
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        show_help
        ;;
    *)
        print_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
