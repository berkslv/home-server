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

# Validate storage directory
validate_storage_directory() {
    local dir_path="$1"
    
    print_info "Validating storage directory: $dir_path" >&2
    
    # Create directory if it doesn't exist
    if [ ! -d "$dir_path" ]; then
        print_info "Creating directory: $dir_path" >&2
        mkdir -p "$dir_path"
    fi
    
    # Check if writable
    if ! touch "$dir_path/.write_test" 2>/dev/null; then
        print_error "$dir_path is not writable" >&2
        return 1
    fi
    rm -f "$dir_path/.write_test"
    
    # Check available space (at least 20GB)
    local available=$(df -BG "$dir_path" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$available" -lt 20 ]; then
        print_warning "Less than 20GB available on $dir_path (${available}GB free)" >&2
        if ! prompt_continue "Continue anyway?"; then
            return 1
        fi
    else
        print_success "Sufficient space available: ${available}GB" >&2
    fi
    
    return 0
}

# Get storage path for data
get_storage_path() {
    local default_path="/var/lib/home-server"
    local storage_path
    
    print_header "Storage Configuration" >&2
    
    print_info "Data will be stored locally on your SSD" >&2
    echo "Recommended path: $default_path" >&2
    echo >&2
    
    if [ "$AUTO_YES" = true ]; then
        storage_path="$default_path"
        print_info "Using default path: $storage_path" >&2
    else
        read -p "Enter storage path [$default_path]: " storage_path
        storage_path=${storage_path:-$default_path}
    fi
    
    # Validate
    if ! validate_storage_directory "$storage_path"; then
        print_error "Storage directory validation failed" >&2
        exit 1
    fi
    
    # Only echo the path (to stdout for capture)
    echo "$storage_path"
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
    
    # Check if this is a fresh install or re-run
    local is_fresh_install=true
    if [ -f "$CONFIG_FILE" ] && [ -f "$SECRETS_DIR/db_password" ]; then
        is_fresh_install=false
        print_info "Existing installation detected"
    fi
    
    # Get storage path
    if [ "$is_fresh_install" = true ]; then
        STORAGE_PATH=$(get_storage_path)
    else
        # Read from existing config with error handling
        if STORAGE_PATH=$(jq -r '.storage_path // empty' "$CONFIG_FILE" 2>/dev/null) && [ -n "$STORAGE_PATH" ]; then
            print_info "Using existing storage path: $STORAGE_PATH"
        else
            print_warning "Could not read storage path from config, re-prompting"
            STORAGE_PATH=$(get_storage_path)
        fi
    fi
    
    # Tailscale Auth Key
    print_header "Tailscale Configuration"
    
    # Check if secret already exists
    if [ -f "$SECRETS_DIR/tailscale_auth_key" ] && [ "$is_fresh_install" = false ]; then
        print_info "Using existing Tailscale auth key"
        TAILSCALE_AUTH_KEY=$(cat "$SECRETS_DIR/tailscale_auth_key")
    else
        # Check if auth key provided via environment variable
        if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
            print_info "Using Tailscale Auth Key from environment variable"
        else
            echo "To get your Tailscale auth key:"
            echo "  1. Go to https://login.tailscale.com/admin/settings/keys"
            echo "  2. Click 'Generate auth key'"
            echo "  3. Optional: Enable 'Reusable' and set expiration"
            echo "  4. Copy the auth key (starts with tskey-auth-)"
            echo
            
            if [ "$AUTO_YES" = true ]; then
                print_error "Tailscale Auth Key required in non-interactive mode"
                print_info "Set TAILSCALE_AUTH_KEY environment variable or run without -y flag"
                exit 1
            fi
            
            read -sp "Enter Tailscale Auth Key: " TAILSCALE_AUTH_KEY
            echo
        fi
        
        if [ -z "$TAILSCALE_AUTH_KEY" ]; then
            print_error "Tailscale Auth Key is required"
            exit 1
        fi
    fi
    
    # Generate or reuse database password
    print_header "Generating Credentials"
    if [ -f "$SECRETS_DIR/db_password" ] && [ "$is_fresh_install" = false ]; then
        DB_PASSWORD=$(cat "$SECRETS_DIR/db_password")
        print_info "Using existing PostgreSQL password"
    else
        DB_PASSWORD=$(generate_password)
        print_success "PostgreSQL password generated"
    fi
    
    # Store secrets
    print_info "Storing credentials securely..."
    store_secret "tailscale_auth_key" "$TAILSCALE_AUTH_KEY"
    store_secret "db_password" "$DB_PASSWORD"
    
    # Save configuration
    mkdir -p "$CONFIG_DIR"
    local deployment_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    cat > "$CONFIG_FILE" <<EOF
{
  "storage_path": "$STORAGE_PATH",
  "deployment_date": "$deployment_date",
  "version": "1.0",
  "services": {
    "immich": {
      "enabled": true,
      "ml_enabled": true
    },
    "portainer": {
      "enabled": true
    },
    "glances": {
      "enabled": true
    },
    "tailscale": {
      "enabled": true
    }
  }
}
EOF
    chmod 644 "$CONFIG_FILE"
    print_success "Configuration saved to $CONFIG_FILE"
}

# Setup storage directories
setup_directories() {
    print_header "Setting Up Directories"
    
    print_info "Creating directory structure..."
    
    # Immich directories
    mkdir -p "$STORAGE_PATH/immich/upload"
    mkdir -p "$STORAGE_PATH/immich/postgres"
    mkdir -p "$STORAGE_PATH/backups"
    
    # Set permissions
    # Immich upload directory (user 1000)
    chown -R 1000:1000 "$STORAGE_PATH/immich/upload"
    chmod -R 755 "$STORAGE_PATH/immich/upload"
    
    # PostgreSQL directory (user 999 - postgres user in container)
    chown -R 999:999 "$STORAGE_PATH/immich/postgres"
    chmod -R 700 "$STORAGE_PATH/immich/postgres"
    
    # Backups directory
    chown -R 1000:1000 "$STORAGE_PATH/backups"
    chmod -R 755 "$STORAGE_PATH/backups"
    
    print_success "Directory structure created"
    echo "  - $STORAGE_PATH/immich/upload"
    echo "  - $STORAGE_PATH/immich/postgres"
    echo "  - $STORAGE_PATH/backups"
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
            # Download from GitHub
            print_info "Downloading from GitHub repository..."
            if curl -fsSL "https://raw.githubusercontent.com/berkslv/home-server/main/docker-compose.yml" -o "$COMPOSE_FILE"; then
                print_success "Downloaded docker-compose.yml from GitHub"
            else
                print_error "Failed to download docker-compose.yml"
                print_info "Please check your internet connection or manually place docker-compose.yml at $COMPOSE_FILE"
                exit 1
            fi
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
    EXTERNAL_DRIVE="$STORAGE_PATH" docker compose pull
    
    print_info "Starting services..."
    EXTERNAL_DRIVE="$STORAGE_PATH" docker compose up -d
    
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
    echo -e "${BLUE}Tailscale${NC}"
    echo "  Access via Tailscale network at: http://home-server:2283 (Immich)"
    echo "  View devices: https://login.tailscale.com/admin/machines"
    echo
    echo "========================================"
    echo "  Generated Credentials"
    echo "========================================"
    echo
    echo -e "${YELLOW}PostgreSQL Database Password:${NC}"
    echo "  $DB_PASSWORD"
    echo
    echo -e "${YELLOW}Tailscale Auth Key:${NC}"
    echo "  Stored securely (not displayed for security)"
    echo
    echo -e "${YELLOW}IMPORTANT: Save these credentials securely!${NC}"
    echo "Credentials are stored in: $SECRETS_DIR"
    echo
    echo "========================================"
    echo "  Storage Locations"
    echo "========================================"
    echo
    echo "  Photos: $STORAGE_PATH/immich/upload"
    echo "  Database: $STORAGE_PATH/immich/postgres"
    echo "  Backups: $STORAGE_PATH/backups"
    echo
    echo "======================================="
    echo "  Useful Commands"
    echo "======================================="
    echo
    echo "  View logs:        cd $CONFIG_DIR && docker compose logs -f"
    echo "  Restart services: cd $CONFIG_DIR && EXTERNAL_DRIVE=$STORAGE_PATH docker compose restart"
    echo "  Stop services:    cd $CONFIG_DIR && EXTERNAL_DRIVE=$STORAGE_PATH docker compose down"
    echo "  Update services:  cd $CONFIG_DIR && EXTERNAL_DRIVE=$STORAGE_PATH docker compose pull && docker compose up -d"
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
