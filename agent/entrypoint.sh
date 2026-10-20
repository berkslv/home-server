#!/bin/bash
set -euo pipefail

# Persistent host keys so the fingerprint survives rebuilds
[ -f /etc/ssh/keys/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/keys/ssh_host_ed25519_key
[ -f /etc/ssh/keys/ssh_host_rsa_key ] || ssh-keygen -q -t rsa -b 4096 -N "" -f /etc/ssh/keys/ssh_host_rsa_key

# Seed the home volume on first start
if [ ! -f /home/agent/.bashrc ]; then
    cp -a /opt/agent-skel/. /home/agent/
fi
chown agent:agent /home/agent

# Authorized keys come from the AUTHORIZED_KEYS env var (newline separated)
install -d -m 700 -o agent -g agent /home/agent/.ssh
printf '%s\n' "$AUTHORIZED_KEYS" > /home/agent/.ssh/authorized_keys
chown agent:agent /home/agent/.ssh/authorized_keys
chmod 600 /home/agent/.ssh/authorized_keys

# Make the container env (TZ, etc.) visible to SSH sessions
if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone
fi

exec /usr/sbin/sshd -D -e
