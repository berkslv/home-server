# Guidance for AI agents (Claude Code, opencode, Hermes) working on this home server

Read this first. Details live in [README.md](README.md) (first deploy, SSH, Cloudflare) and
[docs/immich-operations.md](docs/immich-operations.md) (Immich, backup, restore, monitoring, alerts).

## What this is

Raspberry Pi 4 (aarch64, Ubuntu, 459 GB USB SSD, LAN `192.168.1.100`, user `berkslv`) running:
- **Immich** (photo library, ~30k assets) at `https://immich.berkslv.com` (Cloudflare Access) and `http://192.168.1.100:2283`
- **agent** container (Claude Code / opencode / Hermes) on `127.0.0.1:2222`
- **cloudflared** systemd service (Tunnel; no router ports open)
- **restic → Cloudflare R2** nightly backup, **pi-health** hourly check → healthchecks.io (emails the owner)
- **pi-security** hourly intrusion check → its own healthchecks.io check (docs §11)

## Hard rules

1. **The photo library is private from agents.** `/opt/immich` is `root:root 700`. `berkslv` is deliberately
   **not** in the `docker` or `lxd` groups (both are root-equivalent). Never add them back, never mount
   `/opt/immich` or the Docker socket into the agent container, never copy photos or DB dumps somewhere
   `berkslv` can read. Restore tests go into a root-only folder and are deleted afterwards.
2. **Never print or commit secrets.** Refer to them by path only (table below). Don't `cat` them, don't
   echo them into logs, don't paste them into commit messages or chat.
3. **sudo needs the owner's password.** There is no NOPASSWD and there must never be one. If you don't have
   sudo, say what command the owner should run instead of working around it.
4. **Don't change the backup schedule or retention** (daily 03:00; keep 7 daily / 4 weekly / 12 monthly).
   The owner decided this explicitly.
5. **After any legitimate system change** (deploy, package/user/key/port/container change, Immich upgrade), `pi-security`
   will report it every hour until someone checks it and runs `sudo pi-security --accept`. Tell the owner, don't
   accept silently on their behalf unless they asked for the change.
6. **Ask before** deleting anything under `/opt/immich`, running `restic forget/prune` by hand, upgrading
   Immich, restarting cloudflared (cuts remote access), or touching sshd config.

## Where the source of truth is

- **GitHub `berkslv/home-server`** is the source. The owner edits on the Mac and runs `./deploy.sh`, which
  rsyncs to `/opt/home-server` **with `--delete`** and runs `host/setup.sh` (which runs `host/install-ops.sh`).
- **`/opt/home-server` on the Pi is a deployed copy, not a git repo.** Editing it directly is lost on the
  next deploy. To change something from the Pi: clone to a temp dir, edit, commit, push, delete the clone,
  then copy the changed files into `/opt/home-server` (and install them, e.g. `sudo host/install-ops.sh`)
  so the Pi matches. Tell the owner to `git pull` on the Mac before the next deploy.
- Commits: author `Berk Selvi`, the owner's GitHub email; push to `main` only when asked.
- After any change to the system, **update `docs/immich-operations.md`** (or the README) in the same commit.
  The owner does not keep chat history; the repo is the memory.

## Secrets: where they live (never in git)

| Secret | Path (root 600) | Recovery |
|---|---|---|
| Tunnel token, SSH keys, Access service token `immich-app`, GH token, API keys | Mac: `home-server/.env`. Pi: `/etc/home-server/.env` (root 600, put there by deploy). **Never** in `/opt/home-server`. | `cloudflare/setup.sh` re-creates |
| Immich DB password | `/opt/immich/.env` | new one on rebuild |
| R2 keys | `/etc/restic/r2.env` | new token in Cloudflare dashboard (R2 → bucket `immich-backup` only) |
| restic repo password | `/etc/restic/password` | **owner's password manager only. Lost = backup unreadable.** |
| healthchecks.io ping URLs (`HC_URL`, `HC_SECURITY_URL`) | `/etc/pi-health.env` | healthchecks.io dashboard |
| cloudflared token | `/etc/cloudflared/tunnel.env` | written from `.env` by setup.sh |

## Common tasks (all need sudo)

```bash
sudo pi-health --dry-run                         # full status in one go (17 checks)
sudo pi-security --dry-run                       # intrusion check; --accept after a verified change
sudo journalctl -u immich-backup -n 30           # last backup run
sudo immich-backup restic snapshots              # any restic command with env loaded
sudo immich-restore-test                         # restore a random sample from R2 and compare
alias immich='sudo docker compose -f /opt/home-server/immich/docker-compose.yml --env-file /opt/immich/.env'
immich ps; immich logs -f immich-server
alias hs='sudo docker compose -f /opt/home-server/docker-compose.yml --env-file /etc/home-server/.env'  # agent
```

- **Alert email from healthchecks.io:** docs §8 has a table per failing check.
- **Upgrade Immich:** docs §6. Pause the `pi-health` check in healthchecks.io first.
- **Recover a deleted photo:** Immich trash first (30 days), then restic (docs §4).
- **Disk dead / Pi lost:** docs §5.
- **Big upload batch / ML queue:** start the Mac ML server (docs §2); otherwise the Pi does it on 1 core and runs hot.
- **Job queue sizes** without an API key:
  `sudo docker exec immich_redis redis-cli llen immich_bull:faceDetection:wait` (also `ocr`, `smartSearch`,
  `thumbnailGeneration`, `videoConversion`, `facialRecognition`, `metadataExtraction`).

## Lessons learned (don't rediscover these)

- `systemctl is-active` on a **running oneshot** prints `activating`, not `active`.
- Never overwrite a running bash script in place (bash reads it lazily). Install to a temp file and `mv`
  (`host/install-ops.sh` does this). A run that started before a swap keeps executing the old version.
- Cloudflare free plan rejects request bodies **> 100 MB**: bulk imports and big videos go to `localhost:2283`
  or the LAN URL, not the public hostname.
- Public `immich.berkslv.com` answers anonymous requests with a 302 to Cloudflare Access; scripts pass
  `CF-Access-Client-Id/Secret` from `/etc/home-server/.env`. `localhost:20241/ready` = tunnel connected to the edge.
- `vcgencmd` doesn't work on this Ubuntu; temperature is `/sys/class/thermal/thermal_zone0/temp`,
  under-voltage is in `journalctl -k`.
- Immich v3 DB: there is no `encodedVideoPath` / `isVisible` on `asset`; derived files are in `asset_file`
  (by `type`). Upload source is not a column on `asset`.
- CPU-temperature alerts (≥ 80 °C) during heavy ML or transcoding are expected; they clear by themselves.
  The real fix is a fan.
- Running `immich-machine-learning` without its CPU cap makes the Pi unusable; keep `cpus: 1.0`.
- `sshd -T` prints keys in mixed case on this Ubuntu (`PasswordAuthentication no`); compare case-insensitively.
- `50-cloud-init.conf` says `PasswordAuthentication yes`, but `00-hardening.conf` sorts first and sshd keeps the
  first value it reads, so passwords are off. Don't rename `00-hardening.conf`.
- `ufw` service is "active" but the firewall reports `Status: inactive` (no rules). Docker-published ports bypass
  ufw anyway; exposure is controlled by what listens (`pi-security` baselines it).
