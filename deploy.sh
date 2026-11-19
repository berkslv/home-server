#!/bin/bash
#
# Deploy the home server to a Raspberry Pi over SSH.
# Usage: PI=berkslv@192.168.1.100 ./deploy.sh
#        BUILD=1 ./deploy.sh   also rebuild the agent image (after changing agent/)
#
set -euo pipefail

PI="${PI:-berkslv@192.168.1.100}"
REMOTE_DIR="${REMOTE_DIR:-/opt/home-server}"
BUILD="${BUILD:-}"
cd "$(dirname "$0")"

[ -f .env ] || { echo ".env missing: copy .env.example and run cloudflare/setup.sh" >&2; exit 1; }
grep -q '^TUNNEL_TOKEN=.' .env || { echo "TUNNEL_TOKEN missing in .env, run cloudflare/setup.sh" >&2; exit 1; }

ssh -t "$PI" "sudo install -d -o \$USER -g \$USER $REMOTE_DIR"
rsync -az --delete --exclude .git --exclude .DS_Store --exclude .env --exclude .env.incoming ./ "$PI:$REMOTE_DIR/"
# Secrets: uploaded 600, then host/setup.sh moves them to root-only /etc/home-server/.env and deletes the copy
rsync -a --chmod=F600 .env "$PI:$REMOTE_DIR/.env.incoming"

# Host: Docker, cloudflared service, SSH keys; then the agent and Immich containers
ssh -t "$PI" "set -e
    sudo HOST_USER=\$USER $REMOTE_DIR/host/setup.sh || { rm -f $REMOTE_DIR/.env.incoming; exit 1; }
    cd $REMOTE_DIR
    if [ -n '$BUILD' ] || ! sudo docker image inspect home-server/agent:latest >/dev/null 2>&1; then
        sudo docker compose --env-file /etc/home-server/.env build agent
    fi
    sudo docker compose --env-file /etc/home-server/.env up -d --remove-orphans && sudo docker compose --env-file /etc/home-server/.env ps
    sudo docker compose -f immich/docker-compose.yml --env-file /opt/immich/.env up -d --remove-orphans
    sudo docker compose -f immich/docker-compose.yml --env-file /opt/immich/.env ps"
