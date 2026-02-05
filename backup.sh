#!/bin/bash
#
# Home Server Backup Script
# Backs up PostgreSQL database, Immich data, and configurations
# Usage: /opt/home-server/scripts/backup.sh
#

set -euo pipefail

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

# Retention policy
DAILY_RETENTION=7
WEEKLY_RETENTION=4
MONTHLY_RETENTION=3

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

# Load configuration
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        print_info "Please run the deployment script first"
        exit 1
    fi
    
    EXTERNAL_DRIVE=$(jq -r '.external_drive' "$CONFIG_FILE")
    
    if [ -z "$EXTERNAL_DRIVE" ] || [ "$EXTERNAL_DRIVE" = "null" ]; then
        print_error "External drive path not found in configuration"
        exit 1
    fi
    
    BACKUP_BASE="$EXTERNAL_DRIVE/backups"
}

# Create backup directory
create_backup_dir() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="$BACKUP_BASE/$timestamp"
    
    mkdir -p "$BACKUP_DIR"
    chmod 755 "$BACKUP_DIR"
    
    print_success "Created backup directory: $BACKUP_DIR"
}

# Backup PostgreSQL database
backup_database() {
    print_header "Backing Up PostgreSQL Database"
    
    print_info "Dumping Immich database..."
    
    if ! docker exec immich-postgres pg_isready -U postgres > /dev/null 2>&1; then
        print_error "PostgreSQL is not running or not accessible"
        return 1
    fi
    
    docker exec immich-postgres pg_dump -U postgres immich | \
        gzip -9 > "$BACKUP_DIR/immich_db.sql.gz"
    
    local db_size=$(du -h "$BACKUP_DIR/immich_db.sql.gz" | cut -f1)
    print_success "Database backed up: immich_db.sql.gz ($db_size)"
}

# Backup Immich upload directory
backup_immich_uploads() {
    print_header "Backing Up Immich Uploads"
    
    local upload_dir="$EXTERNAL_DRIVE/immich/upload"
    
    if [ ! -d "$upload_dir" ]; then
        print_warning "Upload directory not found: $upload_dir"
        return 0
    fi
    
    local upload_size=$(du -sh "$upload_dir" | cut -f1)
    print_info "Upload directory size: $upload_size"
    print_info "Creating compressed archive (this may take a while)..."
    
    tar -czf "$BACKUP_DIR/immich_upload.tar.gz" \
        -C "$EXTERNAL_DRIVE/immich" upload 2>/dev/null || {
        print_warning "Some files may have been skipped during backup"
    }
    
    local archive_size=$(du -h "$BACKUP_DIR/immich_upload.tar.gz" | cut -f1)
    print_success "Uploads backed up: immich_upload.tar.gz ($archive_size)"
}

# Backup Docker volumes
backup_docker_volumes() {
    print_header "Backing Up Docker Volumes"
    
    print_info "Backing up Portainer data..."
    
    if docker volume inspect portainer_data > /dev/null 2>&1; then
        docker run --rm \
            -v portainer_data:/data \
            -v "$BACKUP_DIR:/backup" \
            alpine tar -czf /backup/portainer_data.tar.gz -C /data .
        
        print_success "Portainer data backed up"
    else
        print_warning "Portainer volume not found"
    fi
}

# Backup configurations
backup_configurations() {
    print_header "Backing Up Configurations"
    
    print_info "Backing up configuration files..."
    
    # Config file
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$BACKUP_DIR/config.json"
        print_success "Copied config.json"
    fi
    
    # Docker compose file
    if [ -f "$COMPOSE_FILE" ]; then
        cp "$COMPOSE_FILE" "$BACKUP_DIR/docker-compose.yml"
        print_success "Copied docker-compose.yml"
    fi
    
    # Backup secrets (encrypted)
    if [ -d "$SECRETS_DIR" ]; then
        print_info "Encrypting and backing up secrets..."
        
        # Prompt for encryption password
        read -sp "Enter encryption password for secrets backup: " ENCRYPT_PASS
        echo
        
        tar -czf - -C "$CONFIG_DIR" secrets | \
            openssl enc -aes-256-cbc -pbkdf2 -pass pass:"$ENCRYPT_PASS" \
            -out "$BACKUP_DIR/secrets.tar.gz.enc"
        
        print_success "Secrets backed up (encrypted)"
    fi
    
    # Cloudflare credentials (if exists)
    if [ -d "/root/.cloudflared" ]; then
        cp -r /root/.cloudflared "$BACKUP_DIR/cloudflared" 2>/dev/null || true
        print_success "Cloudflare credentials backed up"
    fi
}

