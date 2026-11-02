# Home Server

Raspberry Pi (Ubuntu Server) exposed through Cloudflare Tunnel and protected by Cloudflare Access, running a Docker-based agent box.

```
laptop ── cloudflared access ssh ──▶ Cloudflare Access (email OTP) ──▶ Tunnel ──▶ cloudflared (Pi host) ──▶ Pi sshd :22
                                                                                                        └─▶ agent container 127.0.0.1:2222
```

- **cloudflared** – runs on the Pi as a systemd service (not in Docker); outbound-only, no ports are opened on the router.
- **ssh.berkslv.com** – SSH into the Pi host itself, gated by an Access policy (email allowlist, one-time PIN). Also available as a browser terminal from the Access App Launcher.
- **agent** – Ubuntu 24.04 container with Node.js, Python/uv, gh, git, tmux, build tools, Claude Code, opencode and Hermes Agent. Passwordless sudo for user `agent`; `/home/agent` persists in a volume. Its sshd is published only on the Pi's `127.0.0.1:2222`, reached with a ProxyJump through the host.

## Layout

```
docker-compose.yml     agent container
agent/                 agent image (Dockerfile, sshd config, entrypoint)
host/setup.sh          on the Pi: Docker, cloudflared systemd service, host authorized_keys
cloudflare/setup.sh    tunnel (wrangler), ingress, DNS, Access app + policy
deploy.sh              rsync to the Pi, run host/setup.sh, compose up
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

The script is idempotent. It creates the `home-server` tunnel with `wrangler tunnel create`, sets its ingress to `ssh://localhost:22` (the Pi's own sshd), creates the `ssh` CNAME, the Access policy and app, and writes `TUNNEL_TOKEN` to `.env`.

Optional variables: `DOMAIN`, `SSH_HOST`, `TUNNEL_NAME`, `SESSION_DURATION`, `CLOUDFLARE_ACCOUNT_ID`.

### 2. Deploy to the Pi

```bash
PI=berkslv@192.168.1.106 ./deploy.sh
```

Syncs this directory to `/opt/home-server`, then runs `host/setup.sh` as root (installs Docker and cloudflared from apt, writes the tunnel token to `/etc/cloudflared/tunnel.env`, installs the `cloudflared` systemd unit, writes `AUTHORIZED_KEYS` to the host user's `~/.ssh/authorized_keys`) and `docker compose up -d --build`. It asks for the sudo password.

### 3. Connect

```bash
brew install cloudflared
```

`~/.ssh/config`:

```
Host ssh.berkslv.com
  User berkslv
  ProxyCommand cloudflared access ssh --hostname %h

Host agent
  HostName localhost
  Port 2222
  User agent
  ProxyJump ssh.berkslv.com
```

```bash
ssh ssh.berkslv.com   # Pi host
ssh agent             # agent container, through the host
ssh -J ssh.berkslv.com -p 2222 agent@localhost   # same, without the "Host agent" block
```

From a shell on the Pi itself there is no private key, so use `docker exec -it -u agent agent bash -l`, or connect with `ssh -A ssh.berkslv.com` to forward your key.

The first connection opens a browser for the Access login (email one-time PIN).

### Adding a new machine

Every machine needs cloudflared, the `~/.ssh/config` block above and **its own SSH key** in `AUTHORIZED_KEYS`:

1. Install cloudflared: `brew install cloudflared` (macOS) or `winget install --id Cloudflare.cloudflared` (Windows).
2. Add the ssh config. On Windows it is `C:\Users\<you>\.ssh\config`, with the full path from `where.exe cloudflared`:
   ```
   Host ssh.berkslv.com
     User berkslv
     ProxyCommand "C:\Program Files (x86)\cloudflared\cloudflared.exe" access ssh --hostname %h

   Host agent
     HostName localhost
     Port 2222
     User agent
     ProxyJump ssh.berkslv.com
   ```
3. Create a key: `ssh-keygen -t ed25519`. Add its public key (`~/.ssh/id_ed25519.pub`) as a new line inside the quotes of `AUTHORIZED_KEYS` in `.env`, with a comment naming the machine. Then run `./deploy.sh`.
4. Run `ssh ssh.berkslv.com` and log in with your email code.

To revoke a machine, delete its line and redeploy. Don't edit `~/.ssh/authorized_keys` by hand on the host or in the container: both are rewritten from `.env` (on deploy and on container start). Avoid copying one private key between machines, so each machine can be revoked on its own.

## Management (on the Pi)

```bash
cd /opt/home-server
sudo docker compose logs -f
sudo docker compose up -d --build     # rebuild the agent image
ssh -p 2222 agent@localhost           # or: sudo docker exec -it -u agent agent bash
sudo docker restart agent             # restart the Hermes gateway (e.g. after `hermes setup`)

systemctl status cloudflared
journalctl -u cloudflared -f
sudo apt update && sudo apt install --only-upgrade cloudflared && sudo systemctl restart cloudflared
```

Changing keys: edit `AUTHORIZED_KEYS` in `.env` and redeploy; deploy rewrites the host's `authorized_keys` and the entrypoint rewrites the container's on start.

GitHub: set `GH_TOKEN` (fine-grained PAT), `GIT_USER_NAME` and `GIT_USER_EMAIL` in `.env` and redeploy. The entrypoint logs `gh` in with the token and configures git to use it, so `gh` and `git push` work in SSH sessions. Rotate by replacing the token and redeploying.

## Notes

- The agent container has no Docker socket. Mounting `/var/run/docker.sock` would give it root on the host.
- On the LAN you can skip Cloudflare: `ssh berkslv@192.168.1.106`, and for the agent `ssh -J berkslv@192.168.1.106 -p 2222 agent@localhost`.
- The host sshd still accepts passwords on the LAN; Cloudflare Access gates the public hostname.
