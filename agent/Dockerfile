FROM ubuntu:24.04

ARG NODE_MAJOR=24
ARG OPENCODE_VERSION=1.19.3
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Base CLI tooling
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo ca-certificates curl wget gnupg \
        git jq vim nano tmux htop less unzip zip rsync \
        build-essential python3 python3-pip python3-venv \
        ripgrep fd-find tree iputils-ping dnsutils procps tzdata locales \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

# Node.js, GitHub CLI
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends nodejs gh \
    && rm -rf /var/lib/apt/lists/*

# uv (Python), Claude Code and opencode
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
    && npm install -g @anthropic-ai/claude-code opencode-ai@${OPENCODE_VERSION} \
    && npm cache clean --force

# agent-cron: scheduled opencode jobs defined as GitHub issues
COPY agent-cron/package.json agent-cron/package-lock.json /opt/agent-cron/
RUN cd /opt/agent-cron && npm ci --omit=dev && npm cache clean --force
COPY agent-cron/src /opt/agent-cron/src
COPY agent-cron/agent-cron.sh /usr/local/bin/agent-cron

# Non-root user (ubuntu image ships uid 1000 as "ubuntu"; replace it)
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent \
    && chmod 440 /etc/sudoers.d/agent \
    && cp -a /home/agent /opt/agent-skel

COPY sshd_config /etc/ssh/sshd_config.d/agent.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/agent-cron && mkdir -p /run/sshd /etc/ssh/keys

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
