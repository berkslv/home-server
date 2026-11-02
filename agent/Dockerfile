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
        libatomic1 ripgrep fd-find tree iputils-ping dnsutils procps tzdata locales \
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

# Non-root user (ubuntu image ships uid 1000 as "ubuntu"; replace it)
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent \
    && chmod 440 /etc/sudoers.d/agent

# Hermes Agent, installed as the agent user into ~/.hermes so the skel copy below seeds a fresh home volume with it.
# The telegram extra is preinstalled: otherwise the gateway stops at an install prompt on first start.
RUN runuser -u agent -- env HOME=/home/agent \
        bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup --skip-browser --skip-computer-use \
            && ~/.local/bin/hermes pm install --extra telegram </dev/null' \
    && cp -a /home/agent /opt/agent-skel

COPY sshd_config /etc/ssh/sshd_config.d/agent.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh && mkdir -p /run/sshd /etc/ssh/keys

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
