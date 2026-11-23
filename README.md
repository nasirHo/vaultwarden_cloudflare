# Vaultwarden Self Hosted on Oracle Cloud and Cloudflare Tunnel

This is a setup to run Vaultwarden on Oracle Cloud. It uses a Cloudflare Tunnel to expose the Vaultwarden instance, which removes any need for HTTPS certificate setup, DDNS, or open inbound ports.

Requires a Cloudflare managed DNS site.

Based off of [bitwarden_gcloud](https://github.com/dadatuputi/bitwarden_gcloud). Tested target: Oracle Cloud Free Tier `VM.Standard.A1.Flex` (arm64). All images used here publish arm64 builds. Keep in mind that resources created during the free trial are deleted when the account switches to the permanent free tier, so MAKE SURE to have a backup, or wait until your account is on the permanent free tier.

## Services

| Service | Purpose |
|---|---|
| `vaultwarden` | The server. Serves HTTP **and** websocket notifications on port 80 (no separate websocket port since Vaultwarden 1.29). |
| `cloudflared` | Cloudflare Tunnel connector (outbound-only). |
| `rclone` | Locally built image (`images/rclone-backup`: rclone + sqlite/zip). Runs `utils/backup.sh` on a cron schedule (`BACKUP_FREQUENCY`, daily by default) and copies backups to Google Drive or any rclone remote. Mounts the vault data read-only. |
| `fail2ban` | Watches `./logs/vaultwarden.log` (and nothing else) and bans offending IPs **at the Cloudflare edge** via the API (host firewall bans would not work, since all traffic arrives through the tunnel). |

Folders: `./vaultwarden` = vault data (back this up), `./logs` = Vaultwarden log, `./backup` = local backup zips.

### Updating

Image versions are pinned in `docker-compose.yml`, so nothing changes behind your back. To update, read the release notes, bump the tag(s) (for rclone, the `RCLONE_VERSION` build arg and the `image:` tag), then:

```sh
docker compose pull            # pinned upstream images
docker compose build --pull    # the local backup image
docker compose up -d
```

## Setup

### 1. Oracle Cloud VM

- Install Docker + the compose plugin.
- The tunnel is outbound-only: in the VCN Security List / NSG you can drop all ingress rules except SSH (22).

### 2. Cloudflare Tunnel

In the Cloudflare dashboard: **Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared**.

- Copy the tunnel token into `CF_TUNNEL_TOKEN` in `.env`.
- Add a **Public hostname**: `vw.example.com` → Service `HTTP` → `vaultwarden:80`.

That single route covers the web vault, the API and websocket notifications (`/notifications/hub`); cloudflared upgrades websockets automatically.

### 3. Protect `/admin` with Cloudflare Access

The admin page should not be reachable by the whole internet. In **Zero Trust → Access → Applications → Add an application → Self-hosted**:

- Application domain: `vw.example.com`, path: `admin` (subpaths are covered automatically).
- Policy: **Allow**, include `Emails` → your email (login method: One-time PIN or an IdP of your choice).

Only the `/admin` path is protected; do **not** put Access in front of the whole hostname, as Bitwarden apps/extensions cannot complete an Access login.

Then also set an `ADMIN_TOKEN` (defense in depth). Generate an argon2 hash:

```sh
docker run --rm -it vaultwarden/server:1.37.5-alpine /vaultwarden hash
```

and put it in `vaultwarden.env` **in single quotes**, e.g. `ADMIN_TOKEN='$argon2id$v=19$m=65540,...'`. Leave the line commented out to disable the admin page entirely.

### 4. Fail2Ban API token

Create a Cloudflare API token (**My Profile → API Tokens → Create Custom Token**) with permission **Zone → Firewall Services → Edit**, restricted to your zone. Put it in `CF_API_TOKEN`, and your zone ID (zone Overview page) in `CF_ZONE_ID`.

Two jails are enabled (`fail2ban/jail.d/vaultwarden.local`): failed vault logins and invalid admin tokens. Bans appear under **Security → WAF → Tools → IP Access Rules**.

Optionally, add a Cloudflare WAF rate-limiting rule for `/identity/connect/token` (one rule is free). Vaultwarden also has built-in `LOGIN_RATELIMIT_*` / `ADMIN_RATELIMIT_*` limits enabled by default.

### 5. Backups

`utils/backup.sh` runs in the `rclone` container on the `BACKUP_FREQUENCY` schedule. Each run:

1. snapshots `db.sqlite3` with `VACUUM INTO` and runs `PRAGMA integrity_check` on the snapshot,
2. zips it together with `attachments/`, `sends/`, `config.json` and `rsa_key*` (paths relative to the data folder),
3. tests the archive, then **copies** it to the rclone remote (never `sync`, so a wiped local folder can't wipe the remote),
4. deletes backups older than `BACKUP_RETENTION_DAYS` locally and remotely (remote only after a successful upload).

Any failure aborts the run (nothing is pruned) and is reported in `docker compose logs rclone` and, if `BACKUP_HEALTHCHECK_URL` is set (e.g. a free [healthchecks.io](https://healthchecks.io) check), as a `/fail` ping. A healthcheck is recommended: it also alerts you when backups silently *stop* running.

**Encryption:** backups contain the whole vault database and the token signing key, so upload through an rclone `crypt` remote. Copy `rclone/rclone.conf.template` to `rclone/rclone.conf`, fill in the `gdrive` remote (easiest: run `rclone config` on a machine with a browser and copy the result) and the `gdrive-crypt` passwords. **Store the crypt passwords outside this vault** — otherwise losing the VM means losing the only key to the backups.

Run a backup manually to test:

```sh
docker exec rclone sh /etc/periodic/daily/backup
```

**Restore:**

```sh
rclone --config rclone/rclone.conf copy gdrive-crypt:backups ./restore   # decrypts on download
docker compose stop vaultwarden
unzip restore/vaultwarden_backup.<date>.zip -d ./vaultwarden/   # into an empty data folder
docker compose start vaultwarden
```

### 6. Start

```sh
cp .env.template .env                           # stack settings: domain, Cloudflare, backups
cp vaultwarden.env.template vaultwarden.env     # Vaultwarden settings: admin token, push, SMTP, ...
chmod 600 .env vaultwarden.env                  # both hold secrets
docker compose up -d --build
docker compose logs -f vaultwarden
```

### 7. Log rotation

Vaultwarden writes `LOG_FILE` (`./logs/vaultwarden.log`, which fail2ban reads) but never rotates it. Install the host logrotate config once:

```sh
sudo sh utils/install_logrotate.sh
```

It rotates `vaultwarden.log` and `fail2ban/fail2ban.log` weekly (or earlier once they pass 50M / 20M), keeps 12 / 8 compressed generations, and signals the containers to reopen their files (`SIGHUP` to Vaultwarden, `flushlogs` to fail2ban) — no restarts. Test it with `sudo logrotate -f /etc/logrotate.d/vaultwarden`.

Container stdout logs (`docker compose logs`) are capped separately in `docker-compose.yml` at 3 × 10 MB per service.

## Migrating from an existing install

1. Stop the old server (e.g. `systemctl stop vaultwarden`) so the SQLite DB is consistent.
2. Copy from the old data folder (e.g. `/opt/vaultwarden/data`) into `./vaultwarden/`:
   `db.sqlite3` (plus `db.sqlite3-wal` if present), `attachments/`, `sends/`, `rsa_key.pem`, `config.json` (if present). `icon_cache/` is optional.
3. **Check `config.json`**: settings saved via the admin page override environment variables (domain, admin token, SMTP, ...). Edit or remove stale entries.
4. Use the same or a newer Vaultwarden version than the old server; database migrations only go forward.
5. Do not carry over TLS settings (`ROCKET_TLS`, certificates) — Cloudflare terminates TLS and the container serves plain HTTP inside the docker network.

### Configuration files

| File | Holds | Notes |
|---|---|---|
| `.env` | Stack settings: `DOMAIN`, `TZ`, Cloudflare tokens, backup settings | Used by docker compose for `${...}` substitution only; not passed wholesale to any container. |
| `vaultwarden.env` | Vaultwarden's own settings: `ADMIN_TOKEN`, `SIGNUPS_ALLOWED`, `PUSH_*`, `SMTP_*`, `YUBICO_*`, ... | Passed as-is to the Vaultwarden container. Any option from [Vaultwarden's .env.template](https://github.com/dani-garcia/vaultwarden/blob/main/.env.template) works. **Comment out unused settings instead of leaving them empty** — e.g. an empty `YUBICO_SERVER=` makes Vaultwarden refuse to start. |

When migrating from a native install, most lines of the old Vaultwarden `.env` (e.g. `PUSH_*`, `ADMIN_TOKEN`) can be copied into `vaultwarden.env` as-is; leave out `ROCKET_*`, `DATA_FOLDER`, `WEB_VAULT_*` and `DOMAIN`.