# Create backup manifest
create_manifest() {
    print_info "Creating backup manifest..."
    
    cat > "$BACKUP_DIR/manifest.txt" <<EOF
Backup Created: $(date)
Hostname: $(hostname)
External Drive: $EXTERNAL_DRIVE

Contents:
$(ls -lh "$BACKUP_DIR" | tail -n +2)

Docker Containers:
$(docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || echo "N/A")

Disk Usage:
$(df -h "$EXTERNAL_DRIVE" | tail -n 1)
EOF
    
    print_success "Manifest created"
}

# Rotate old backups
rotate_backups() {
    print_header "Rotating Old Backups"
    
    local backup_count=$(find "$BACKUP_BASE" -maxdepth 1 -type d -name "20*" | wc -l)
    print_info "Total backups: $backup_count"
    
    # Mark weekly backups (created on Sunday)
    find "$BACKUP_BASE" -maxdepth 1 -type d -name "20*" | while read dir; do
        local dir_name=$(basename "$dir")
        local dir_date=$(echo "$dir_name" | cut -d_ -f1)
        
        # Check if Sunday (day of week = 0)
        if [ "$(date -d "$dir_date" +%u)" -eq 7 ] 2>/dev/null; then
            touch "$dir/.weekly"
        fi
        
        # Check if first day of month
        if [ "$(date -d "$dir_date" +%d)" -eq 1 ] 2>/dev/null; then
            touch "$dir/.monthly"
        fi
    done
    
    # Remove old daily backups (keep last N, preserve weekly/monthly)
    local daily_backups=$(find "$BACKUP_BASE" -maxdepth 1 -type d -name "20*" \
        ! -name ".*" \
        ! -exec test -f {}/.weekly \; \
        ! -exec test -f {}/.monthly \; \
        -print | sort -r)
    
    local daily_count=0
    echo "$daily_backups" | while read backup; do
        daily_count=$((daily_count + 1))
        if [ $daily_count -gt $DAILY_RETENTION ]; then
            print_info "Removing old daily backup: $(basename $backup)"
            rm -rf "$backup"
        fi
    done
    
    # Remove old weekly backups
    local weekly_backups=$(find "$BACKUP_BASE" -maxdepth 1 -type d -name "20*" \
        -exec test -f {}/.weekly \; -print | sort -r)
    
    local weekly_count=0
    echo "$weekly_backups" | while read backup; do
        weekly_count=$((weekly_count + 1))
        if [ $weekly_count -gt $WEEKLY_RETENTION ]; then
            if [ ! -f "$backup/.monthly" ]; then
                print_info "Removing old weekly backup: $(basename $backup)"
                rm -rf "$backup"
            fi
        fi
    done
    
    # Remove old monthly backups
    local monthly_backups=$(find "$BACKUP_BASE" -maxdepth 1 -type d -name "20*" \
        -exec test -f {}/.monthly \; -print | sort -r)
    
    local monthly_count=0
    echo "$monthly_backups" | while read backup; do
        monthly_count=$((monthly_count + 1))
        if [ $monthly_count -gt $MONTHLY_RETENTION ]; then
            print_info "Removing old monthly backup: $(basename $backup)"
            rm -rf "$backup"
        fi
    done
    
    print_success "Backup rotation complete"
}

