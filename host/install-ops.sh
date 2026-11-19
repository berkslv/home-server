#!/bin/bash
#
# Install/update the ops tooling from this repo onto the host. Run as root; called by
# host/setup.sh on every deploy, safe to run on its own. Idempotent.
#   backup/immich-backup        -> /usr/local/sbin/immich-backup        + immich-backup.{service,timer}
#   backup/restore-test         -> /usr/local/sbin/immich-restore-test
#   health/pi-health            -> /usr/local/sbin/pi-health            + pi-health.{service,timer}
#
# Secrets are never in the repo. Timers are only enabled once their secret files exist:
#   /etc/restic/r2.env, /etc/restic/password   (backup)
#   /etc/pi-health.env                         (health check)
# See docs/immich-operations.md §4, §7.
#
# Usage: sudo ./host/install-ops.sh
#
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
log()  { echo -e "\033[0;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $*"; }

# Packages
missing=()
command -v restic   >/dev/null || missing+=(restic)
command -v smartctl >/dev/null || missing+=(smartmontools)
if [ ${#missing[@]} -gt 0 ]; then
    log "Installing ${missing[*]}"
    apt-get update
    apt-get install -y --no-install-recommends "${missing[@]}"
fi

# Replace a script atomically: a running bash script must never be overwritten in place
put() {  # put <src> <dest> <mode>
    if ! cmp -s "$1" "$2"; then
        install -m "$3" -o root -g root "$1" "$2.new" && mv -f "$2.new" "$2"
        log "updated $2"
    fi
}

put "$DIR/backup/immich-backup" /usr/local/sbin/immich-backup       700
put "$DIR/backup/restore-test"  /usr/local/sbin/immich-restore-test 700
put "$DIR/health/pi-health"     /usr/local/sbin/pi-health           700
for u in backup/immich-backup.service backup/immich-backup.timer health/pi-health.service health/pi-health.timer; do
    put "$DIR/$u" "/etc/systemd/system/$(basename "$u")" 644
done
install -d -m 700 /etc/restic /var/lib/immich-backup /var/cache/restic
systemctl daemon-reload

# Enable timers only when their secrets are present (never start a backup from here)
if [ -s /etc/restic/r2.env ] && [ -s /etc/restic/password ]; then
    systemctl enable --now immich-backup.timer >/dev/null
    log "immich-backup.timer: $(systemctl is-active immich-backup.timer)"
else
    warn "R2 backup NOT enabled: create /etc/restic/r2.env and /etc/restic/password (docs §5 step 3)"
fi
if [ -s /etc/pi-health.env ]; then
    systemctl enable --now pi-health.timer >/dev/null
    log "pi-health.timer: $(systemctl is-active pi-health.timer)"
else
    warn "Health check NOT enabled: create /etc/pi-health.env with HC_URL=https://hc-ping.com/<uuid> (docs §7)"
fi
