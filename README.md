# WordPress Backup & Restore Scripts

A pair of robust bash scripts for backing up and restoring WordPress installations. Both scripts automatically detect whether WordPress is running in **Docker** or as a **native** installation, so you only need one tool for any environment.

## Scripts

| Script | Purpose |
|--------|---------|
| [`wp_backup.sh`](wp_backup.sh) | Back up a WordPress installation (files + database) |
| [`wp_restore.sh`](wp_restore.sh) | Restore WordPress from a backup archive |
| [`webserver_backup.sh`](webserver_backup.sh) | Back up webserver configuration (Apache, OLS, Nginx) |
| [`webserver_restore.sh`](webserver_restore.sh) | Restore webserver configuration from a backup archive |

The `wp_*` scripts work on **any web server** that serves WordPress — Nginx, Apache, OpenLiteSpeed, LiteSpeed Enterprise, or Caddy — because they operate at the filesystem and database level only. The `webserver_*` scripts back up the webserver configuration itself, which lives **outside** WordPress.

## Features

- ✅ **Two backup modes**: Full (entire WordPress directory) or Lightweight (`wp-content` + `wp-config.php` + `.htaccess`)
- ✅ **Auto-detection**: Docker vs native environment, MySQL vs MariaDB
- ✅ **Smart DB container discovery**: When the container name in `.dbinfo` doesn't match a running container (e.g. restoring across Docker stacks), `wp_restore.sh` re-resolves the DB container from `wp-config.php`'s `DB_HOST` via five layered strategies — so cross-stack restores just work
- ✅ **Reset-DB flow** (`-c` default, `-r` opt-in for `-w`): reads DB credentials and `$table_prefix` from the **live** wp-config.php on the target host/container, drops existing tables with the live prefix, then imports the backup — perfect for cross-stack restores where the old DB credentials in `.dbinfo` are stale
- ✅ **Container-direct mode** (`-c`): back up and restore WordPress running in Docker **without** a host folder mapping — uses `docker cp` and a `.dbinfo` sidecar to carry the resolved DB credentials
- ✅ **Single archive**: Files + database in one ZIP file
- ✅ **Smart restore**: Automatically detects full vs lightweight backup; refuses to restore lightweight into an empty directory
- ✅ **Post-restore customization**: Optional URL replacement, site title change, admin user creation — perfect for migrations to new domains
- ✅ **Dry-run mode**: Preview changes before applying them (`--dry-run`)
- ✅ **Integrity verification**: Backup is verified after creation
- ✅ **Email notifications**: Optional backup report via `msmtp` (`-e email`)
- ✅ **Timestamped output**: `YYYYMMDD_HHMMSS_foldername[_lightweight].zip`
- ✅ **Safe recovery**: Existing target files are backed up before overwrite
- ✅ **Webserver config backup**: Companion scripts back up Apache, OpenLiteSpeed, or Nginx configuration (host or Docker container)

## Backup Modes

### Full Mode (default)
Backs up the **entire WordPress directory** (core, themes, plugins, uploads, config). Best for disaster recovery and migration to a fresh server.

### Lightweight Mode (`-l`)
Backs up only what's **unique** to your site:

| Included | Purpose |
|----------|---------|
| `wp-content/` | Themes, plugins, uploads |
| `wp-config.php` | Database credentials, security keys, custom constants |
| `.htaccess` | Apache/OLS rewrite rules |
| `database.sql` | Full database dump |

WordPress core (`wp-admin/`, `wp-includes/`) is **not** included since it can be re-downloaded. This produces significantly smaller backups.

### When to Use Each Mode

| Scenario | Recommended Mode |
|----------|------------------|
| Disaster recovery / production backups | **Full** |
| Frequent scheduled backups (cron) | **Lightweight** |
| Migrating to a fresh server | **Full** |
| Migrating to a server with matching WP version | **Lightweight** |
| Limited disk space | **Lightweight** |

### Lightweight Restore Requirement

> ⚠️ **IMPORTANT**: Restoring a lightweight backup requires the target directory to **already contain WordPress core files** (`wp-includes/`, `wp-admin/`) with a compatible version. If not, install WordPress first or use a full backup.

The restore script **refuses to proceed** and exits with an error if the target is empty or missing core files, preventing a broken installation.

## Container-Direct Mode (`-c`)

> 🐳 **Use `-c` when WordPress runs in Docker without a host folder mapping** (e.g. only Docker named volumes are mounted). The script will read/write files and database **through the running container** using `docker cp` and `docker exec` — no host path required.

This mode is designed for the official WordPress Docker image (`wordpress:cli`, `wordpress:apache`) and similar images that use `getenv_docker()` helpers in `wp-config.php` (so DB credentials live in container environment variables, not the file itself).

### What `-c` does

- **Backup (`wp_backup.sh -c`)** — pulls files out of the running WP container with `docker cp`, dumps the database via the **DB container** (auto-detected from the shared Docker network with the WP container, or by inspecting the compose project + service name), and writes a `.dbinfo` sidecar with the resolved DB credentials (so the literal `"wordpress"` placeholder from `getenv_docker()` never leaks into the archive).
- **Restore (`wp_restore.sh -c`)** — pushes files back into the running WP container with `docker cp`, restores the database through the DB container. Reads `.dbinfo` from the backup to find the right DB container + credentials without re-parsing the (possibly env-driven) `wp-config.php`.

### Quick Start

