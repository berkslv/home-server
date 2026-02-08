# Home Server

Docker-based home server featuring Immich (photo management with ML), Portainer (container management), Glances (system monitoring), and Cloudflare Tunnel (secure remote access).

## Features

- **Immich** - Self-hosted photo/video management with machine learning
- **Portainer** - Docker management web UI
- **Glances** - Real-time system monitoring
- **Cloudflare Tunnel** - Secure remote access without port forwarding
- **One-Command Deployment** - Automated setup with credential generation

## Quick Start

### Prerequisites

- Ubuntu/Raspberry Pi OS (64-bit)
- 4GB+ RAM (8GB recommended)
- 20GB+ available storage
- [Cloudflare Tunnel Token](https://one.dash.cloudflare.com/) (Networks > Tunnels)

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

# Non-interactive (set CF_TUNNEL_TOKEN first)
export CF_TUNNEL_TOKEN="your-token"
wget -qO- https://raw.githubusercontent.com/berkslv/home-server/main/deploy.sh | sudo -E bash -s -- -y
```

## Access Services

After deployment:

- **Immich**: `http://localhost:2283`
- **Portainer**: `https://localhost:9443`
- **Glances**: `http://localhost:61208`

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
docker rm -f cloudflared portainer glances immich-server immich-machine-learning immich-postgres immich-redis

# Remove volumes
docker volume rm portainer_data model-cache
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
