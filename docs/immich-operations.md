# Immich operations

The reference for the Immich install on the Pi: how it's laid out, how the Google Photos library got in, and how backup and restore work. The README covers the first deploy. This file covers everything after it.

This file never contains secrets. Each one is listed by where it lives.

---

## 1. Layout

| | |
|---|---|
| Host | Raspberry Pi 4, 8 GB, Ubuntu, 459 GB USB SSD (`/dev/sda2`), LAN `192.168.1.100` |
| Immich | v3.4.1, compose project `immich`, started from `/opt/home-server/immich/docker-compose.yml` with `--env-file /opt/immich/.env` |
| URLs | `https://immich.berkslv.com` (Cloudflare Access), `http://192.168.1.100:2283` (LAN) |
| Isolation | `/opt/immich` is `root:root 700`. `berkslv` is **not** in the `docker` or `lxd` groups (both are root-equivalent), so the user, agents and the `agent` container can't read the library without sudo. Never put Immich data or secrets in this repo, and never add those groups back. |

### Paths on the Pi

| Path | What | Backed up to R2 |
|---|---|---|
| `/opt/immich/.env` | DB password, DB name/user, TZ (root 600) | no. Recreate on rebuild; see §6. |
| `/opt/immich/library/library/` | originals, sorted by the storage template `{{y}}/{{MM}}/{{dd}}/{{filename}}` | **yes** |
| `/opt/immich/library/upload/` | uploads not yet moved by the template | **yes** |
| `/opt/immich/library/backups/` | Immich's nightly DB dumps (`immich-db-backup-<ts>-v3.4.1-pg14.19.sql.gz`, 02:00) | **yes** |
| `/opt/immich/library/profile/` | profile pictures | **yes** |
| `/opt/immich/library/thumbs/` | thumbnails and previews (~9 GB) | no, regenerable |
| `/opt/immich/library/encoded-video/` | transcoded videos (~36 GB) | no, regenerable (~1 day of CPU) |
| `/opt/immich/postgres/` | live database files | no. Use the dumps; copying a running DB is unsafe. |
| `/etc/restic/` | R2 credentials and the restic password (root 600) | no. Keep the password in a password manager. |
| `/etc/pi-health.env` | healthchecks.io ping URL (root 600) | no. It's shown in the healthchecks.io dashboard. |
| `/var/lib/immich-backup/last-success` | epoch time of the last fully successful backup run, read by `pi-health` | no |

