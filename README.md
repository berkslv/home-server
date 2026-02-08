# Home Server

Docker-based home server featuring Immich (photo management with ML), Portainer (container management), Glances (system monitoring), and Tailscale (secure remote access).

## Features

- **Immich** - Self-hosted photo/video management with machine learning
- **Portainer** - Docker management web UI
- **Glances** - Real-time system monitoring
- **Tailscale** - Zero-config VPN for secure remote access
- **One-Command Deployment** - Automated setup with credential generation

## Quick Start

### Prerequisites

- Ubuntu/Raspberry Pi OS (64-bit)
- 4GB+ RAM (8GB recommended)
- 20GB+ available storage
- [Tailscale Auth Key](https://login.tailscale.com/admin/settings/keys) (Generate reusable key)

### Deploy

```bash
# Clone repository
git clone https://github.com/berkslv/home-server.git
cd home-server

# Run deployment
sudo bash deploy.sh
```

### One-Liner Installation

```bash
# Interactive mode
wget -qO- https://raw.githubusercontent.com/berkslv/home-server/main/deploy.sh | sudo bash

# Non-interactive (set TAILSCALE_AUTH_KEY first)
export TAILSCALE_AUTH_KEY="tskey-auth-xxx"
wget -qO- https://raw.githubusercontent.com/berkslv/home-server/main/deploy.sh | sudo -E bash -s -- -y
```

## Access Services

After deployment:

**Local access:**
- **Immich**: `http://localhost:2283`
- **Portainer**: `https://localhost:9443`
- **Glances**: `http://localhost:61208`

**Remote access via Tailscale:**
- **Immich**: `http://home-server:2283`
- **Portainer**: `https://home-server:9443`
- **Glances**: `http://home-server:61208`

Create admin accounts on first login.

## Management

```bash
cd /opt/home-server

# View logs
docker compose logs -f

# Restart services
EXTERNAL_DRIVE=/var/lib/home-server docker compose restart

# Update services
EXTERNAL_DRIVE=/var/lib/home-server docker compose pull
EXTERNAL_DRIVE=/var/lib/home-server docker compose up -d

# Stop all
EXTERNAL_DRIVE=/var/lib/home-server docker compose down
```

## Storage Locations

```
/var/lib/home-server/
├── immich/upload/    # Photos and videos
├── immich/postgres/  # Database
└── backups/          # Backups
```

Configuration and secrets: `/opt/home-server/`

## Testing Locally

Test with Docker:

```bash
# Run Ubuntu container
docker run -it --rm --privileged \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v $(pwd):/workspace \
  ubuntu:22.04 bash

# Inside container
cd /workspace
bash deploy.sh
```

Verify deployment:

```bash
# Check containers
docker ps

# View logs
cd /opt/home-server && docker compose logs

# Check config
cat /opt/home-server/config.json
```

Clean up:

```bash
# Exit container (Ctrl+D)

# Remove containers
docker rm -f tailscale portainer glances immich-server immich-machine-learning immich-postgres immich-redis

# Remove volumes
docker volume rm portainer_data model-cache tailscale_state
```

## Troubleshooting

**View logs:**
```bash
cd /opt/home-server
docker compose logs -f [service-name]
```

**Check permissions:**
```bash
# Immich upload (should be 1000:1000)
ls -la /var/lib/home-server/immich/upload

# PostgreSQL (should be 999:999)
ls -la /var/lib/home-server/immich/postgres
```

**Check resources:**
```bash
docker stats
free -h
```

## Uninstall

```bash
cd /opt/home-server
docker compose down -v
sudo rm -rf /opt/home-server
sudo rm -rf /var/lib/home-server  # Optional: removes all data
```

## License

MIT
