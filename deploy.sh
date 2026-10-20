#!/bin/bash
#
# Deploy the home server stack to a Raspberry Pi over SSH.
# Usage: PI=berkslv@192.168.1.111 ./deploy.sh
#
set -euo pipefail

PI="${PI:-berkslv@192.168.1.111}"
REMOTE_DIR="${REMOTE_DIR:-/opt/home-server}"
cd "$(dirname "$0")"

[ -f .env ] || { echo ".env missing: copy .env.example and run cloudflare/setup.sh" >&2; exit 1; }
grep -q '^TUNNEL_TOKEN=.' .env || { echo "TUNNEL_TOKEN missing in .env, run cloudflare/setup.sh" >&2; exit 1; }

# One-time host bootstrap: Docker + target dir
ssh -t "$PI" "set -e
    if ! command -v docker >/dev/null; then
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker \$USER
    fi
    sudo install -d -o \$USER -g \$USER $REMOTE_DIR"

rsync -az --delete --exclude .git --exclude .DS_Store ./ "$PI:$REMOTE_DIR/"
ssh "$PI" "chmod 600 $REMOTE_DIR/.env && cd $REMOTE_DIR && sudo docker compose up -d --build --remove-orphans && sudo docker compose ps"