# Restore function
restore_backup() {
    local backup_dir="$1"
    
    if [ ! -d "$backup_dir" ]; then
        print_error "Backup directory not found: $backup_dir"
        exit 1
    fi
    
    print_header "Restoring from Backup"
    print_warning "This will OVERWRITE existing data!"
    read -p "Are you sure you want to restore from $backup_dir? [y/N]: " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Restore cancelled"
        exit 0
    fi
    
    # Stop services
    print_info "Stopping services..."
    cd "$CONFIG_DIR"
    EXTERNAL_DRIVE="$EXTERNAL_DRIVE" docker compose down
    
    # Restore database
    if [ -f "$backup_dir/immich_db.sql.gz" ]; then
        print_info "Restoring database..."
        
        # Start only PostgreSQL
        EXTERNAL_DRIVE="$EXTERNAL_DRIVE" docker compose up -d immich-postgres
        sleep 10
        
        # Drop and recreate database
        docker exec immich-postgres psql -U postgres -c "DROP DATABASE IF EXISTS immich;"
        docker exec immich-postgres psql -U postgres -c "CREATE DATABASE immich;"
        
        # Restore dump
        gunzip -c "$backup_dir/immich_db.sql.gz" | \
            docker exec -i immich-postgres psql -U postgres immich
        
        print_success "Database restored"
    fi
    
    # Restore uploads
    if [ -f "$backup_dir/immich_upload.tar.gz" ]; then
        print_info "Restoring uploads..."
        rm -rf "$EXTERNAL_DRIVE/immich/upload"
        mkdir -p "$EXTERNAL_DRIVE/immich/upload"
        tar -xzf "$backup_dir/immich_upload.tar.gz" -C "$EXTERNAL_DRIVE/immich"
        chown -R 1000:1000 "$EXTERNAL_DRIVE/immich/upload"
        print_success "Uploads restored"
    fi
    
    # Restore Docker volumes
    if [ -f "$backup_dir/portainer_data.tar.gz" ]; then
        print_info "Restoring Portainer data..."
        docker run --rm \
            -v portainer_data:/data \
            -v "$backup_dir:/backup" \
            alpine sh -c "rm -rf /data/* && tar -xzf /backup/portainer_data.tar.gz -C /data"
        print_success "Portainer data restored"
    fi
    
    # Restore configurations
    if [ -f "$backup_dir/config.json" ]; then
        cp "$backup_dir/config.json" "$CONFIG_FILE"
        print_success "Configuration restored"
    fi
    
    # Restore secrets (if encrypted)
    if [ -f "$backup_dir/secrets.tar.gz.enc" ]; then
        print_info "Restoring secrets..."
        read -sp "Enter decryption password: " DECRYPT_PASS
        echo
        
        openssl enc -aes-256-cbc -pbkdf2 -d -pass pass:"$DECRYPT_PASS" \
            -in "$backup_dir/secrets.tar.gz.enc" | \
            tar -xzf - -C "$CONFIG_DIR"
        
        print_success "Secrets restored"
    fi
    
    # Restart all services
    print_info "Starting all services..."
    EXTERNAL_DRIVE="$EXTERNAL_DRIVE" docker compose up -d
    
    print_success "Restore complete!"
}

# List available backups
list_backups() {
    print_header "Available Backups"
    
    if [ ! -d "$BACKUP_BASE" ]; then
        print_warning "No backups found"
        return
    fi
    
    local backups=$(find "$BACKUP_BASE" -maxdepth 1 -type d -name "20*" | sort -r)
    
    if [ -z "$backups" ]; then
        print_warning "No backups found"
        return
    fi
    
    echo "Backup Location: $BACKUP_BASE"
    echo
    printf "%-20s %-10s %-15s %s\n" "DATE" "TYPE" "SIZE" "PATH"
    echo "------------------------------------------------------------------------"
    
    echo "$backups" | while read backup; do
        local name=$(basename "$backup")
        local size=$(du -sh "$backup" 2>/dev/null | cut -f1)
        local type="Daily"
        
        if [ -f "$backup/.monthly" ]; then
            type="Monthly"
        elif [ -f "$backup/.weekly" ]; then
            type="Weekly"
        fi
        
        printf "%-20s %-10s %-15s %s\n" "$name" "$type" "$size" "$backup"
    done
}

# Main backup function
perform_backup() {
    print_header "Home Server Backup"
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then 
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        print_info "jq is not installed. Installing..."
        apt-get update -qq && apt-get install -y jq
        print_success "jq installed successfully"
    fi
    
    load_config
    create_backup_dir
    
    backup_database
    backup_immich_uploads
    backup_docker_volumes
    backup_configurations
    create_manifest
    
    local backup_size=$(du -sh "$BACKUP_DIR" | cut -f1)
    print_header "Backup Summary"
    echo "Backup Location: $BACKUP_DIR"
    echo "Total Size: $backup_size"
    echo "Timestamp: $(date)"
    
    rotate_backups
    
    print_success "Backup complete!"
}

# Usage information
usage() {
    echo "Usage: $0 [command] [options]"
    echo
    echo "Commands:"
    echo "  backup              Perform a full backup (default)"
    echo "  restore <path>      Restore from a backup"
    echo "  list                List available backups"
    echo
    echo "Examples:"
    echo "  $0                                    # Perform backup"
    echo "  $0 backup                             # Perform backup"
    echo "  $0 list                               # List backups"
    echo "  $0 restore /mnt/external-ssd/backups/20260205_120000"
}

# Main execution
main() {
    local command="${1:-backup}"
    
    case "$command" in
        backup)
            perform_backup
            ;;
        restore)
            if [ -z "${2:-}" ]; then
                print_error "Backup path required"
                usage
                exit 1
            fi
            load_config
            restore_backup "$2"
            ;;
        list)
            load_config
            list_backups
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
