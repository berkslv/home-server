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

# agent-cron: settings file for the CLI (SSH sessions don't inherit container env),
# then the scheduler in its own tmux server; each job run gets a window there
if [ -n "${JOBS_REPO:-}" ]; then
    install -d -m 700 -o agent -g agent /home/agent/.agent-cron
    (
        umask 077
        for var in JOBS_REPO JOBS_OWNER JOBS_LABEL JOBS_MAX_CONCURRENT JOBS_SYNC_INTERVAL JOBS_COMMENT_POLL \
                   OPENCODE_MODEL OPENROUTER_API_KEY RESEND_API_KEY RESEND_FROM NOTIFICATION_EMAIL TZ; do
            [ -z "${!var:-}" ] || printf '%s=%q\n' "$var" "${!var}"
        done > /home/agent/.agent-cron/env
    )
    chown agent:agent /home/agent/.agent-cron/env
    as_agent tmux -L agent-cron new-session -d -s agent-cron -n scheduler \
        "while true; do agent-cron daemon; echo 'scheduler exited, restarting in 10s'; sleep 10; done"
    as_agent tmux -L agent-cron set-option -g history-limit 50000
    echo "agent-cron: scheduler started (tmux -L agent-cron attach)"
fi

exec /usr/sbin/sshd -D -e
