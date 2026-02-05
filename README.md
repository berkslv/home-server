# Raspberry Pi Home Server

A complete Docker-based home server solution for Raspberry Pi featuring Immich (photo management), Portainer (container management), Glances (system monitoring), and Cloudflare Tunnel (secure remote access).

## Features

- **Immich** - Self-hosted photo and video management (without ML for better performance on Pi)
- **Portainer** - Docker container management with web UI
- **Glances** - Real-time system monitoring dashboard
- **Cloudflare Tunnel** - Secure remote access without port forwarding
- **Automated Backups** - PostgreSQL dumps and data backups with rotation
- **One-Command Deployment** - Interactive setup script with credential generation

## Prerequisites

### Hardware
- **Raspberry Pi 4/5** (4GB RAM minimum, 8GB recommended)
- **External SSD** (strongly recommended over SD card for performance)
  - Minimum 128GB for photos
  - USB 3.0 connection recommended
  - Pre-mounted before deployment (e.g., `/mnt/external-ssd`)
- **Stable Internet Connection** (for initial setup and Cloudflare Tunnel)

### Software
- **Raspberry Pi OS** (64-bit recommended)
- **Docker** and **Docker Compose** installed
  ```bash
  curl -fsSL https://get.docker.com -o get-docker.sh
  sudo sh get-docker.sh
  sudo usermod -aG docker $USER
  ```
- **Git** (optional, for cloning repository)

