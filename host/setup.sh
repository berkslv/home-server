#!/bin/bash
#
# Host bootstrap, run on the Pi as root by deploy.sh. Idempotent.
#   - Docker (Ubuntu packages) for the agent and Immich containers
#   - /opt/immich (root-only) with a generated DB password on first run
#   - deploy secrets: /etc/home-server/.env (root 600; deploy.sh hands .env over, it never stays in the repo dir)
#   - cloudflared as a systemd service, tunnel token from that .env
#   - AUTHORIZED_KEYS from that .env -> host user's ~/.ssh/authorized_keys
#   - backup / restore-test / health check via host/install-ops.sh
#
# Usage: sudo HOST_USER=berkslv ./host/setup.sh
#
set -euo pipefail

HOST_USER="${HOST_USER:?HOST_USER is required}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
log() { echo -e "\033[0;34m[INFO]\033[0m $*"; }

# Deploy secrets live root-only in /etc/home-server/.env, never in the repo dir: the host user (and so
# any agent running as it) must not be able to read the tunnel token or the Access service token.
# deploy.sh uploads .env as $DIR/.env.incoming; take it over and delete it. ($DIR/.env: pre-2026-11-19 layout)
ENV_FILE=/etc/home-server/.env
install -d -m 700 -o root -g root /etc/home-server
for f in "$DIR/.env.incoming" "$DIR/.env"; do
    if [ -f "$f" ]; then install -m 600 -o root -g root "$f" "$ENV_FILE"; rm -f "$f"; log "secrets -> $ENV_FILE"; fi
done
[ -f "$ENV_FILE" ] || { echo "$ENV_FILE missing: run deploy.sh from the machine that has .env" >&2; exit 1; }

# Read only the values we need from .env (docker-compose syntax, quoted multi-line values allowed)
TUNNEL_TOKEN=$(grep -E '^TUNNEL_TOKEN=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"')
AUTHORIZED_KEYS=$(awk '/^AUTHORIZED_KEYS=/{f=1; sub(/^AUTHORIZED_KEYS="?/, "")} f{if (sub(/"$/, "")) {print; exit} print}' "$ENV_FILE")
[ -n "$TUNNEL_TOKEN" ] || { echo "TUNNEL_TOKEN missing in .env" >&2; exit 1; }
[ -n "$AUTHORIZED_KEYS" ] || { echo "AUTHORIZED_KEYS missing in .env" >&2; exit 1; }

# Docker
if ! command -v docker >/dev/null; then
    log "Installing Docker"
    apt-get update
    apt-get install -y docker.io docker-compose-v2 docker-buildx
fi
systemctl enable --now docker >/dev/null
# The docker group is root-equivalent and would expose /opt/immich; deploy uses sudo instead
gpasswd -d "$HOST_USER" docker >/dev/null 2>&1 || true

# Immich: data and secrets stay root-only, outside the rsync'd repo dir
install -d -m 700 -o root -g root /opt/immich
install -d -m 755 -o root -g root /opt/immich/library
if [ ! -f /opt/immich/.env ]; then
    log "Creating /opt/immich/.env with a new DB password"
    (umask 077; cat > /opt/immich/.env <<EOF
DB_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
TZ=Europe/Istanbul
EOF
    )
fi

# cloudflared from Cloudflare's apt repo
if ! command -v cloudflared >/dev/null; then
    log "Installing cloudflared"
    install -d -m 755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
        > /etc/apt/sources.list.d/cloudflared.list
    apt-get update
    apt-get install -y cloudflared
fi

# cloudflared service; the token lives in a root-only env file, not on the command line
install -d -m 700 /etc/cloudflared
printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" > /etc/cloudflared/tunnel.env
chmod 600 /etc/cloudflared/tunnel.env
cat > /etc/systemd/system/cloudflared.service <<'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=/etc/cloudflared/tunnel.env
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cloudflared >/dev/null
systemctl restart cloudflared
log "cloudflared: $(systemctl is-active cloudflared)"

# Host SSH keys: same list as the agent container, rewritten on every deploy
HOME_DIR=$(getent passwd "$HOST_USER" | cut -d: -f6)
install -d -m 700 -o "$HOST_USER" -g "$HOST_USER" "$HOME_DIR/.ssh"
printf '%s\n' "$AUTHORIZED_KEYS" > "$HOME_DIR/.ssh/authorized_keys"
chown "$HOST_USER:$HOST_USER" "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
log "authorized_keys: $(grep -c . "$HOME_DIR/.ssh/authorized_keys") key(s) for $HOST_USER"

# sshd: keys only. sshd keeps the first value it reads, so this must sort before 50-cloud-init.conf
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $HOST_USER
EOF
sshd -t
systemctl reload ssh
log "sshd: $(sshd -T | grep -iE '^(passwordauthentication|permitrootlogin)' | tr '\n' ' ')"

# Backup, restore test and health check (scripts + systemd timers) from backup/ and health/
"$DIR/host/install-ops.sh"
