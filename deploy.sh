#!/bin/bash
#
# Deploy the home server to a Raspberry Pi over SSH.
# Usage: PI=berkslv@192.168.1.106 ./deploy.sh
#
set -euo pipefail

PI="${PI:-berkslv@192.168.1.106}"
REMOTE_DIR="${REMOTE_DIR:-/opt/home-server}"
cd "$(dirname "$0")"

[ -f .env ] || { echo ".env missing: copy .env.example and run cloudflare/setup.sh" >&2; exit 1; }
grep -q '^TUNNEL_TOKEN=.' .env || { echo "TUNNEL_TOKEN missing in .env, run cloudflare/setup.sh" >&2; exit 1; }

ssh -t "$PI" "sudo install -d -o \$USER -g \$USER $REMOTE_DIR"
rsync -az --delete --exclude .git --exclude .DS_Store ./ "$PI:$REMOTE_DIR/"

# Host: Docker, cloudflared service, SSH keys; then the agent container
ssh -t "$PI" "set -e
    chmod 600 $REMOTE_DIR/.env
    sudo HOST_USER=\$USER $REMOTE_DIR/host/setup.sh
    cd $REMOTE_DIR && sudo docker compose up -d --build --remove-orphans && sudo docker compose ps"
