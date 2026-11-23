#!/bin/sh
# Installs logrotate/vaultwarden.conf into /etc/logrotate.d with this repo's path.
# Usage: sudo sh utils/install_logrotate.sh
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET=/etc/logrotate.d/vaultwarden

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }
command -v logrotate >/dev/null 2>&1 || { echo "logrotate not installed (apt install logrotate)"; exit 1; }

case "$REPO_DIR" in
    *'|'* | *' '*) echo "Repo path must not contain spaces or '|': $REPO_DIR"; exit 1 ;;
esac

sed "s|__REPO_DIR__|${REPO_DIR}|g" "${REPO_DIR}/logrotate/vaultwarden.conf" >"$TARGET"
chmod 644 "$TARGET"
echo "Installed $TARGET"

# Dry run to validate the config
logrotate -d "$TARGET" 2>&1 | grep -iE 'error|considering log' || true
