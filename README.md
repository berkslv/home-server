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

GitHub: set `GH_TOKEN` (fine-grained PAT), `GIT_USER_NAME` and `GIT_USER_EMAIL` in `.env` and redeploy. The entrypoint logs `gh` in with the token and configures git to use it, so `gh` and `git push` work in SSH sessions and jobs. Rotate by replacing the token and redeploying.

## Scheduled agent jobs (agent-cron)

Jobs are GitHub issues in a private repo (`JOBS_REPO`), run by [opencode](https://opencode.ai) through OpenRouter. The scheduler runs inside the agent container in its own tmux server; every run gets its own tmux window you can watch or take over.

```
GitHub issue (label agent-job) ──sync──▶ agent-cron daemon ──tmux window──▶ agent-cron exec ──▶ opencode run
                ▲                                                                   │
                └──────────── result comment ◀──────────────────────────────────────┴──▶ email (Resend)
```

### A job

Open an issue in the jobs repo, label it `agent-job`. The first fenced `yaml` block is the config, everything else is the prompt:

````markdown
```yaml
schedule: "0 8 * * 1-5"      # cron, in TZ (Europe/Istanbul)
timeout: 30m                 # 90s, 30m, 2h (default 30m)
steps: 25                    # max agent steps (default 30)
model: openrouter/...        # default OPENCODE_MODEL
workdir: berkslv/some-repo   # optional: fresh worktree of this repo per run; otherwise a persistent scratch dir
notify: failure              # email: failure | always | never
permission:                  # optional opencode permissions, merged over the defaults
  bash:
    "*": allow
    "rm -rf *": deny
```

Check for outdated npm dependencies and open a PR with safe patch updates.
````

- Only open issues **opened by `JOBS_OWNER`** count; the scheduler refuses to start on a public repo.
- Issues are synced every 10 minutes (`JOBS_SYNC_INTERVAL`, seconds); `/run` comments are checked every 30 s (`JOBS_COMMENT_POLL`).
- After an edit the scheduler replies with the parsed schedule and next run (or the parse error).
- Each run posts a comment with status, duration, tokens, cost and the agent's summary.
- Comment `/run` (as the owner) to run now. Close the issue or remove the label to disable: the scheduler re-checks the issue on GitHub right before every run, so a closed job never starts (the next sync also drops its schedule).
- A run that would overlap a still-running one is skipped (and notified).
- Default permissions: everything allowed, including files outside the working directory. Only `question`, `plan_enter` and `plan_exit` are denied, since a headless run would wait for an answer until it times out. A job's `permission` block is merged over these.
- Runs missed while the Pi was off are not caught up.

### CLI (over SSH)

```bash
agent-cron list              # jobs, next and last runs
agent-cron status            # scheduler health, running/queued runs
agent-cron sync              # sync issues now instead of waiting up to 10 minutes
agent-cron run 12            # run issue #12 now
agent-cron attach 7          # watch run 7 live (Ctrl-b d to detach)
agent-cron logs 7 [-f]
agent-cron history 12
agent-cron stop 7
agent-cron restart           # restart the scheduler; running jobs keep going
```

State (SQLite, logs, repo clones, scratch dirs) lives in `~/.agent-cron` on the home volume.

### Setup

1. Create a **private** repo (e.g. `berkslv/agent-jobs`) and an `agent-job` label in it.
2. Give the GitHub token **Issues: Read and write** on it.
3. Set in `.env`: `JOBS_REPO`, `JOBS_OWNER`, `OPENCODE_MODEL` (e.g. `openrouter/<model>`), `OPENROUTER_API_KEY`, and for email notifications `RESEND_API_KEY`, `NOTIFICATION_EMAIL` and optionally `RESEND_FROM` (a sender on a domain verified in Resend; the default `onboarding@resend.dev` can only email your own Resend account address).
4. `./deploy.sh`

## Notes

- The agent container has no Docker socket. Mounting `/var/run/docker.sock` would give it root on the host.
- For direct LAN access without Cloudflare, uncomment `ports: 2222:22` on the agent service.