### Cloudflare Account
- Free Cloudflare account
- Domain configured in Cloudflare
- Cloudflare Tunnel created:
  1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/)
  2. Navigate to **Networks > Tunnels**
  3. Create a new tunnel
  4. Copy the tunnel token (you'll need this during deployment)

## Quick Start

### Method 1: Direct Deployment (Recommended)

```bash
# Mount your external SSD first
sudo mkdir -p /mnt/external-ssd
sudo mount /dev/sda1 /mnt/external-ssd  # Adjust device name as needed

# Download and run deployment script
cd /tmp
git clone https://github.com/berkslv/home-server.git
cd home-server
sudo bash deploy.sh
```

### Method 2: wget One-Liner

```bash
# Interactive mode
wget -qO- https://raw.githubusercontent.com/berkslv/home-server/main/deploy.sh --no-check-certificate | sudo bash

# Non-interactive mode (requires CF_TUNNEL_TOKEN environment variable)
export CF_TUNNEL_TOKEN="your-cloudflare-tunnel-token-here"
wget -qO- https://raw.githubusercontent.com/berkslv/home-server/main/deploy.sh --no-check-certificate | sudo -E bash -s -- -y
```

## Deployment Process

The deployment script will guide you through:

1. **Pre-flight Checks**
   - Verify Docker installation
   - Check system architecture (ARM64)
   - Validate available memory

2. **External Storage Configuration**
   - Detect mounted drives
   - Validate selected mount point
   - Check available disk space

3. **Cloudflare Tunnel Setup**
   - Prompt for tunnel token
   - Configure secure remote access

4. **Credential Generation**
   - Auto-generate PostgreSQL password (24 characters)
   - Securely store credentials in `/opt/home-server/secrets/`

5. **Directory Setup**
   - Create Immich directories on external SSD
   - Set proper permissions for containers

6. **Service Deployment**
   - Pull Docker images (ARM64 compatible)
   - Start all services with health checks

## Post-Deployment

After successful deployment, you'll see a summary with:

### Service URLs

Access your services locally:

- **Immich**: `http://<raspberry-pi-ip>:2283`
- **Portainer**: `https://<raspberry-pi-ip>:9443`
- **Glances**: `http://<raspberry-pi-ip>:61208`

### Generated Credentials

The script displays the auto-generated PostgreSQL password. **Save this securely!**

Credentials are stored in:
- PostgreSQL password: `/opt/home-server/secrets/db_password`
- Cloudflare token: `/opt/home-server/secrets/cf_tunnel_token`
- Configuration: `/opt/home-server/config.json`

### First-Time Setup

**Immich:**
1. Navigate to `http://<raspberry-pi-ip>:2283`
2. Create your admin account
3. Start uploading photos via web or mobile app

**Portainer:**
1. Navigate to `https://<raspberry-pi-ip>:9443`
2. Set admin password on first login
3. Connect to local Docker environment (already configured)

**Cloudflare Tunnel:**
Configure public hostnames in Cloudflare dashboard to route traffic to your services.

## Storage Locations

All data is stored on your external SSD:

```
/mnt/external-ssd/  (or your chosen path)
├── immich/
│   ├── upload/          # Your photos and videos
│   └── postgres/        # Database files
└── backups/             # Automated backups
    └── YYYYMMDD_HHMMSS/ # Timestamped backup folders
```

## Backup & Restore

### Manual Backup

```bash
sudo /opt/home-server/scripts/backup.sh backup
```

### List Available Backups

```bash
sudo /opt/home-server/scripts/backup.sh list
```

### Restore from Backup

```bash
sudo /opt/home-server/scripts/backup.sh restore /mnt/external-ssd/backups/20260205_120000
```

### Automated Backups with Cron

Add to root's crontab:

```bash
sudo crontab -e
```

Add this line (runs daily at 2 AM):

```
0 2 * * * /opt/home-server/scripts/backup.sh backup >> /var/log/home-server-backup.log 2>&1
```

### Backup Retention Policy

- **Daily backups**: Last 7 days
- **Weekly backups**: Last 4 weeks (Sundays)
- **Monthly backups**: Last 3 months (1st of month)

## Management Commands

All commands should be run from `/opt/home-server/`:

```bash
cd /opt/home-server

# View logs
EXTERNAL_DRIVE=/mnt/external-ssd docker compose logs -f

# View specific service logs
EXTERNAL_DRIVE=/mnt/external-ssd docker compose logs -f immich-server

# Restart all services
EXTERNAL_DRIVE=/mnt/external-ssd docker compose restart

# Restart specific service
EXTERNAL_DRIVE=/mnt/external-ssd docker compose restart immich-server

# Stop all services
EXTERNAL_DRIVE=/mnt/external-ssd docker compose down

# Start all services
EXTERNAL_DRIVE=/mnt/external-ssd docker compose up -d

# Update to latest versions
EXTERNAL_DRIVE=/mnt/external-ssd docker compose pull
EXTERNAL_DRIVE=/mnt/external-ssd docker compose up -d

# Check service status
EXTERNAL_DRIVE=/mnt/external-ssd docker compose ps
```

## Troubleshooting

### Services Not Starting

Check logs:
```bash
cd /opt/home-server
EXTERNAL_DRIVE=/mnt/external-ssd docker compose logs
```

### External Drive Not Detected

Ensure it's mounted:
```bash
# Check mount point
mountpoint -q /mnt/external-ssd && echo "Mounted" || echo "Not mounted"

# List block devices
lsblk

# Mount manually
sudo mount /dev/sda1 /mnt/external-ssd
```

### Auto-mount External Drive on Boot

Create systemd mount unit:

```bash
# Find UUID of your drive
sudo blkid

# Create mount unit
sudo nano /etc/systemd/system/mnt-external\x2dssd.mount
```

Add:
```ini
[Unit]
Description=External SSD for Home Server

[Mount]
What=/dev/disk/by-uuid/YOUR-UUID-HERE
Where=/mnt/external-ssd
Type=ext4
Options=defaults,nofail

[Install]
WantedBy=multi-user.target
```

Enable:
```bash
sudo systemctl daemon-reload
sudo systemctl enable mnt-external\x2dssd.mount
sudo systemctl start mnt-external\x2dssd.mount
```

### Immich Upload Issues

Check permissions:
```bash
ls -la /mnt/external-ssd/immich/upload
# Should be owned by 1000:1000

# Fix if needed
sudo chown -R 1000:1000 /mnt/external-ssd/immich/upload
```

### PostgreSQL Connection Errors

Check database container:
```bash
docker logs immich-postgres

# Verify permissions
ls -la /mnt/external-ssd/immich/postgres
# Should be owned by 999:999 with 700 permissions
```

### Low Memory Issues

Monitor with Glances or:
```bash
free -h
docker stats
```

Reduce memory limits in `docker-compose.yml` if needed.

### Cloudflare Tunnel Not Working

Check tunnel status:
```bash
docker logs cloudflared

# Verify token is valid
cat /opt/home-server/secrets/cf_tunnel_token
```

## Updating Services

### Update All Services

```bash
cd /opt/home-server
EXTERNAL_DRIVE=/mnt/external-ssd docker compose pull
EXTERNAL_DRIVE=/mnt/external-ssd docker compose up -d
```

### Update Specific Service

```bash
cd /opt/home-server
EXTERNAL_DRIVE=/mnt/external-ssd docker compose pull immich-server
EXTERNAL_DRIVE=/mnt/external-ssd docker compose up -d immich-server
```

## Uninstalling

To completely remove the home server:

```bash
# Stop and remove containers
cd /opt/home-server
EXTERNAL_DRIVE=/mnt/external-ssd docker compose down -v

# Remove configuration (keeps external drive data)
sudo rm -rf /opt/home-server

# Optional: Remove data from external drive
# sudo rm -rf /mnt/external-ssd/immich
# sudo rm -rf /mnt/external-ssd/backups
```

## Performance Tips

1. **Use SSD instead of SD card** - Dramatically improves database and photo loading performance
2. **Disable ML features** - Already disabled in this setup for better performance
3. **Limit concurrent uploads** - Start with small batches when initially uploading photos
4. **Monitor resources** - Use Glances to watch CPU, memory, and disk usage
5. **Regular maintenance** - Keep Docker images updated and clean up unused images

## Security Notes

- All credentials are auto-generated and stored securely
- Secrets have 600 permissions (readable only by root)
- Cloudflare Tunnel provides secure access without exposing ports
- Database credentials never stored in environment variables
- Regular backups include encrypted secrets

## Architecture

```
┌─────────────────────────────────────────────┐
│         Cloudflare Tunnel                   │
│     (Secure Remote Access)                  │
└──────────────┬──────────────────────────────┘
               │
┌──────────────┴──────────────────────────────┐
│         Raspberry Pi Home Server            │
│                                             │
│  ┌─────────────┐  ┌──────────────┐        │
│  │  Portainer  │  │   Glances    │        │
│  │   :9443     │  │   :61208     │        │
│  └─────────────┘  └──────────────┘        │
│                                             │
│  ┌─────────────────────────────────────┐  │
│  │         Immich Stack                │  │
│  │  ┌──────────┐  ┌────────────────┐  │  │
│  │  │  Redis   │  │   PostgreSQL   │  │  │
│  │  └──────────┘  └────────────────┘  │  │
│  │  ┌──────────────────────────────┐  │  │
│  │  │     Immich Server :2283      │  │  │
│  │  └──────────────────────────────┘  │  │
│  │  ┌──────────────────────────────┐  │  │
│  │  │   Immich Microservices       │  │  │
│  │  └──────────────────────────────┘  │  │
│  └─────────────────────────────────────┘  │
└─────────────────┬───────────────────────────┘
                  │
         ┌────────┴─────────┐
         │  External SSD    │
         │  Photos & Data   │
         └──────────────────┘
```

## License

MIT License - Feel free to modify and distribute

## Support

For issues and questions:
- Check the troubleshooting section above
- Review Docker logs for specific services
- Consult official documentation:
  - [Immich Documentation](https://immich.app/docs)
  - [Portainer Documentation](https://docs.portainer.io/)
  - [Cloudflare Tunnel Docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)

## Acknowledgments

- **Immich** - Amazing self-hosted photo management
- **Portainer** - Docker management made easy
- **Glances** - Comprehensive system monitoring
- **Cloudflare** - Secure tunnel solution
