# Home Server

Raspberry Pi (Ubuntu Server) running a Docker-based agent box, exposed through Cloudflare Tunnel and protected by Cloudflare Access.

```
laptop ── cloudflared access ssh ──▶ Cloudflare Access (email OTP) ──▶ Tunnel ──▶ cloudflared (Pi) ──▶ agent:22
```

- **cloudflared** – outbound-only tunnel connector; no ports are opened on the router.
- **agent** – Ubuntu 24.04 with Node.js, Python/uv, gh, git, tmux, build tools and Claude Code. Passwordless sudo for user `agent`; `/home/agent` persists in a volume.
- **ssh.berkslv.com** – SSH into the agent container, gated by an Access policy (email allowlist, one-time PIN). Also available as a browser terminal from the Access App Launcher.

## Layout

```
docker-compose.yml     cloudflared + agent
agent/                 agent image (Dockerfile, sshd config, entrypoint)
cloudflare/setup.sh    tunnel (wrangler), ingress, DNS, Access app + policy
deploy.sh              bootstrap Docker on the Pi, rsync, compose up
.env.example           TUNNEL_TOKEN, AUTHORIZED_KEYS, TZ
```

## Setup

### 1. Cloudflare

Create an API token at https://dash.cloudflare.com/profile/api-tokens with:

| Scope   | Permission                                            |
|---------|-------------------------------------------------------|
| Account | Cloudflare Tunnel: Edit                               |
| Account | Access: Apps and Policies: Edit                       |
| Account | Access: Organizations, Identity Providers, and Groups: Edit |
| Account | Account Settings: Read                                |
| Zone    | DNS: Edit, Zone: Read (berkslv.com)                   |

Zero Trust must be enabled on the account once (dashboard → Zero Trust, pick a team name, free plan).

```bash
npm i -g wrangler
cp .env.example .env    # set AUTHORIZED_KEYS to your public key(s)

CLOUDFLARE_API_TOKEN=... ACCESS_EMAILS=you@example.com ./cloudflare/setup.sh
```

The script is idempotent. It creates the `home-server` tunnel with `wrangler tunnel create`, sets its ingress to `ssh://agent:22`, creates the `ssh` CNAME, the Access policy and app, and writes `TUNNEL_TOKEN` to `.env`.

Optional variables: `DOMAIN`, `SSH_HOST`, `TUNNEL_NAME`, `SESSION_DURATION`, `CLOUDFLARE_ACCOUNT_ID`.

### 2. Deploy to the Pi

```bash
PI=berkslv@192.168.1.111 ./deploy.sh
```

Installs Docker if missing, syncs this directory to `/opt/home-server` and runs `docker compose up -d --build`.

### 3. Connect

```bash
brew install cloudflared
```

`~/.ssh/config`:

```
Host ssh.berkslv.com
  User agent
  ProxyCommand cloudflared access ssh --hostname %h
```

```bash
ssh ssh.berkslv.com
```

The first connection opens a browser for the Access login (email one-time PIN).

### Adding a new machine

Every machine needs cloudflared, the `~/.ssh/config` block above and **its own SSH key** in `AUTHORIZED_KEYS`:

1. Install cloudflared: `brew install cloudflared` (macOS) or `winget install --id Cloudflare.cloudflared` (Windows).
2. Add the ssh config. On Windows it is `C:\Users\<you>\.ssh\config`, with the full path from `where.exe cloudflared`:
   ```
   Host ssh.berkslv.com
     User agent
     ProxyCommand "C:\Program Files (x86)\cloudflared\cloudflared.exe" access ssh --hostname %h
   ```
3. Create a key: `ssh-keygen -t ed25519`. Add its public key (`~/.ssh/id_ed25519.pub`) as a new line inside the quotes of `AUTHORIZED_KEYS` in `.env`, with a comment naming the machine. Then run `./deploy.sh`.
4. Run `ssh ssh.berkslv.com` and log in with your email code.

To revoke a machine, delete its line and redeploy. Don't edit `~/.ssh/authorized_keys` inside the container: it is rewritten from `.env` on every start. Avoid copying one private key between machines, so each machine can be revoked on its own.

## Management (on the Pi)

```bash
cd /opt/home-server
sudo docker compose logs -f
sudo docker compose up -d --build     # rebuild the agent image
sudo docker compose pull cloudflared && sudo docker compose up -d
```

Changing keys: edit `AUTHORIZED_KEYS` in `.env` and redeploy; the entrypoint rewrites `authorized_keys` on start.

GitHub: set `GH_TOKEN` (fine-grained PAT), `GIT_USER_NAME` and `GIT_USER_EMAIL` in `.env` and redeploy. The entrypoint logs `gh` in with the token and configures git to use it, so `gh` and `git push` work in SSH sessions. Rotate by replacing the token and redeploying.

## Notes

- The agent container has no Docker socket. Mounting `/var/run/docker.sock` would give it root on the host.
- For direct LAN access without Cloudflare, uncomment `ports: 2222:22` on the agent service.
