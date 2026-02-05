#!/bin/bash
#
# Home Server Deployment Script
# Deploys Immich, Portainer, Glances, and Cloudflare Tunnel on Raspberry Pi
# Usage: wget -qO- https://raw.githubusercontent.com/berkslv/home-server/main/deploy.sh | bash
#

set -euo pipefail

# Default options
AUTO_YES=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CONFIG_DIR="/opt/home-server"
CONFIG_FILE="$CONFIG_DIR/config.json"
SECRETS_DIR="$CONFIG_DIR/secrets"
COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}========================================${NC}\n"
}

# Prompt with auto-yes support
prompt_continue() {
    local message="${1:-Continue anyway?}"
    if [ "$AUTO_YES" = true ]; then
        print_info "Auto-accepting: $message"
        return 0
    fi
    read -p "$message [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    fi
    return 1
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Install required packages
install_requirements() {
    local packages_to_install=()
    
    print_info "Checking required packages..."
    
    # Check git
    if ! command -v git &> /dev/null; then
        print_warning "git is not installed"
        packages_to_install+=("git")
    else
        print_success "git is installed: $(git --version | head -n1)"
    fi
    
    # Check curl
    if ! command -v curl &> /dev/null; then
        print_warning "curl is not installed"
        packages_to_install+=("curl")
    else
        print_success "curl is installed"
    fi
    
    # Check wget
    if ! command -v wget &> /dev/null; then
        print_warning "wget is not installed"
        packages_to_install+=("wget")
    else
        print_success "wget is installed"
    fi
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        print_warning "jq is not installed"
        packages_to_install+=("jq")
    else
        print_success "jq is installed"
    fi
    
    # Check openssl
    if ! command -v openssl &> /dev/null; then
        print_warning "openssl is not installed"
        packages_to_install+=("openssl")
    else
        print_success "openssl is installed"
    fi
    
    # Install missing packages
    if [ ${#packages_to_install[@]} -gt 0 ]; then
        print_info "Installing missing packages: ${packages_to_install[*]}"
        apt-get update -qq
        apt-get install -y "${packages_to_install[@]}"
        print_success "All required packages installed"
    else
        print_success "All required packages are already installed"
    fi
}

# Install Docker if not present
install_docker() {
    print_info "Checking Docker installation..."
    
    if ! command -v docker &> /dev/null; then
        print_warning "Docker is not installed. Installing Docker..."
        
        # Install Docker using official script
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm /tmp/get-docker.sh
        
        # Add current user to docker group (if not root)
        if [ -n "${SUDO_USER:-}" ]; then
            usermod -aG docker "$SUDO_USER"
            print_info "Added $SUDO_USER to docker group"
        fi
        
        # Start Docker service
        systemctl enable docker
        systemctl start docker
        
        print_success "Docker installed successfully: $(docker --version)"
    else
        print_success "Docker is already installed: $(docker --version)"
    fi
    
    # Check Docker Compose
    if ! docker compose version &> /dev/null; then
        print_error "Docker Compose plugin is not available"
        print_info "Installing Docker Compose plugin..."
        
        # Docker Compose should be installed with Docker, try updating
        apt-get update -qq
        apt-get install -y docker-compose-plugin
        
        if ! docker compose version &> /dev/null; then
            print_error "Failed to install Docker Compose plugin"
            exit 1
        fi
    fi
    
    print_success "Docker Compose is available: $(docker compose version --short)"
}

# Pre-flight checks
preflight_checks() {
    print_header "Running Pre-flight Checks"
    
    # Install required packages
    install_requirements
    
    # Install Docker if needed
    install_docker
    
    # Check architecture
    ARCH=$(uname -m)
    if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
        print_warning "This script is optimized for ARM64 architecture, detected: $ARCH"
        if ! prompt_continue "Continue anyway?"; then
            exit 1
        fi
    else
        print_success "ARM64 architecture detected: $ARCH"
    fi
    
    # Check available memory
    TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_MEM" -lt 4 ]; then
        print_warning "Less than 4GB RAM detected (${TOTAL_MEM}GB). Immich may run slowly."
    else
        print_success "Sufficient memory available: ${TOTAL_MEM}GB"
    fi
}

# Validate external drive
validate_external_drive() {
    local drive_path="$1"
    
    print_info "Validating external drive: $drive_path"
    
    # Check if path exists
    if [ ! -d "$drive_path" ]; then
        print_error "Path does not exist: $drive_path"
        return 1
    fi
    
    # Check if mounted
    if ! mountpoint -q "$drive_path" 2>/dev/null; then
        print_error "$drive_path is not a mount point"
        print_info "Make sure your external SSD is mounted before running this script"
        return 1
    fi
    
    # Check if writable
    if ! touch "$drive_path/.write_test" 2>/dev/null; then
        print_error "$drive_path is not writable"
        return 1
    fi
    rm -f "$drive_path/.write_test"
    
    # Check available space (at least 20GB)
    local available=$(df -BG "$drive_path" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$available" -lt 20 ]; then
        print_warning "Less than 20GB available on $drive_path (${available}GB free)"
        if ! prompt_continue "Continue anyway?"; then
            return 1
        fi
    else
        print_success "Sufficient space available: ${available}GB"
    fi
    
    return 0
}

# Suggest and prompt for external drive path
get_external_drive_path() {
    print_header "External Storage Configuration"
    
    print_info "Detecting mounted drives..."
    echo
    echo "Suggested mount points:"
    
    # List potential mount points
    local suggestions=()
    local current_user="${SUDO_USER:-root}"
    for mount in /mnt/* /media/*/* /media/$current_user/*; do
        if mountpoint -q "$mount" 2>/dev/null; then
            local size=$(df -BG "$mount" | awk 'NR==2 {print $2}' | sed 's/G//')
            local avail=$(df -BG "$mount" | awk 'NR==2 {print $4}' | sed 's/G//')
            echo "  - $mount (Size: ${size}GB, Available: ${avail}GB)"
            suggestions+=("$mount")
        fi
    done
    
    if [ ${#suggestions[@]} -eq 0 ]; then
        print_warning "No external drives detected"
        echo "Common mount points: /mnt/external-ssd, /media/usb0, /mnt/usb"
    fi
    
    echo
    local default_path="/mnt/external-ssd"
    
    if [ "$AUTO_YES" = true ]; then
        external_drive="$default_path"
        print_info "Auto-accepting default path: $external_drive"
    else
        read -p "Enter external SSD mount path [$default_path]: " external_drive
        external_drive=${external_drive:-$default_path}
    fi
    
    # Validate
    if ! validate_external_drive "$external_drive"; then
        print_error "External drive validation failed"
        exit 1
    fi
    
    echo "$external_drive"
}

# Generate random password
generate_password() {
    openssl rand -base64 24 | tr -d "=+/" | cut -c1-24
}

# Store secret securely
store_secret() {
    local secret_name="$1"
    local secret_value="$2"
    
    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"
    
    echo -n "$secret_value" > "$SECRETS_DIR/$secret_name"
    chmod 600 "$SECRETS_DIR/$secret_name"
    
    print_success "Stored secret: $secret_name"
}

# Interactive configuration
configure_deployment() {
    print_header "Deployment Configuration"
    
    # Get external drive path
    EXTERNAL_DRIVE=$(get_external_drive_path)
    
    # Cloudflare Tunnel Token
    print_header "Cloudflare Tunnel Configuration"
    
    # Check if token provided via environment variable
    if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
        print_info "Using Cloudflare Tunnel Token from environment variable"
    else
        echo "To get your tunnel token:"
        echo "  1. Go to https://one.dash.cloudflare.com/"
        echo "  2. Navigate to Networks > Tunnels"
        echo "  3. Create a new tunnel or select existing one"
        echo "  4. Copy the tunnel token"
        echo
        
        if [ "$AUTO_YES" = true ]; then
            print_error "Cloudflare Tunnel Token required in non-interactive mode"
            print_info "Set CF_TUNNEL_TOKEN environment variable or run without -y flag"
            exit 1
        fi
        
        read -sp "Enter Cloudflare Tunnel Token: " CF_TUNNEL_TOKEN
        echo
    fi
    
    if [ -z "$CF_TUNNEL_TOKEN" ]; then
        print_error "Cloudflare Tunnel Token is required"
        exit 1
    fi
    
    # Generate database password
    print_header "Generating Credentials"
    DB_PASSWORD=$(generate_password)
    print_success "PostgreSQL password generated"
    
    # Store secrets
    print_info "Storing credentials securely..."
    store_secret "cf_tunnel_token" "$CF_TUNNEL_TOKEN"
    store_secret "db_password" "$DB_PASSWORD"
    
    # Save configuration
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
{
  "external_drive": "$EXTERNAL_DRIVE",
  "deployment_date": "$(date -Iseconds)",
  "version": "1.0",
  "services": {
    "immich": {
      "enabled": true,
      "ml_enabled": false
    },
    "portainer": {
      "enabled": true
    },
    "glances": {
      "enabled": true
    },
    "cloudflared": {
      "enabled": true
    }
  }
}
EOF
    chmod 644 "$CONFIG_FILE"
    print_success "Configuration saved to $CONFIG_FILE"
}

# Setup external drive directories
setup_directories() {
    print_header "Setting Up Directories"
    
    print_info "Creating directory structure on external drive..."
    
    # Immich directories
    mkdir -p "$EXTERNAL_DRIVE/immich/upload"
    mkdir -p "$EXTERNAL_DRIVE/immich/postgres"
    mkdir -p "$EXTERNAL_DRIVE/backups"
    
    # Set permissions
    # Immich upload directory (user 1000)
    chown -R 1000:1000 "$EXTERNAL_DRIVE/immich/upload"
    chmod -R 755 "$EXTERNAL_DRIVE/immich/upload"
    
    # PostgreSQL directory (user 999 - postgres user in container)
    chown -R 999:999 "$EXTERNAL_DRIVE/immich/postgres"
    chmod -R 700 "$EXTERNAL_DRIVE/immich/postgres"
    
    # Backups directory
    chown -R 1000:1000 "$EXTERNAL_DRIVE/backups"
    chmod -R 755 "$EXTERNAL_DRIVE/backups"
    
    print_success "Directory structure created"
    echo "  - $EXTERNAL_DRIVE/immich/upload"
    echo "  - $EXTERNAL_DRIVE/immich/postgres"
    echo "  - $EXTERNAL_DRIVE/backups"
}

# Download docker-compose.yml if not present
download_compose_file() {
    print_header "Setting Up Docker Compose"
    
    if [ ! -f "$COMPOSE_FILE" ]; then
        print_info "Downloading docker-compose.yml..."
        
        # Check if we're running from a local directory with docker-compose.yml
        if [ -f "docker-compose.yml" ]; then
            cp docker-compose.yml "$COMPOSE_FILE"
            print_success "Copied docker-compose.yml from current directory"
        else
            print_error "docker-compose.yml not found"
            print_info "Please ensure docker-compose.yml is in the current directory or at $COMPOSE_FILE"
            exit 1
        fi
    else
        print_success "Using existing docker-compose.yml"
    fi
    
    chmod 644 "$COMPOSE_FILE"
}

# Deploy services
deploy_services() {
    print_header "Deploying Services"
    
    print_info "Pulling Docker images (this may take a while)..."
    cd "$CONFIG_DIR"
    EXTERNAL_DRIVE="$EXTERNAL_DRIVE" docker compose pull
    
    print_info "Starting services..."
    EXTERNAL_DRIVE="$EXTERNAL_DRIVE" docker compose up -d
    
    print_success "All services started"
}

# Display completion summary
show_summary() {
    print_header "Deployment Complete!"
    
    # Get server IP
    SERVER_IP=$(hostname -I | awk '{print $1}')
    
    echo -e "${GREEN}Your home server is ready!${NC}"
    echo
    echo "========================================"
    echo "  Service Access Information"
    echo "========================================"
    echo
    echo -e "${BLUE}Immich (Photo Management)${NC}"
    echo "  URL: http://$SERVER_IP:2283"
    echo "  Note: Create your admin account on first login"
    echo
    echo -e "${BLUE}Portainer (Docker Management)${NC}"
    echo "  URL: https://$SERVER_IP:9443"
    echo "  Note: Set admin password on first login"
    echo
    echo -e "${BLUE}Glances (System Monitoring)${NC}"
    echo "  URL: http://$SERVER_IP:61208"
    echo
    echo "========================================"
    echo "  Generated Credentials"
    echo "========================================"
    echo
    echo -e "${YELLOW}PostgreSQL Database Password:${NC}"
    echo "  $DB_PASSWORD"
    echo
    echo -e "${YELLOW}IMPORTANT: Save these credentials securely!${NC}"
    echo "Credentials are stored in: $SECRETS_DIR"
    echo
    echo "========================================"
    echo "  Storage Locations"
    echo "========================================"
    echo
    echo "  Photos: $EXTERNAL_DRIVE/immich/upload"
    echo "  Database: $EXTERNAL_DRIVE/immich/postgres"
    echo "  Backups: $EXTERNAL_DRIVE/backups"
    echo
    echo "========================================"
    echo "  Useful Commands"
    echo "========================================"
    echo
    echo "  View logs:        cd $CONFIG_DIR && docker compose logs -f"
    echo "  Restart services: cd $CONFIG_DIR && EXTERNAL_DRIVE=$EXTERNAL_DRIVE docker compose restart"
    echo "  Stop services:    cd $CONFIG_DIR && EXTERNAL_DRIVE=$EXTERNAL_DRIVE docker compose down"
    echo "  Update services:  cd $CONFIG_DIR && EXTERNAL_DRIVE=$EXTERNAL_DRIVE docker compose pull && docker compose up -d"
    echo "  Run backup:       /opt/home-server/scripts/backup.sh"
    echo
    echo "Configuration: $CONFIG_FILE"
    echo "Docker Compose: $COMPOSE_FILE"
    echo
    print_success "Setup complete! Enjoy your home server!"
}

# Main execution
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -y|--yes)
                AUTO_YES=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS]"
                echo
                echo "Options:"
                echo "  -y, --yes    Auto-accept all prompts (non-interactive mode)"
                echo "  -h, --help   Show this help message"
                echo
                echo "Example:"
                echo "  $0 -y        # Run in non-interactive mode"
                echo "  wget -qO- https://raw.githubusercontent.com/berkslv/home-server/main/deploy.sh | bash -s -- -y"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done
    
    print_header "Raspberry Pi Home Server Deployment"
    
    check_root
    preflight_checks
    configure_deployment
    setup_directories
    download_compose_file
    deploy_services
    show_summary
}

# Run main function
main "$@"
