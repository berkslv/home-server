---
name: update-home-server
description: Update the Raspberry Pi home server - Ubuntu/apt packages (incl. cloudflared), Immich (server + ML, and the Mac ML server), the agent container image (Claude Code, Node, gh, opencode), then verify health and re-baseline the security check. Use when asked to update, upgrade, patch, or "check for updates" on the Pi, Immich, cloudflared or the agent.
---

# Update the home server

Monthly routine, ~30 min of mostly waiting. Read [AGENTS.md](../../../AGENTS.md) first: everything here needs
sudo (the owner's password; never NOPASSWD, never store it), and the hard rules apply.

## 0. Survey (read-only, no sudo needed for most)

```bash
apt list --upgradable 2>/dev/null | tail -n +2           # pending apt packages
[ -f /var/run/reboot-required ] && cat /var/run/reboot-required.pkgs   # reboot pending?
curl -s localhost:2283/api/server/version                # running Immich
curl -s https://api.github.com/repos/immich-app/immich/releases/latest | jq -r '.tag_name, .published_at'
cloudflared --version | head -1
sudo docker exec -u agent agent bash -lc 'claude --version; opencode --version'
```

Report what's pending to the owner and **get a go-ahead**: restarting cloudflared or Immich is outward-facing.

## 1. Safety net

```bash
F=/opt/immich/library/backups/manual-pre-<version>-$(date +%Y%m%dT%H%M).sql.gz
sudo bash -c "docker exec immich_postgres pg_dump --clean --if-exists -U postgres immich | gzip > $F && gzip -t $F"
sudo journalctl -u immich-backup -n 3 -o cat          # last R2 backup succeeded?
```

Avoid the minutes around :00 (pi-health) and :30 (pi-security) for restarts, or pause the checks in healthchecks.io.

## 2. apt packages (incl. cloudflared)

```bash
sudo apt-get update && sudo apt-get -s full-upgrade | grep -E '^(Inst|Remv)'    # review: nothing important removed?
sudo systemd-run --unit=apt-upgrade --collect --wait -p StandardOutput=journal -E DEBIAN_FRONTEND=noninteractive \
  apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
sudo dpkg --audit                                        # must print nothing
curl -s -o /dev/null -w '%{http_code}\n' localhost:20241/ready   # 200 = tunnel back
```

- **The cloudflared package restarts the tunnel itself.** Every SSH session that comes through
  `ssh.berkslv.com` drops, and so does any command running in it. That's why the upgrade runs in a
  `systemd-run` unit: it survives the drop. Prefer doing this from the LAN (`ssh berkslv@192.168.1.100`).
- Ubuntu security updates also install automatically every morning (unattended-upgrades); cloudflared does not.

## 3. Immich

1. Read the release notes for **every** version between the running one and the target
   (`https://github.com/immich-app/immich/releases`). Stop and ask the owner on anything marked breaking,
   manual migration steps, or a postgres/vectorchord change.
2. Compare images with the release's compose file:
   ```bash
   curl -sL https://github.com/immich-app/immich/releases/download/<vX.Y.Z>/docker-compose.yml | grep image:
   grep image: immich/docker-compose.yml
   ```
   Update the `immich-server` / `immich-machine-learning` tags (and the valkey/postgres digests only if they
   changed). Keep our local changes: the ML `cpus: 1.0` / `cpu_shares` cap, `MACHINE_LEARNING_*` env, and the
   `/opt/immich` paths. Update the version in the file's header comment too.
3. Pull (no downtime), then recreate (~1 min downtime):
   ```bash
   alias immich='sudo docker compose -f /opt/home-server/immich/docker-compose.yml --env-file /opt/immich/.env'
   sudo systemd-run --unit=immich-pull --collect --wait docker compose -f /opt/home-server/immich/docker-compose.yml --env-file /opt/immich/.env pull -q
   sudo systemd-run --unit=immich-up --collect --wait docker compose -f /opt/home-server/immich/docker-compose.yml --env-file /opt/immich/.env up -d --remove-orphans
   curl -s localhost:2283/api/server/version          # new version; ping may take ~40 s
   sudo docker logs --since 5m immich_server 2>&1 | grep -iE 'error|migration'
   ```
4. **Mac ML server** must match the version. Tell the owner to run on the Mac:
   ```bash
   docker rm -f immich-ml && docker run -d --name immich-ml --restart unless-stopped -p 3003:3003 \
     -v immich-model-cache:/cache -e MACHINE_LEARNING_MODEL_REVISION=v2 \
     ghcr.io/immich-app/immich-machine-learning:<vX.Y.Z>
   ```
   (The Pi's own ML container is the fallback; nothing breaks while the Mac is off.)
5. Rollback: put the old tag back and `up -d`. If a migration broke the DB, restore the dump from step 1
   (docs/immich-operations.md §5 step 4).

## 4. Agent container (Claude Code, Node, gh, uv, opencode)

The image is built locally from `agent/Dockerfile`; Claude Code, Node, gh and uv are unpinned, so a clean
rebuild gets their latest versions. opencode is pinned (`OPENCODE_VERSION`): bump it deliberately.

```bash
cd /opt/home-server
sudo systemd-run --unit=agent-rebuild --collect --wait -p WorkingDirectory=/opt/home-server \
  docker compose --env-file /etc/home-server/.env build --pull --no-cache agent      # 10-30 min on the Pi
sudo docker compose --env-file /etc/home-server/.env up -d agent                      # recreate: drops agent sessions
```

- Recreating kills running agent sessions (tmux in the container). Warn the owner first.
- `/home/agent` is a volume, kept across rebuilds.

## 5. Clean up, verify, record

```bash
sudo docker image prune -f                     # dangling images from the rebuild
sudo docker builder prune -f --filter until=168h
sudo docker rmi ghcr.io/immich-app/immich-server:<old> ghcr.io/immich-app/immich-machine-learning:<old>
sudo pi-health --dry-run                       # must be ALL OK (cpu temp may be high right after)
sudo pi-security --dry-run                     # will show CHANGED: containers (new tags), files (apt), maybe ports
```

- Review every `pi-security` CHANGED line: each must be explained by this update (new image tags, files
  touched by the upgraded packages). Then `sudo pi-security --accept`. Anything unexplained: stop and tell the owner.
- If `/var/run/reboot-required` exists, tell the owner a reboot is needed (`sudo reboot`; everything comes
  back on its own: containers `unless-stopped`, timers `Persistent=true`). Don't reboot without a go-ahead.
- Commit the changed files (`immich/docker-compose.yml`, `agent/Dockerfile`) with the versions in the
  message, and add a line to the update log in `docs/immich-operations.md` §6. Follow the git workflow in
  AGENTS.md (`/opt/home-server` is not a git repo).
- Delete the manual pre-upgrade dump after a few days once the nightly R2 backup has run.
