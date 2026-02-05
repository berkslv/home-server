# Testing the Deployment Script

Simple guide to test the deployment script locally using Docker.

## Quick Test

```bash
# Run Ubuntu container with Docker access
docker run -it --rm --privileged -v /var/run/docker.sock:/var/run/docker.sock -v $(pwd):/workspace ubuntu:22.04 bash

# Inside container - create external SSD directory
mkdir -p /mnt/external-ssd

# Run the deployment
cd /workspace
bash deploy.sh
```

## Test with wget (Optional - Only if you want to test remote download)

This simulates downloading from GitHub/remote server. **Not needed for basic testing.**

```bash
# Terminal 2: Run container and test wget download
docker run -it --rm --privileged -v /var/run/docker.sock:/var/run/docker.sock --network host ubuntu:22.04 bash

# Inside container:
mkdir -p /mnt/external-ssd
wget -qO- http://localhost:8000/deploy.sh | bash
```

## Verify Deployment

After deployment completes:

```bash
# Check running containers
docker ps

# View logs
cd /opt/home-server
docker compose logs -f

# Check configuration
cat /opt/home-server/config.json

# List secrets
ls -la /opt/home-server/secrets/
```

## Test Backup

```bash
# Run backup
bash /opt/home-server/scripts/backup.sh backup

# List backups
bash /opt/home-server/scripts/backup.sh list

# View backup contents
ls -la /mnt/external-ssd/backups/
```

## Clean Up

```bash
# Exit container (Ctrl+D)

# Remove deployed services
docker rm -f cloudflared portainer glances immich-server immich-microservices immich-postgres immich-redis

# Remove volumes
docker volume rm portainer_data
```