```bash
# Backup — read everything from inside the running WP container
./wp_backup.sh -c my-project-wordpress-app -o /backups

# Backup with a custom document root inside the container (default: /var/www/html)
./wp_backup.sh -c my-project-wordpress-app -d /var/www/html -o /backups

# Restore — push everything back into the running WP container
./wp_restore.sh -b /backups/20260918_171946_my-project-wordpress-app.zip \
  -c my-project-wordpress-app

# Restore + URL replacement (e.g. swap dev domain for production)
./wp_restore.sh -b backup.zip -c my-project-wordpress-app \
  -u https://www.production.com \
  -A admin -P 'N3wP@ss!' -E admin@production.com
```

### Limitations & Notes

- The WP container **must be running**. `docker inspect` is used to verify state.
- The DB container is auto-discovered at restore time using a layered fallback chain (see [Smart DB Container Discovery](#smart-db-container-discovery) below). The `DB_CONTAINER` line in `.dbinfo` is treated as a **hint** — if no container by that name is currently running, the script tries to find a matching one through other strategies before failing. This makes it safe to restore a backup created on one Docker stack into a different stack (e.g. `szreypower-website-2026-db` → `wp-dev-environment-wordpress-db`).
- Lightweight container-direct restores still require `wp-includes/` to exist inside the container — same rule as the host-mode restore.
- For DB dumps from **MySQL 8.0** containers, the script adds `--no-tablespaces` automatically (non-root users lack the `PROCESS` privilege).
- Mutually exclusive with `-w` — pick either a host path or a container, not both.

### `.dbinfo` sidecar format

The backup ZIP contains a `.dbinfo` file at the archive root:

```ini
DB_NAME=<resolved db name>          # not the literal "wordpress" placeholder
DB_USER=<db user>
DB_PASSWORD=<db password>
DB_HOST=<db host as seen by WP>     # e.g. "db:3306"
DB_TYPE=<mysql|mariadb>
DB_CONTAINER=<compose db service + project>   # treated as a HINT only at restore time
BACKUP_MODE=<full|lightweight>
SOURCE=<container-direct|native>
WP_CONTAINER=<the container that was backed up>
WP_CONTAINER_DOCROOT=<docroot inside the container>
```

This file is read by `wp_restore.sh` to skip `wp-config.php` parsing entirely (which would otherwise fail for env-driven configs).

> ℹ️ `DB_CONTAINER` records the DB container at the moment the backup was taken. On restore, the script **always** verifies that container is still running — if it isn't, the script re-resolves the DB container via the strategies described in [Smart DB Container Discovery](#smart-db-container-discovery) below before failing. This is what enables restoring a backup from one Docker stack into a different stack.

### Smart DB Container Discovery

`wp_restore.sh` finds the right database container using a **5-step fallback chain**. Each step uses information that becomes progressively more general, so the script can find the DB even when the container name in `.dbinfo` is stale, the `docker-compose.yml` lives somewhere unexpected, or you're restoring into a completely different Docker stack.

The chain (run in order, first match wins):

| # | Strategy | Where the data comes from |
|---|----------|---------------------------|
| 1 | **Exact name match** | A running container literally named `DB_HOST` from `wp-config.php` / `.dbinfo` (e.g. `db`) |
| 2-3 | **Compose v2 prefix** | Derive the compose project name from the WP container (passed via `-c` or auto-discovered), then try `<project>-<db-service>-1` and `<project>-<db-service>` |
| 4 | **Shared Docker network** | Inspect networks of any running WordPress container; pick the first container on those networks whose image matches `*mariadb*` / `*mysql*` |
| 5 | **Last-resort single-DB host** | Pick the first running container whose image matches `*mariadb*` / `*mysql*` (works when there's only one DB stack on the host) |

When does each strategy kick in?

- **Strategy 1** — `wp-config.php` has `DB_HOST` set to a real container name (rare for official WordPress images, but common for hand-written configs).
- **Strategies 2-3** — You pass `-c my-project-wordpress-app` and `DB_HOST=db`; compose projects containers as `<project>-<service>-N` by default.
- **Strategy 4** — The common case for `wp-dev-environment` and similar stacks: WordPress and DB live on a private compose network, but `DB_HOST` in `wp-config.php` is just the service name (`mysql`, `db`, `mariadb`).
- **Strategy 5** — You're restoring on a host that only runs a single DB container and nothing else.

The discovery runs **twice** during a normal restore:

1. **Early** (before the backup is extracted) — best-effort, silent if `DB_HOST` isn't known yet.
2. **After backup extraction** — once `.dbinfo` has populated `DB_HOST`, the script re-runs discovery and uses the result for the actual `docker exec mysql ...`.

If discovery fails completely (no running containers at all, or none match), you'll get a clear error pointing at `DB_HOST` and asking you to start your containers or pass `-c`.

## Quick Start

### Backup

```bash
# Full backup (auto-detects Docker or native)
./wp_backup.sh -w /var/www/html/wordpress -o /backups

# Lightweight backup (smaller, only wp-content + wp-config.php + .htaccess)
./wp_backup.sh -w /var/www/html/wordpress -o /backups -l

# Backup + email notification
./wp_backup.sh -w /var/www/html/wordpress -o /backups -e admin@example.com
```

### Restore

```bash
# Restore (auto-detects environment AND full vs lightweight)
./wp_restore.sh -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress

# Restore a lightweight backup
./wp_restore.sh -b /backups/20250530_143022_wordpress_lightweight.zip -w /var/www/html/wordpress
```

### Webserver Backup

```bash
# Back up a known config directory (host)
./webserver_backup.sh -f /etc/nginx -o /backups

# Back up a known config directory (OpenLiteSpeed)
./webserver_backup.sh -f /usr/local/lsws/conf -o /backups

# Auto-detect Docker or native (no `-f` needed), send email report
./webserver_backup.sh -o /backups -e admin@example.com
```

### Webserver Restore

```bash
# Restore to default native location (auto-detect from backup metadata)
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip

# Restore to a specific native path
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip -f /etc/nginx

# Restore to a Docker container
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip -c my_nginx_container

# Preview before applying
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip --dry-run
```

## Detailed Usage

### wp_backup.sh

**Purpose**: Create a backup of WordPress files and database.

**Usage**:
```bash
./wp_backup.sh -w WORDPRESS_DIR [-o OUTPUT_DIR] [-l]
```

**Options**:
- `-w WORDPRESS_DIR`: Path to WordPress installation (required, **mutually exclusive with `-c`**)
- `-c WP_CONTAINER`: **Container-direct mode** — read files from the running WP container instead of a host path (no folder mapping required)
- `-d DOCROOT`: Document root **inside the container** when using `-c` (default: `/var/www/html`)
- `-o OUTPUT_DIR`: Backup output directory (optional, default: current directory)
- `-l`: Lightweight mode (backup only `wp-content`, `wp-config.php`, `.htaccess`)
- `-e EMAIL`: Send backup report to this email address (optional, requires `msmtp`)
- `-h`: Show help message

**Examples**:
```bash
# Full backup (host path)
./wp_backup.sh -w /var/www/html/wordpress -o /backups

# Lightweight backup (host path)
./wp_backup.sh -w /var/www/html/wordpress -l -o /backups

# Backup with email notification
./wp_backup.sh -w /var/www/html/wordpress -o /backups -e admin@example.com

# Container-direct: WP runs in Docker with no host folder mapping
./wp_backup.sh -c my-project-wordpress-app -o /backups
./wp_backup.sh -c my-project-wordpress-app -d /var/www/html -l -o /backups
```

### Email Notifications

Use `-e EMAIL` to receive a backup report after the run. The script uses `msmtp` (with the `default` account) to send mail.

**Install msmtp** (Debian/Ubuntu):
```bash
sudo apt install msmtp msmtp-mta
```

**Configure** `~/.msmtprc` (or `/etc/msmtprc`):
```ini
defaults
auth           on
tls            on
tls_starttls   on
logfile        ~/.msmtp.log

account        default
host           smtp.example.com
port           587
from           server@example.com
user           server@example.com
password       your-app-password
```

The email contains:
- Status indicator (✅ SUCCESS or ❌ FAILED) and exit code
- Backup path, file size, mode (full/lightweight)
- Detected environment (Docker/Native) and database type (MySQL/MariaDB)
- Full backup log inlined in the message body
- Hostname and timestamp

Notification is sent automatically on both success and failure — even `exit 1` paths trigger an email so you always know when something goes wrong.

**Auto-Detection Logic**:
1. **Environment detection**: Searches for `docker-compose.yml` in the WordPress directory and up to 3 parent levels, then checks for running WordPress-related containers.
2. **Database detection**: Reads `docker-compose.yml` (Docker) or scans system processes/packages/commands (native) to identify MySQL vs MariaDB.
3. **Container detection**: Identifies database container names automatically when in Docker mode.
4. **Fallback**: Uses native database services if Docker is not detected.

### wp_restore.sh

**Purpose**: Restore WordPress files and database from a backup archive. Supports **post-restore customization** (URL change, site title, admin user) which is essential when restoring to a different domain or environment.

**Usage**:
```bash
./wp_restore.sh -b BACKUP_FILE -w WORDPRESS_DIR [options]
```

**Options**:

| Option | Description |
|--------|-------------|
| `-b BACKUP_FILE` | Path to the backup ZIP file (required, **not needed for `-f` fix mode**) |
| `-w WORDPRESS_DIR` | Path to WordPress installation directory (**mutually exclusive with `-c`**) |
| `-c WP_CONTAINER` | **Container-direct mode** — push files back into the running WP container (no host folder mapping required). Reads `.dbinfo` from the backup to find the DB container + credentials. |
| `-d DOCROOT` | Document root **inside the container** when using `-c` (default: `/var/www/html`) |
| `-u NEW_URL` | Replace all URLs in the database with this URL (e.g. `http://localhost:8088`) |
| `-U OLD_URL` | Specify the URL to search for (default: auto-detect from `wp-config.php` or `.dbinfo`) |
| `-t NEW_TITLE` | Set a new site title (updates `blogname` option) |
| `-A ADMIN_USER` | Create or update an admin user (login) |
| `-P ADMIN_PASSWORD` | Password for the admin user (requires `-A`) |
| `-E ADMIN_EMAIL` | Email for the admin user (requires `-A`) |
| `--skip-files` | Skip file restoration (DB only) |
| `--skip-db` | Skip database restoration (files only) |
| `--dry-run` | Show what would happen, then exit without modifying anything |
| `--fix-mode` / `-f` | Apply post-restore customizations to a live site **without** restoring from a backup |
| `-h` | Show help message |

**Examples**:

```bash
# Basic restore (auto-detects everything)
./wp_restore.sh -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress

# Restore to a NEW domain (replace all URLs in DB + create new admin)
./wp_restore.sh -b /backups/site.zip -w ~/restore-site/www \
  -U https://olddomain.com -u https://newdomain.com \
  -A newadmin -P 'NewP@ssw0rd!' -E admin@newdomain.com

# Migrate to local sandbox (replace URLs, change title, test first)
./wp_restore.sh -b site_backup.zip -w ~/sandbox/www \
  -U https://www.production.com -u http://localhost:8088 \
  -t "Local Test" --dry-run   # preview first, then remove --dry-run to apply

# Restore DB only (keep existing files)
./wp_restore.sh -b db_backup.zip -w /var/www/site --skip-files

# Restore files only (keep existing DB)
./wp_restore.sh -b files_backup.zip -w /var/www/site --skip-db

# Container-direct restore (push into running WP container, no host mapping)
./wp_restore.sh -b /backups/20260918_171946_my-project-wordpress-app.zip \
  -c my-project-wordpress-app

# Container-direct + URL replacement
./wp_restore.sh -b backup.zip -c my-project-wordpress-app \
  -u https://www.production.com \
  -A admin -P 'N3wP@ss!' -E admin@production.com
```

**Post-Restore Customizations**:

When `-u`, `-t`, or `-A` are used, additional changes are applied **after** the restore completes:

- **URL replacement (`-u`)** — Performs `UPDATE ... REPLACE(col, old, new)` across these tables:
  `wp_options`, `wp_posts` (guid + content + excerpt), `wp_postmeta`, `wp_comments` (content + author_url), `wp_commentmeta`, `wp_links` (url + image), `wp_usermeta`. Custom `$table_prefix` is honored automatically.

- **Site title (`-t`)** — Updates `blogname` option in `wp_options`.

- **Admin user (`-A -P -E`)** — Creates the user if missing, or updates the password + email if it already exists. Always grants the `administrator` role. Password is hashed with PHP's `password_hash()` (bcrypt) executed inside the web server container.

> ⚠️ **URL replacement limitation**: Simple SQL `REPLACE()` does not understand PHP serialized data. Some references (typically <1%) may remain in serialized option values or escaped shortcodes. For a 100% clean migration, run `wp search-replace` via WP-CLI after restore, or use the `--dry-run` first to confirm scope.

**Auto-Detection Logic**:
1. **Backup mode**: Reads `.backup_mode` marker inside the archive (full vs lightweight).
2. **Environment detection**: Searches for `docker-compose.yml` near the WordPress directory or checks running containers.
3. **Database detection**: Analyzes `docker-compose.yml` or system processes. If `docker-compose.yml` is missing or doesn't mention mysql/mariadb, DB type defaults to `mysql`.
4. **DB container discovery**: Two-pass resolution. Pass 1 runs early (silent when `DB_HOST` is unknown). After the backup is extracted and `.dbinfo` populates `DB_HOST`, pass 2 re-runs the [5-step fallback chain](#smart-db-container-discovery) to find the right running container. This is what makes cross-stack restores (`szreypower-*-db` → `wp-dev-environment-wordpress-db`) work without any extra flags.
5. **Lightweight safety check**: Verifies `wp-includes/` exists in the target before restoring a lightweight backup.
6. **Table prefix**: Reads `$table_prefix` from the restored `wp-config.php`.
7. **PHP detection** (for admin user): Auto-finds the web server container by skipping `db/database/mariadb/mysql/postgres/redis` services in `docker-compose.yml`, falling back to common names (`wordpress`, `web`, `app`, `nginx`, `apache`, `ols`, `lsws`), or uses host `php` if available.

**Failure-recovery behaviour for the DB container**: If the resolved container is not running when it's time to actually restore (e.g. someone stopped the DB mid-run), the script re-runs the fallback chain once more before giving up. The error message names the candidate it tried, the `DB_HOST` it was looking for, and the suggested fix (`docker compose up -d` or pass `-c`).

**Conflict validation**:
- `--skip-files` + `--skip-db` together → error (would do nothing useful)
- `-A ADMIN_USER` without both `-P` and `-E` → error

## Reset-DB Flow (`-c` default, `-r`/`--reset-db` for `-w`)

The reset-db flow discards any DB credentials carried in the backup's `.dbinfo` sidecar (which may refer to a *different* Docker stack) and instead reads credentials directly from the **live** `wp-config.php` on the target. It is the safest way to restore across Docker stacks.

### Why it exists

When restoring a backup from one stack into another, the `.dbinfo` sidecar contains:
- `DB_HOST=db:3306` (compose service name)
- `DB_CONTAINER=old-stack-db` (the source project's DB container)

On the target stack, the compose project name is different — so `old-stack-db` doesn't exist and the live database is in `new-stack-db`. Without reset-db, the [5-step fallback chain](#smart-db-container-discovery) usually rescues you, but live credentials can still mismatch. With reset-db, the script **always** uses the target's real DB.

### How it works

1. **Read live `wp-config.php`**: from `-w` host path, or pulled via `docker cp` from `-c` container. Handles `getenv_docker('WORDPRESS_DB_*', 'literal')` by resolving via the WP container's environment (Prompts only if env vars are missing on the container AND the literal defaults look placeholdery).
2. **Read backup's `$table_prefix`**: extracted from the backup's `wp-config.php`.
3. **List live tables** matching the **live** prefix via `information_schema.TABLES`.
4. **Confirm** the destructive action (auto-confirmed with `-y`/`--yes`, skipped in `--dry-run`).
5. **`DROP`** the live tables (`SET FOREIGN_KEY_CHECKS=0` for clean ordering).
6. **Import** the backup's `database.sql` using the **live** credentials.
7. **Patch** `$table_prefix` (and `$wpdb->prefix`) in the live `wp-config.php` to match the backup's prefix, so the imported tables are correctly recognised.

### Mode behavior

| Mode | Default? | How to opt-in/out |
|------|----------|-------------------|
| `-c` (container-direct) | **ENABLED** by default | Use opt-in/-out via future flag (not yet implemented) |
| `-w` (host path) | Disabled | Pass `-r` or `--reset-db` |

> The `-c` default reflects reality: if you're using `-c`, you're almost certainly dealing with a Docker stack where the `.dbinfo` from another stack is stale.

### When NOT to use

- **Same-stack restores** (`-c same-container`): reset-db is auto-enabled but harmless — both `.dbinfo` and live config point to the same DB, so `$table_prefix` is unchanged.
- **If you specifically want to use the old `.dbinfo` DB** (e.g., restoring to an empty database that already has the old `.dbinfo` imported): don't pass `-r` AND don't use `-c`. Use `-w` with a fresh `WORDPRESS_DIR`.

### Example

```bash
# Cross-stack restore (e.g. backup from 'szreypower-website-2026' → restore into 'wp-dev-environment')
./wp_restore.sh -b ~/20260919_004657_szreypower-website-2026-wordpress.zip \
    -c wp-dev-environment-wordpress-app

# Same in dry-run mode (no actual changes):
./wp_restore.sh -b ~/20260919_004657_szreypower-website-2026-wordpress.zip \
    -c wp-dev-environment-wordpress-app --dry-run

# Host-mode opt-in:
./wp_restore.sh -b ~/backup.zip -w /var/www/html/wp -r -y
```

### Safety guarantees

- The destructive `DROP` only happens **after** the live credentials are confirmed and **after** the user is prompted (unless `-y`/`--yes` is supplied).
- `--dry-run` shows exactly which tables would be dropped and which DB they live in — **without** touching anything.
- The live `wp-config.php` is patched via `sed` with a literal prefix replacement; the script refuses to patch if the new prefix is empty.
- Original credentials in `wp-config.php` (`DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_HOST`) are **never** overwritten — only the table prefix.

## Recovery Process

1. **Validation**: Verify backup file integrity and structure
2. **Extraction**: Extract backup contents to temporary directory
3. **Mode detection**: Auto-detect full vs lightweight via `.backup_mode` marker
4. **Configuration**: Read database settings from the backup's `wp-config.php` and/or `.dbinfo` sidecar
5. **Environment detection**: Determine restoration method (Docker/Native)
6. **DB container resolution** (Docker mode only): Two-pass — best-effort before backup extraction, then a final authoritative pass using the [5-step fallback chain](#smart-db-container-discovery) once `DB_HOST` is known
6a. **Reset-DB flow** (if enabled): Read live wp-config.php → drop tables with the live prefix → use live credentials for the rest of the restore → patch live `wp-config.php`'s `$table_prefix` after file restore
7. **Database restoration**: Restore database using the appropriate method (`docker exec mysql ...` for Docker, `mysql -h ...` for native)
8. **File restoration**: Restore based on detected mode
   - **Full mode**: Replace the entire WordPress directory
   - **Lightweight mode**: Restore only `wp-content/`, `wp-config.php`, `.htaccess` into the existing WordPress installation
9. **Post-restore customizations** (optional): URL replacement, site title change, admin user create/update
10. **Verification**: Confirm successful restoration

## Webserver Backup & Restore

The `webserver_backup.sh` and `webserver_restore.sh` scripts back up and restore the **webserver configuration** itself (Apache, OpenLiteSpeed, Nginx). This lives **outside** of WordPress and is therefore not covered by `wp_backup.sh` / `wp_restore.sh`.

### webserver_backup.sh

**Purpose**: Create a backup of the webserver configuration directory.

**Usage**:
```bash
./webserver_backup.sh [-o OUTPUT_DIR] [-e EMAIL] [-f WEBSERVER_DIR] [-h]
```

**Options**:
- `-o OUTPUT_DIR`: Backup output directory (optional, default: current directory)
- `-e EMAIL`: Send backup report to this email address (optional, requires `msmtp`)
- `-f WEBSERVER_DIR`: Advanced override — path to a specific webserver config directory. If omitted, the script **auto-detects** from the system or Docker (recommended).
  - Apache → `/etc/apache2` (Debian/Ubuntu) or `/etc/httpd` (RHEL)
  - OpenLiteSpeed / LiteSpeed → `/usr/local/lsws/conf`
  - Nginx → `/etc/nginx`
- `-h`: Show help message

**Examples**:
```bash
# Easiest: auto-detect everything (Docker or native), use current dir as output
./webserver_backup.sh

# Auto-detect, write to /backups
./webserver_backup.sh -o /backups

# Auto-detect + email report
./webserver_backup.sh -o /backups -e admin@example.com

# Advanced: back up a known nginx config dir explicitly
./webserver_backup.sh -f /etc/nginx -o /backups

# Advanced: back up OpenLiteSpeed config explicitly
./webserver_backup.sh -f /usr/local/lsws/conf -o /backups

# Advanced: back up a single file path (e.g. httpd.conf only)
./webserver_backup.sh -f /etc/httpd/conf/httpd.conf -o /backups
```

**Auto-Detection Logic**:
1. **Webserver type**: Detected from the `-f` path's filenames (`nginx.conf`, `httpd.conf`, `httpd_config.conf`) or, when `-f` is omitted, from installed packages (`dpkg` / `rpm`), running processes (`apache2`, `httpd`, `nginx`, `lshttpd`), and known config paths.
2. **Environment**: Searches for `docker-compose.yml` containing a webserver service in the `-f` path and up to 3 parent levels. Falls back to well-known roots (`/var/www`, `/opt`, `/srv`) and finally to running Docker containers (only when `-f` is NOT supplied, to avoid false positives from unrelated webserver containers on the host).
3. **Docker mode**: Uses `docker exec tar` to stream the in-container config out to the host (more reliable than `docker cp` for directories).
4. **Native mode**: Copies the config directory (or file) directly.

> ⚠️ **Tip**: When using `-f`, the script respects your path on the host. It will **not** fall back to scanning running Docker containers, even if their names look like webserver images. This prevents accidentally backing up an unrelated sidecar when you clearly want a host-side config.

**Docker service resolution priority** (when auto-detecting inside `docker-compose.yml`):

The script follows an **early-return chain** — the first detector that finds a service wins; lower-priority detectors are skipped. Detection runs in order **D → C → B → A** (lowest to highest priority):

| # | Priority | Detector | When it picks |
|---|----------|----------|---------------|
| 1 | **D** (lowest) | First service whose image matches the detected webserver type | Legacy fallback — preserved for backward compatibility |
| 2 | **C** | Image matches the webserver type **AND** the service exposes a webserver port (`80`, `443`, `8080`, `8443`) | Port specs honour `${VAR:-default}` interpolation from `$DOCKER_COMPOSE_DIR/.env` |
| 3 | **B** | `$WEBSERVER_SERVICE` env var | Explicit override — must exist as a service in the compose file |
| 4 | **A** (highest) | Compose label `wp-backup: webserver` (or shorthand `wp-backup=webserver`) | Explicit user intent |

Use the higher-priority options when:

- **`A` (label)** — you want a permanent, self-documenting marker that survives renames and survives being copied into a fresh repo:

  ```yaml
  services:
    actual-web:
      image: nginx:alpine
      labels:
        - "wp-backup=webserver"
  ```

- **`B` (`WEBSERVER_SERVICE`)** — you want a quick override without editing the compose file:
  ```bash
  export WEBSERVER_SERVICE=actual-web
  ./webserver_backup.sh -o /backups
  ```

- **`C` (port heuristic)** — happens automatically; tune by exposing a webserver port (`80`/`443`/`8080`/`8443`) and using `${WEB_PORT:-...}` in your compose so the right port is matched even when the value comes from `.env`.

> 💡 The port heuristic and `.env` interpolation only matter when no higher-priority detector (`A` / `B`) fires. If `wp-backup: webserver` is set, it wins unconditionally.

**Output Format**:
```
YYYYMMDD_HHMMSS_<webserver_type>_config_backup.zip
└── files/                          ← Webserver config
│   ├── nginx.conf / httpd.conf / httpd_config.conf
│   ├── conf.d/, sites-enabled/, mods-available/, ...   (whatever was in the source)
│   └── .backup_info                ← Metadata: type, source, container, env, host

Examples:
  20250530_143022_nginx_config_backup.zip
  20250530_143022_apache_config_backup.zip
  20250530_143022_openlitespeed_config_backup.zip

The webserver type is embedded in the filename so multi-server backups stay identifiable.
```

> 💡 **Note**: Restore reads `.backup_info` inside the archive, not the filename — so it accepts both the new `*_<type>_config_backup.zip` format and the legacy `*_webserver_backup.zip` format.

### webserver_restore.sh

**Purpose**: Restore webserver configuration from a backup created by `webserver_backup.sh`. Mirrors the safety/reporting style of `wp_restore.sh`.

> 💡 **Interactive by design**: Restore is an operation you run while watching the terminal. All logs — preflight warnings, safety backups, file copies, reload results — stream live so you can react immediately. There is intentionally **no email option** (unlike `webserver_backup.sh -e EMAIL`, which is meant for scheduled/cron runs).

**Usage**:
```bash
./webserver_restore.sh -b BACKUP_FILE [options]
```

**Options**:

| Option | Description |
|--------|-------------|
| `-b BACKUP_FILE` | Path to the webserver backup ZIP file (required) |
| `-f WEBSERVER_DIR` | Target path. Native host path on the host, OR in-container path when env=docker. If omitted, auto-detected. |
| `-c CONTAINER` | Target Docker container. Defaults to the container recorded in the backup, or auto-detected. |
| `--force` | Skip the safety backup of existing target config |
| `--dry-run` | Show what would be done without modifying anything |
| `--restart` | Hard restart webserver after restore (default: graceful reload) |
| `-h` | Show help message |

**Examples**:
```bash
# Restore to default native location (auto-detect from backup metadata)
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip

# Restore to a specific native path
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip -f /etc/nginx

# Restore to a Docker container
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip -c my_nginx_container

# Restore to a specific in-container path
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip -c my_nginx_container -f /etc/nginx

# Preview before applying
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip --dry-run

# Force restore (skip safety backup of existing config)
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip --force

# Hard restart after restore (default: graceful reload)
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip --restart

# Force a specific webserver service when auto-detect picks the wrong one
WEBSERVER_SERVICE=actual-web ./webserver_restore.sh -b /backups/..._nginx_config_backup.zip
```

The `WEBSERVER_SERVICE` env var (also documented in [`webserver_backup.sh`](#webservver_backupsh)) lets you override which service in `docker-compose.yml` is treated as the webserver during restore. The same priority order applies (label → env var → port heuristic → first-image-match).

**Auto-Detection Logic**:
1. **Webserver type**: Reads from `.backup_info` in the archive, or infers from filenames inside (`nginx.conf`, `httpd_config.conf`, `apache2.conf`, `httpd.conf`).
2. **Environment**: Honored from `.backup_info` (native vs docker). Override with `-c` (forces Docker) or with `-f` pointing at an existing host path (forces native).
3. **Target container**: Uses the container recorded in `.backup_info`, or scans `docker-compose.yml` from the same compose directory as the original backup, falling back to inspecting running containers whose images match the detected webserver type.
4. **Default target path**: Auto-selected per type — `/etc/apache2` (apache), `/usr/local/lsws/conf` (openlitespeed), `/etc/nginx` (nginx). Override with `-f`.

**Preflight checks** (run before extracting the backup):
- **Docker mode**: verifies the target container exists and is running (FATAL if not). If running, also checks whether the container's image looks like the backup's webserver type — mismatch is a WARN (you may be migrating config between different webserver images intentionally).
- **Native mode**: detects the webserver process(es) running on the host via `pgrep -x` and `systemctl is-active`. Reports mismatch as WARN (e.g. backup is nginx but host runs apache). If no webserver process is detected at all, emits a WARN — this is normal for fresh hosts or during migration.
- All preflight results appear in the log under the **Preflight Checks** section.
- **Severity**:
  - `FATAL` → aborts the restore. Re-run with `--force` to override.
  - `WARN` → logs and proceeds (use `--force` to silence).
  - `OK` → informational.
- `--force` bypasses preflight entirely (logs `[SKIP] --force flag set`).

**Safety behavior**:
- Before overwriting an existing target directory, the script renames it to `<target>.backup.<timestamp>` and tracks the path. If the restore **succeeds**, these safety backups are automatically removed. If the restore **fails at any point**, they are **preserved** and listed in the log so you can recover manually.
- Use `--force` to skip both the safety backup and the preflight checks (faster, but riskier).
- After restore, the script verifies presence of key config files for the detected webserver type and applies the new config:
  - **Default (graceful reload)** — no downtime. Uses `apachectl -k graceful` / `nginx -s reload` / `lswsctrl reload` (native) or `docker exec ... <reload cmd>` (Docker).
  - **`--restart` (hard restart)** — brief downtime, picks up changes that reload can't (e.g. new listen sockets, new modules, removed directives). Uses `systemctl restart <service>` (native) or `docker restart <container>` (Docker).
  - Both actions are **non-fatal** if they fail — the restore itself is still considered successful; only a warning is emitted. The user can apply the config manually.

> ⚠️ **Note**: Restoring webserver configuration is a privileged operation. The script must be able to write to `/etc/...` (run with `sudo`) or invoke `docker exec` against the target container. For Docker, the container must be running.

**Conflict validation**:
- No required parameters beyond `-b`. All other options are optional and validated lazily.

## Web Server Compatibility

These scripts work at the **filesystem and database level only**, so they are compatible with **any web server** that serves WordPress:

| Web Server | Compatible | Notes |
|------------|-----------|-------|
| Nginx | ✅ Yes | Operates below the web server layer |
| Apache | ✅ Yes | `.htaccess` is included in lightweight backups |
| OpenLiteSpeed (OLS) | ✅ Yes | `.htaccess` is included in lightweight backups |
| LiteSpeed Enterprise | ✅ Yes | `.htaccess` is included in lightweight backups |
| Caddy | ✅ Yes | Operates below the web server layer |

You can freely migrate between web servers after restoring a backup.

> 💡 **Tip**: For Nginx/Caddy users, custom rewrite rules live in server config files (not `.htaccess`). Back those up separately — they're outside WordPress.

## Backup Contents

### Full Mode
```
YYYYMMDD_HHMMSS_foldername.zip
├── files/                  ← Complete WordPress directory
│   ├── wp-admin/
│   ├── wp-includes/
│   ├── wp-content/
│   ├── wp-config.php
│   └── ...
├── database.sql
└── .dbinfo                 ← Resolved DB credentials (container-direct only)
```

### Lightweight Mode
```
YYYYMMDD_HHMMSS_foldername_lightweight.zip
├── files/
│   ├── wp-content/         ← Themes, plugins, uploads
│   ├── wp-config.php
│   └── .htaccess (if exists)
├── database.sql
└── .dbinfo                 ← Resolved DB credentials (container-direct only)
```

> 💡 The `.dbinfo` sidecar is only written when the backup was taken in **container-direct mode** (`-c`). It contains the **resolved** DB credentials (after env / `getenv_docker()` resolution) so a future restore doesn't have to re-parse `wp-config.php` — which would otherwise return the literal placeholder `"wordpress"` instead of the real DB name.

## Output Format

```
YYYYMMDD_HHMMSS_[wordpress-folder-name].zip                  # Full mode
YYYYMMDD_HHMMSS_[wordpress-folder-name]_lightweight.zip      # Lightweight mode
```

Examples: `20250530_143022_wordpress.zip`, `20250530_143022_wordpress_lightweight.zip`

## Dependencies

### Common (all scripts)
- `bash` (4.0+)
- `zip` (backup) / `unzip` (restore)

### For Docker environments
- `docker`
- `docker-compose` (or the `docker compose` plugin)

### For native environments
- **WordPress scripts**: `mysqldump` or `mariadb-dump`, plus `mysql` or `mariadb`
- **Webserver scripts**: no DB tools needed

### For email notifications (optional)
- `msmtp` (with a configured `default` account)

The scripts only require dependencies for the environment they detect.

## Installation

```bash
chmod +x wp_backup.sh wp_restore.sh webserver_backup.sh webserver_restore.sh
```

## Permissions

The scripts need read access to the WordPress directory and write access to:
- The output directory (for backup files)
- The target WordPress directory (for restore)

For Docker environments, the scripts also need access to the Docker socket.

## Scheduled Backups (Cron)

```bash
crontab -e
```

```cron
# Full backup every day at 02:00, with email report
0 2 * * * /home/zongbao/wp-server-backup-scripts/wp_backup.sh \
    -w /var/www/html/wordpress \
    -o /backups \
    -e admin@example.com \
    >> /var/log/wp_backup.log 2>&1

# Lightweight backup every 6 hours (smaller, faster)
0 */6 * * * /home/zongbao/wp-server-backup-scripts/wp_backup.sh \
    -w /var/www/html/wordpress \
    -o /backups \
    -l \
    >> /var/log/wp_backup.log 2>&1

# Webserver config backup every Sunday at 03:00
0 3 * * 0 /home/zongbao/wp-server-backup-scripts/webserver_backup.sh \
    -o /backups \
    -e admin@example.com \
    >> /var/log/webserver_backup.log 2>&1
```

## Important Notes

- **Test first**: Always test backup and restore in a non-production environment before relying on these scripts.
- **Database credentials**: The WordPress backup captures `wp-config.php` which contains plaintext database credentials — store backups securely.
- **Docker backups**: Database dumps and webserver configs are streamed via `docker exec`, so the Docker daemon must be running.
- **Lightweight safety check**: The restore script refuses to restore a lightweight WordPress backup into an empty directory to prevent a broken WordPress installation.
- **Existing files**: On WordPress restore, existing files at the target are moved to a timestamped backup folder (not deleted) so you can recover. On webserver restore, the target config directory is renamed with a `.backup.<timestamp>` suffix before being overwritten.
- **Webserver backup scope**: The webserver backup captures the **configuration** of Apache/OLS/Nginx only. It does not include site content (that's the WordPress backup's job) or TLS certificates, logs, or binary executables. Adjust paths accordingly if you need extras.
- **Disambiguating the webserver service in compose**: If your `docker-compose.yml` has multiple services whose image matches the same webserver type, add the label `wp-backup: webserver` to the canonical one (or use the shorthand `wp-backup=webserver` in list form). Alternatively set `WEBSERVER_SERVICE=<service-name>` in the environment before running either backup or restore. See [Docker service resolution priority](#webservver_backupsh) for the full detection chain.

## Troubleshooting

### "Database container 'X' is not running" (cross-stack restore)
You're restoring a backup that was taken on a different Docker stack (or the original stack has been torn down). The `DB_CONTAINER` value in `.dbinfo` no longer corresponds to a running container.

The script automatically tries to re-resolve the DB container via the [5-step fallback chain](#smart-db-container-discovery). If the final message says it still couldn't find one:

1. Confirm at least one MySQL/MariaDB container is actually running: `docker ps --format '{{.Names}}\t{{.Image}}' | grep -iE 'mysql|mariadb'`
2. If you have a WordPress container running on the same Docker network as the DB (the usual case), the network strategy (#4) should find it. Check that the WP container is also running.
3. If you're restoring onto a fresh host with no WordPress stack yet, start the target stack first (`docker compose up -d` in the right directory), then re-run.
4. As a last resort, pass the WP container explicitly with `-c` so the script can derive the compose project name.

### "Docker detected but no container running"
The script detected a `docker-compose.yml` but the containers are stopped. Start them with `docker-compose up -d` or temporarily move the compose file away to force native mode.

### "Database connection failed"
Verify that `DB_HOST`, `DB_USER`, `DB_PASSWORD` from `wp-config.php` are valid and the database server is running.

### "Lightweight restore refused: target missing wp-includes/"
You attempted to restore a lightweight backup to a directory that doesn't contain WordPress core. Either:
1. Install WordPress core to the target first (`wp core download`), or
2. Use a full backup instead.

### Permissions errors during restore
Ensure the user running the script has write access to the target WordPress directory. For system directories like `/var/www`, you may need `sudo`.

### URL replacement left some references unchanged
Simple `UPDATE ... REPLACE(col, old, new)` does not understand PHP serialized data, so a small number of references (~1% or less) may remain. For complete cleanup, run WP-CLI's `search-replace` after restore:
```bash
docker exec <wp_container> wp search-replace 'https://olddomain.com' 'https://newdomain.com' --all-tables --allow-root
```

### "PHP not found" error when using -A/-P/-E
The script could not locate `php` in the database container, any detected web container, or the host. Solutions:
1. Install `php-cli` on the host (`sudo apt install php-cli`), or
2. Set the `PHP_CONTAINER` env var: `PHP_CONTAINER=my_wordpress_container ./wp_restore.sh -A ...`

### Docker MariaDB user cannot write (privilege errors)
If `brkdbuser` cannot execute `UPDATE`/`INSERT` during post-restore customizations, grant privileges in the MariaDB container:
```bash
docker exec -it <db_container> mariadb -uroot -p
GRANT ALL PRIVILEGES ON *.* TO 'brkdbuser'@'%';
FLUSH PRIVILEGES;
```

### "Could not determine target webserver container" (webserver_restore.sh)
The script could not auto-detect a webserver container from the recorded compose file or running containers. Solutions:
1. Pass `-c CONTAINER` explicitly, or
2. Pass `-f WEBSERVER_DIR` with the in-container path you want to restore to (and optionally `-c`).

### "Webserver backup targeted the wrong service in docker-compose.yml"

When `docker-compose.yml` has more than one service whose image matches the
detected webserver type (e.g. a sidecar `nginx` plus the actual `nginx`/
`openlitespeed`/`apache` service), the auto-detector can land on the first
listed one. Fix this with the highest-priority detector — the **compose
label** is the recommended approach:

```yaml
services:
  actual-web:
    image: nginx:alpine
    labels:
      - "wp-backup=webserver"   # <- explicit marker
```

Or, without editing the compose file, force a service via the
`WEBSERVER_SERVICE` env var:

```bash
export WEBSERVER_SERVICE=actual-web
./webserver_backup.sh -o /backups
```

See [Docker service resolution priority](#webservver_backupsh) for the full
detection chain.

### Webserver restore failed but safety backups were preserved
On failure, the script leaves the pre-existing target config in place under `<target>.backup.<timestamp>`. Inspect those directories to manually recover. They are automatically removed only on success.

### "Post-restore reload failed" (webserver_restore.sh)
The restore itself succeeded, but the in-place reload command (`apachectl -k graceful` / `nginx -s reload` / `lswsctrl reload`) failed — usually because the new config has a syntax error. Inspect the webserver error log, fix the config, and reload manually.

## License

Provided as-is for educational and operational purposes. Test thoroughly in your environment before production use.
