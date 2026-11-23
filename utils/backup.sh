#!/bin/sh
#
# Vaultwarden backup script (runs under crond inside the rclone/rclone container).
#
# Backs up the items listed in https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault
# into a single zip with paths relative to the data folder, so a restore is just
# "unzip into an empty data folder":
#
#   db.sqlite3     consistent snapshot via VACUUM INTO, integrity-checked
#   attachments/   (if present)
#   sends/         (if present)
#   config.json    (if present; admin page settings)
#   rsa_key*       (login token signing key)
#
# The zip is then copied (never `sync`ed) to an rclone remote, ideally a `crypt`
# remote, and old backups are pruned locally and remotely by age.
#
# Environment:
#   BACKUP_ENABLED                 "false" to skip (default: true)
#   BACKUP_DIR                     local backup folder (required)
#   BACKUP_DATA_DIR                Vaultwarden data folder (required)
#   BACKUP_RETENTION_DAYS          delete backups older than this, local + remote (default: 30)
#   BACKUP_RCLONE_CONFIG           rclone config path
#   BACKUP_RCLONE_REMOTE_NAME      rclone remote; leave empty for local-only backups
#   BACKUP_RCLONE_REMOTE_PATH      path inside the remote (may be empty)
#   BACKUP_HEALTHCHECK_URL         optional healthchecks.io-style URL; pinged on
#                                  start (/start), success, and failure (/fail)

set -eu

# Under crond, job output is discarded; send it to the container log instead
# so it shows up in `docker compose logs rclone`.
if [ -w /proc/1/fd/1 ]; then
    exec >>/proc/1/fd/1 2>&1
fi

log() { echo "[backup $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

ping_hc() {
    [ -n "${BACKUP_HEALTHCHECK_URL:-}" ] || return 0
    wget -q -T 10 -O /dev/null "${BACKUP_HEALTHCHECK_URL}$1" 2>/dev/null || log "WARN: healthcheck ping failed"
}

fail() {
    log "ERROR: $*"
    ping_hc /fail
    exit 1
}

if [ "${BACKUP_ENABLED:-true}" = false ]; then
    log "Backup disabled; exiting"
    exit 0
fi

[ -n "${BACKUP_DIR:-}" ] || fail "BACKUP_DIR not defined"
[ -n "${BACKUP_DATA_DIR:-}" ] || fail "BACKUP_DATA_DIR not defined"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
case "$RETENTION_DAYS" in '' | *[!0-9]*) fail "BACKUP_RETENTION_DAYS must be a number" ;; esac

for cmd in sqlite3 zip unzip; do
    command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' not installed"
done

mkdir -p "$BACKUP_DIR"

# Prevent overlapping runs (e.g. a slow upload with the 15min schedule)
exec 9>"${BACKUP_DIR}/.backup.lock"
flock -n 9 || fail "another backup is still running"

ping_hc /start
log "Starting backup"

TMP_DIR="$(mktemp -d "${BACKUP_DIR}/.tmp.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

NAME="vaultwarden_backup.$(date '+%Y-%m-%d_%H%M%S').zip"
TMP_ZIP="${TMP_DIR}/${NAME}"

# --- Database (required) ---
DB="${BACKUP_DATA_DIR}/db.sqlite3"
[ -f "$DB" ] || fail "database not found at $DB"
sqlite3 -cmd ".timeout 30000" "$DB" "VACUUM INTO '${TMP_DIR}/db.sqlite3'" || fail "database snapshot failed"
CHECK="$(sqlite3 "${TMP_DIR}/db.sqlite3" "PRAGMA integrity_check;")" || fail "integrity check could not run"
[ "$CHECK" = ok ] || fail "snapshot integrity check failed: $CHECK"
(cd "$TMP_DIR" && zip -q "$TMP_ZIP" db.sqlite3) || fail "zip of database failed"

# --- Everything else (optional items, paths relative to the data folder) ---
cd "$BACKUP_DATA_DIR"
set --
for item in attachments sends config.json rsa_key*; do
    if [ -e "$item" ]; then
        set -- "$@" "$item"
    else
        log "note: '$item' not present, skipping"
    fi
done
if [ "$#" -gt 0 ]; then
    zip -q -r "$TMP_ZIP" "$@" || fail "zip of data files failed"
fi
cd - >/dev/null

unzip -tq "$TMP_ZIP" >/dev/null || fail "archive test failed"
mv "$TMP_ZIP" "${BACKUP_DIR}/${NAME}"
log "Created ${NAME} ($(du -h "${BACKUP_DIR}/${NAME}" | cut -f1))"

# --- Local retention ---
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'vaultwarden_backup.*.zip' -mtime +"$RETENTION_DAYS" \
    -exec rm -f {} \; -exec echo "pruned local {}" \;

# --- Remote copy + retention ---
if [ -n "${BACKUP_RCLONE_REMOTE_NAME:-}" ]; then
    command -v rclone >/dev/null 2>&1 || fail "'rclone' not installed"
    REMOTE="${BACKUP_RCLONE_REMOTE_NAME}:${BACKUP_RCLONE_REMOTE_PATH:-}"
    set -- --include 'vaultwarden_backup.*.zip'
    [ -n "${BACKUP_RCLONE_CONFIG:-}" ] && set -- --config "$BACKUP_RCLONE_CONFIG" "$@"

    # `copy`, not `sync`: losing the local folder must never wipe the remote.
    rclone "$@" copy "$BACKUP_DIR" "$REMOTE" || fail "rclone copy to $REMOTE failed"
    log "Uploaded to $REMOTE"

    # Only prune remotely after a successful upload; the newest backup is
    # always younger than the cutoff, so this can never delete everything.
    rclone "$@" delete "$REMOTE" --min-age "${RETENTION_DAYS}d" || log "WARN: remote prune failed"
else
    log "No rclone remote configured; local backup only"
fi

ping_hc ""
log "Backup finished"