Leftovers in `/opt/immich`, safe to delete: `docker-compose.yml` and `docker-compose.yml.bak` (the original standalone install, superseded by the repo's compose file), `import.sh`, `import-logs/`, `immich-go.env` (contains the import API key). The root tmux session `immich-import` is also a leftover.

### Managing it

```bash
cd /opt/home-server
alias immich='sudo docker compose -f immich/docker-compose.yml --env-file /opt/immich/.env'
immich ps
immich logs -f immich-server
```

---

## 2. Settings changed from the defaults

**In the compose file:**
- `immich-machine-learning` is limited to `cpus: 1.0` and `cpu_shares: 256`, with `MACHINE_LEARNING_REQUEST_THREADS=1` and `MACHINE_LEARNING_MODEL_REVISION=v2`. Without the cap, ML makes the Pi unusable.

**In Immich admin settings** (stored in the database, so they come back with a DB restore):
- **Machine Learning URLs:** `http://192.168.1.104:3003` (the M1 MacBook) first, then `http://immich-machine-learning:3003` (the Pi) as fallback. When the Mac is asleep, the Pi takes over. That's fine for day-to-day uploads.
- **Job concurrency:** face detection 1, thumbnail generation 2.
- **Storage template:** `{{y}}/{{MM}}/{{dd}}/{{filename}}`.

To run ML on the Mac again for a large batch, start the `immich-machine-learning` container there with the same version tag and port 3003 published to the LAN. Video transcoding always runs on the Pi; it can't be offloaded.

---

## 3. History: the Google Photos migration (2026-11-13 → 11-17)

1. **Download.** Google Takeout: 13 `.tgz` files, 112 GiB, on Google Drive. Downloaded with `rclone copy gdrive:Takeout` and verified with `rclone check --one-way` (MD5). Took about 3.5 h on an 80 Mbit line.
2. **Extract.** immich-go v0.32.0 can't read `.tgz`, so the archives were extracted first.
3. **Import.** Ran `immich-go upload from-google-photos --on-errors=continue --concurrent-tasks=4 --include-unmatched` against `http://localhost:2283`, not through Cloudflare, which rejects bodies over 100 MB. It used a temporary API key, after a dry run. Took about 2 h (~16 MB/s, limited by SSD writes).
   - Result: **27,586 assets** (24,934 images, 2,652 videos, 1,257 of them Live Photo motion clips), 112.3 GB.
   - 0 upload errors and 231 duplicates skipped.
   - No albums, because the Takeout only had year folders.
4. **Processing:** about 3 days in total.
   - Thumbnails, CLIP search, faces and OCR finished on ~11-16, with ML mostly on the Mac.
   - **630 people** detected.
   - Video transcoding: 1,052 videos, finished 11-17 10:12. This step kept the Pi at 100% CPU and ~87 °C.
5. **Known gaps:**
   - 9 JPGs never got a thumbnail and are probably damaged in the Takeout: `NCXF2056.JPG`, `JWWP5936.JPG`, `TZDM5228.JPG`, `CNMX8706.JPG`, `f519a9cf-63fe-4379-9ced-1265e638cc8e.jpg`, `FDAY2207.JPG`, `IXBO0337.JPG`, `JUWI9385.JPG`, `OEHD5634.JPG`.
   - The 1,257 hidden Live Photo clips have no thumbnails by design.
6. **Cleanup.** The downloaded and extracted Takeout files were deleted afterwards.

**To-do from the migration:**
- [ ] Delete the `import` API key (Account Settings → API Keys) and `/opt/immich/immich-go.env`.
- [ ] Remove the leftovers listed in §1.
- [ ] Change the sudo password. It was shared in an AI chat session.

---

## 4. Off-site backup: restic → Cloudflare R2

Set up on 2026-11-17. Copies of the script and units are in `backup/` in this repo (no secrets). **`host/setup.sh` doesn't install them yet**, so on a rebuild install them by hand (§5 step 3).

| | |
|---|---|
| Tool | restic 0.19.1 (Ubuntu package) |
| Target | R2 bucket `immich-backup`, Standard storage class, repo id `4e530ef5ef` |
| Credentials | `/etc/restic/r2.env`: `R2_ACCOUNT_ID`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `R2_BUCKET`. The R2 API token has Object Read & Write on **this bucket only**. |
| Encryption | `/etc/restic/password`, randomly generated. **Copy it to the password manager.** Without it the backup can't be decrypted. |
| Script | `/usr/local/sbin/immich-backup` (root 700) |
| Schedule | `immich-backup.timer`: daily at 03:00 (+ up to 10 min random), `Persistent=true`, so a missed run happens at the next boot. This is one hour after Immich's 02:00 DB dump. |
| Service | `immich-backup.service`: oneshot, `Nice=10`, idle I/O priority. It can't overlap with itself. |
| Upload cap | 1500 KiB/s (`LIMIT_UP`), so the 20 Mbit uplink stays usable |

**What each run does:**
1. `restic backup` of `library/library`, `library/upload`, `library/backups` and `library/profile`.
2. `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12`, which keeps about **one year** of history.
3. **Sundays:** `restic prune --max-unused 10%`.
4. **On the 1st of each month:** `restic check --read-data-subset 5%`. R2 egress is free.
5. Writes the current time to `/var/lib/immich-backup/last-success`, which `pi-health` uses to check the backup's age.

### Cost

- About 121 GB stored. R2 Standard is $0.015 per GB-month with the first 10 GB free, so about **$1.67 a month, ~$20 a year**.
- Operations stay within the free tier, and egress (restores) is free.
- Each extra 10 GB of photos adds about $0.15 a month.
- Retention barely affects cost, because restic deduplicates. Only deleted photos still held by old snapshots cost extra.
- **Don't use Infrequent Access.** It would save about $5 a year, but adds retrieval fees, a 30-day minimum storage time, and no free tier.
- **Why daily and not weekly:** it costs the same and means at most one day of photos is at risk.

### Commands

```bash
sudo journalctl -u immich-backup -f                  # follow the current or last run
systemctl list-timers immich-backup.timer            # next run
sudo systemctl start immich-backup.service           # run now
sudo immich-backup restic snapshots                  # any restic command, with the env loaded
sudo immich-backup restic stats --mode raw-data      # bytes actually stored in R2
sudo immich-backup restic ls latest /opt/immich/library/backups
```

The first full upload ran 2026-11-17 11:22 → 2026-11-18 09:33 (22 h, 114.7 GiB).
Nightly runs after that only upload what's new (2026-11-19: +8.8 GiB in 1 h 43 min).

**Restore tests**

| Date | Snapshot | Sample | Result |
|---|---|---|---|
| 2026-11-19 | 3d8094bb | 65 originals (heic/jpg/png/mov/mp4) + newest DB dump, 353 MiB in 42 s | PASS: all byte-identical, dump gzip OK (85 tables) |

Run it again with `sudo immich-restore-test` (repo: `backup/restore-test`). It restores a random
sample from the latest snapshot into a root-only temporary folder, compares it with the live files
and deletes it again. `sudo N=200 immich-restore-test` for a bigger sample.

### Restore a few files (test, or recover something deleted)

```bash
sudo immich-backup restic snapshots
sudo immich-backup restic find 'IMG_1234*'
sudo mkdir -m 700 /root/restore-test
sudo immich-backup restic restore latest --target /root/restore-test \
     --include /opt/immich/library/library/2019/07
sudo diff -r /root/restore-test/opt/immich/library/library/2019/07 /opt/immich/library/library/2019/07
sudo rm -rf /root/restore-test
```

To bring back a photo that was deleted in Immich: restore the file, then upload it again through the app or `immich-go`. Its metadata (people, album membership) only comes back with a full DB restore.

---

## 5. Disaster recovery: the SSD or Pi is lost

**You need:**
- this repo;
- the restic password (password manager);
- an R2 token for the bucket (make a new one in the dashboard if the old one is lost);
- the same Immich version as the dump file name (`-v3.4.1-`).

1. **Rebuild the host.** Install Ubuntu, then run `./deploy.sh` from the laptop. That gives Docker, cloudflared, `/opt/immich` and a **new** `/opt/immich/.env`.
2. **Stop Immich** before restoring: `immich down`.
3. **Restore the files:**
   ```bash
   sudo apt install restic
   sudo install -d -m 700 /etc/restic
   sudoedit /etc/restic/r2.env      # R2_ACCOUNT_ID, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, R2_BUCKET=immich-backup
   sudoedit /etc/restic/password    # the password, no trailing newline needed
   sudo chmod 600 /etc/restic/*
   sudo install -m 700 /opt/home-server/backup/immich-backup /usr/local/sbin/
   sudo install -m 644 /opt/home-server/backup/immich-backup.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo immich-backup restic snapshots
   sudo immich-backup restic restore latest --target /     # writes back to /opt/immich/library/...
   ```
   At ~9 MB/s download, 121 GB takes about 4 h.
4. **Restore the database** from the newest dump. This follows Immich's documented manual restore:
   ```bash
   cd /opt/home-server
   immich down -v                       # postgres dir must be empty: sudo rm -rf /opt/immich/postgres/*
   immich pull && immich create
   sudo docker start immich_postgres && sleep 10
   DUMP=$(sudo ls -1 /opt/immich/library/backups/immich-db-backup-*.sql.gz | tail -1)
   sudo gunzip --stdout "$DUMP" \
     | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
     | sudo docker exec -i immich_postgres psql --dbname=postgres --username=postgres
   immich up -d
   ```
5. **Finish up:**
   - Immich regenerates thumbnails and transcoded videos. Run *Administration → Jobs → Generate Thumbnails / Transcode Videos → Missing*. Expect about 1–2 days of CPU on the Pi.
   - ML results are in the dump, so search, faces and people don't need re-running.
6. **Re-enable the backup timer:** `sudo systemctl enable --now immich-backup.timer`.

---

## 6. Maintenance checklist

- **Upgrading Immich:**
  - Read the release notes, bump the tags and digests in `immich/docker-compose.yml`, then deploy.
  - Re-apply the ML CPU limits if you copy a fresh upstream file.
  - Dumps are version-tagged. After a major upgrade, let one nightly dump and one R2 backup run before deleting anything old.
- **Monthly:**
  - `sudo journalctl -u immich-backup --since -2d` shows the run succeeded.
  - `restic snapshots` shows a recent snapshot.
  - Check disk space with `df -h /`.
- **Twice a year:** `sudo immich-restore-test` and add a row to the restore-test table (§4).
- **Temperature:** the Pi runs at 85 °C+ under transcoding and throttles itself. A fan case helps.

---

## 7. Monitoring: pi-health → healthchecks.io

Set up on 2026-11-17. The files are in `health/` in this repo. Like the backup, it's installed by hand and not by `host/setup.sh`.

**How it works.** `pi-health.timer` runs `/usr/local/sbin/pi-health` (as root) every hour and 5 minutes after boot. It reports to the healthchecks.io check **`pi-health`** (period 1 h, grace 30 min). Alerts go by email to the account address.

- **Everything OK:** the script pings `$HC_URL`, and the report becomes the ping body (visible in the dashboard).
- **Anything fails:** the script pings `$HC_URL/fail`. healthchecks.io emails **"DOWN"** with the report, then **"UP"** when it recovers. It only emails on changes, never every hour.
- **No ping for 1 h 30 min:** the Pi is dead, offline or frozen, so healthchecks.io emails "DOWN". A monitor on the Pi alone couldn't catch this case.

**What it checks:**

| Check | Fails when |
|---|---|
| containers `immich_server`, `immich_machine_learning`, `immich_postgres`, `immich_redis`, `agent` | not running, or unhealthy |
| Immich API `localhost:2283/api/server/ping` | no `pong` |
| `cloudflared` service and `localhost:20241/ready` (tunnel connected to the edge) | inactive, or not ready |
| public `https://immich.berkslv.com/api/server/ping`, using the Access service token from `/opt/home-server/.env` | no `pong` end to end |
| disk `/` | 85% or more used |
| memory | under 5% available |
| CPU temperature | 80 °C or more. This can happen during heavy jobs, such as transcoding after an upgrade. |
| kernel log | under-voltage in the last hour |
| SSD SMART (`smartctl -H /dev/sda`) | not PASSED |
| newest Immich DB dump | 26 h or older |
| R2 backup | last run failed, `last-success` is 36 h or older, or the backup timer is inactive |

The Mac ML server isn't checked; it's often off on purpose. The limits are at the top of the script.

**Commands:**

```bash
sudo pi-health --dry-run                       # run all checks, print, don't ping
sudo systemctl start pi-health.service         # run now and ping
systemctl list-timers pi-health.timer
sudo journalctl -u pi-health -n 30
```

**Install on a rebuilt host:**

```bash
sudo apt install --no-install-recommends smartmontools
sudo install -m 700 /opt/home-server/health/pi-health /usr/local/sbin/
sudo install -m 644 /opt/home-server/health/pi-health.{service,timer} /etc/systemd/system/
sudoedit /etc/pi-health.env          # HC_URL=https://hc-ping.com/<uuid>   (from the healthchecks.io dashboard)
sudo chmod 600 /etc/pi-health.env
sudo systemctl daemon-reload && sudo systemctl enable --now pi-health.timer
```

**Planned downtime** (an upgrade, a move): pause the check in the healthchecks.io dashboard first, then resume it afterwards.
