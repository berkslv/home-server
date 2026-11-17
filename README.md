# Home Server

Raspberry Pi (Ubuntu Server) exposed through Cloudflare Tunnel and protected by Cloudflare Access, running a Docker-based agent box and Immich.

```
laptop ── cloudflared access ssh ──▶ Cloudflare Access (email OTP) ──▶ Tunnel ──▶ cloudflared (Pi host) ──▶ Pi sshd :22
                                                                                                        └─▶ agent container 127.0.0.1:2222
browser ─────────────────────────────▶ Cloudflare Access (email OTP) ──▶ Tunnel ──▶ cloudflared (Pi host) ──▶ Immich :2283
```

- **cloudflared** – runs on the Pi as a systemd service (not in Docker); outbound-only, no ports are opened on the router.
- **ssh.berkslv.com** – SSH into the Pi host itself, gated by an Access policy (email allowlist, one-time PIN). Also available as a browser terminal from the Access App Launcher.
- **agent** – Ubuntu 24.04 container with Node.js, Python/uv, gh, git, tmux, build tools, Claude Code, opencode and Hermes Agent. Passwordless sudo for user `agent`; `/home/agent` persists in a volume. Its sshd is published only on the Pi's `127.0.0.1:2222`, reached with a ProxyJump through the host.
- **immich.berkslv.com** – Immich photo library, behind the same Access policy. Its own compose project (`immich/`); data and the DB password live in `/opt/immich` (root-only, outside the repo dir).

## Layout

```
docker-compose.yml     agent container
agent/                 agent image (Dockerfile, sshd config, entrypoint)
immich/                Immich compose project (server, ML, postgres, valkey)
backup/                restic -> Cloudflare R2 backup script + systemd timer (installed by hand, see docs)
docs/                  docs/immich-operations.md: Immich runbook, migration history, backup & restore
host/setup.sh          on the Pi: Docker, cloudflared systemd service, host authorized_keys, /opt/immich
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
| Account | Access: Service Tokens: Edit                          |
| Account | Account Settings: Read                                |
| Zone    | DNS: Edit, Zone: Read (berkslv.com)                   |

Zero Trust must be enabled on the account once (dashboard → Zero Trust, pick a team name, free plan).

```bash
npm i -g wrangler
cp .env.example .env    # set AUTHORIZED_KEYS to your public key(s)

CLOUDFLARE_API_TOKEN=... ACCESS_EMAILS=you@example.com ./cloudflare/setup.sh
```

The script is idempotent. It creates the `home-server` tunnel with `wrangler tunnel create`, sets its ingress (`ssh` → `ssh://localhost:22`, the Pi's own sshd; `immich` → `http://localhost:2283`), creates both CNAMEs, the Access policy and one Access app per hostname, and writes `TUNNEL_TOKEN` to `.env`. The ingress is replaced on every run, so add public hostnames here rather than in the dashboard.

Optional variables: `DOMAIN`, `SSH_HOST`, `IMMICH_HOST`, `TUNNEL_NAME`, `SESSION_DURATION`, `CLOUDFLARE_ACCOUNT_ID`.

### 2. Deploy to the Pi

```bash
PI=berkslv@192.168.1.100 ./deploy.sh
```

Syncs this directory to `/opt/home-server`, then runs `host/setup.sh` as root (installs Docker and cloudflared from apt, writes the tunnel token to `/etc/cloudflared/tunnel.env`, installs the `cloudflared` systemd unit, writes `AUTHORIZED_KEYS` to the host user's `~/.ssh/authorized_keys`, creates `/opt/immich` and, on first run, `/opt/immich/.env` with a random DB password), then `docker compose up -d --build` for the agent and `docker compose -f immich/docker-compose.yml --env-file /opt/immich/.env up -d` for Immich. It asks for the sudo password.

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

## Immich

Open https://immich.berkslv.com (Access login first, then the Immich login). On the LAN it's also at http://192.168.1.100:2283.

| Path on the Pi           | What                                                        |
|--------------------------|-------------------------------------------------------------|
| `/opt/immich/.env`       | `DB_PASSWORD` and DB name/user, TZ. Root 600, never in git |
| `/opt/immich/library`    | photos, thumbs, encoded video; nightly DB dumps in `backups/` |
| `/opt/immich/postgres`   | database                                                    |
| volume `immich_model-cache` | ML models, re-downloaded if lost                         |

`/opt/immich` is root:root 700 and the host user is kept out of the `docker` group, so neither the host user nor the agent can read the library without sudo.

```bash
cd /opt/home-server
alias immich='sudo docker compose -f immich/docker-compose.yml --env-file /opt/immich/.env'
immich ps
immich logs -f immich-server
```

Upgrading: bump the image tags (and the postgres/valkey digests) in `immich/docker-compose.yml` from the new release's compose file, read the release notes, redeploy.

Limits:
- The Immich mobile app can't do the Access email login, so `cloudflare/setup.sh` creates an Access service token (`immich-app`) allowed on the Immich app and writes it to `.env` as `IMMICH_ACCESS_CLIENT_ID` / `IMMICH_ACCESS_CLIENT_SECRET`. In the app: login screen → settings gear → Advanced → Custom proxy headers, add `CF-Access-Client-Id` and `CF-Access-Client-Secret` with those values. To rotate, delete `IMMICH_ACCESS_CLIENT_SECRET` from `.env`, re-run the script and update the app.
- Cloudflare rejects request bodies over 100 MB on the free plan, so large videos and bulk imports (Google Takeout via `immich-go`) should go to `http://localhost:2283` on the Pi or the LAN URL.
- Off-site backup: nightly restic to Cloudflare R2 (03:00, keeps ~1 year). Setup, costs, restore and disaster recovery are in [docs/immich-operations.md](docs/immich-operations.md).

## Notes

- Nothing in `/opt/immich` is managed by rsync, so `deploy.sh --delete` never touches photos or the database.
- The agent container has no Docker socket. Mounting `/var/run/docker.sock` would give it root on the host.
- On the LAN you can skip Cloudflare: `ssh berkslv@192.168.1.100`, and for the agent `ssh -J berkslv@192.168.1.100 -p 2222 agent@localhost`.
- The host sshd still accepts passwords on the LAN; Cloudflare Access gates the public hostname.
