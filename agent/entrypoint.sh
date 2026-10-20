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

# GitHub: store GH_TOKEN in gh's config (SSH sessions don't inherit container env)
as_agent() { runuser -u agent -- env -u GH_TOKEN HOME=/home/agent "$@"; }
if [ -n "${GH_TOKEN:-}" ]; then
    if printf '%s' "$GH_TOKEN" | as_agent gh auth login --hostname github.com --git-protocol https --with-token \
        && as_agent gh auth setup-git --hostname github.com; then
        echo "GitHub: authenticated as $(as_agent gh api user --jq .login 2>/dev/null || echo '?')"
    else
        echo "GitHub: login with GH_TOKEN failed, continuing without it" >&2
    fi
fi
[ -z "${GIT_USER_NAME:-}" ] || as_agent git config --global user.name "$GIT_USER_NAME"
[ -z "${GIT_USER_EMAIL:-}" ] || as_agent git config --global user.email "$GIT_USER_EMAIL"

# Make the container env (TZ, etc.) visible to SSH sessions
if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone
fi

exec /usr/sbin/sshd -D -e
