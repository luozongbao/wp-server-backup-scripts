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
- `-w WORDPRESS_DIR`: Path to WordPress installation (required)
- `-o OUTPUT_DIR`: Backup output directory (optional, default: current directory)
- `-l`: Lightweight mode (backup only `wp-content`, `wp-config.php`, `.htaccess`)
- `-e EMAIL`: Send backup report to this email address (optional, requires `msmtp`)
- `-h`: Show help message

**Examples**:
```bash
# Full backup
./wp_backup.sh -w /var/www/html/wordpress -o /backups

# Lightweight backup
./wp_backup.sh -w /var/www/html/wordpress -l -o /backups

# Backup with email notification
./wp_backup.sh -w /var/www/html/wordpress -o /backups -e admin@example.com
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
| `-b BACKUP_FILE` | Path to the backup ZIP file (required) |
| `-w WORDPRESS_DIR` | Path to WordPress installation directory (required) |
| `-u NEW_URL` | Replace all URLs in the database with this URL (e.g. `http://localhost:8088`) |
| `-U OLD_URL` | Specify the URL to search for (default: auto-detect from `wp-config.php`) |
| `-t NEW_TITLE` | Set a new site title (updates `blogname` option) |
| `-A ADMIN_USER` | Create or update an admin user (login) |
| `-P ADMIN_PASSWORD` | Password for the admin user (requires `-A`) |
| `-E ADMIN_EMAIL` | Email for the admin user (requires `-A`) |
| `--skip-files` | Skip file restoration (DB only) |
| `--skip-db` | Skip database restoration (files only) |
| `--dry-run` | Show what would happen, then exit without modifying anything |
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
3. **Database detection**: Analyzes `docker-compose.yml` or system processes.
4. **Lightweight safety check**: Verifies `wp-includes/` exists in the target before restoring a lightweight backup.
5. **Table prefix**: Reads `$table_prefix` from the restored `wp-config.php`.
6. **PHP detection** (for admin user): Auto-finds the web server container by skipping `db/database/mariadb/mysql/postgres/redis` services in `docker-compose.yml`, falling back to common names (`wordpress`, `web`, `app`, `nginx`, `apache`, `ols`, `lsws`), or uses host `php` if available.

**Conflict validation**:
- `--skip-files` + `--skip-db` together → error (would do nothing useful)
- `-A ADMIN_USER` without both `-P` and `-E` → error

## Recovery Process

1. **Validation**: Verify backup file integrity and structure
2. **Extraction**: Extract backup contents to temporary directory
3. **Mode detection**: Auto-detect full vs lightweight via `.backup_mode` marker
4. **Configuration**: Read database settings from the backup's `wp-config.php`
5. **Environment detection**: Determine restoration method (Docker/Native)
6. **Database restoration**: Restore database using the appropriate method
7. **File restoration**: Restore based on detected mode
   - **Full mode**: Replace the entire WordPress directory
   - **Lightweight mode**: Restore only `wp-content/`, `wp-config.php`, `.htaccess` into the existing WordPress installation
8. **Verification**: Confirm successful restoration

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

The email report contains:
- Status indicator (✅ SUCCESS or ❌ FAILED) and exit code
- Detected webserver type (apache / openlitespeed / nginx)
- Source directory (or container path)
- Environment (Docker container name or Native)
- Backup path, file size, timestamp, hostname
- Full backup log inlined in the message body

### webserver_restore.sh

**Purpose**: Restore webserver configuration from a backup created by `webserver_backup.sh`. Mirrors the safety/reporting style of `wp_restore.sh`.

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
| `-e EMAIL` | Send restore report to this email address (optional, requires `msmtp`) |
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

# With email report
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip -e admin@example.com
```

**Auto-Detection Logic**:
1. **Webserver type**: Reads from `.backup_info` in the archive, or infers from filenames inside (`nginx.conf`, `httpd_config.conf`, `apache2.conf`, `httpd.conf`).
2. **Environment**: Honored from `.backup_info` (native vs docker). Override with `-c` (forces Docker) or with `-f` pointing at an existing host path (forces native).
3. **Target container**: Uses the container recorded in `.backup_info`, or scans `docker-compose.yml` from the same compose directory as the original backup, falling back to inspecting running containers whose images match the detected webserver type.
4. **Default target path**: Auto-selected per type — `/etc/apache2` (apache), `/usr/local/lsws/conf` (openlitespeed), `/etc/nginx` (nginx). Override with `-f`.

**Preflight checks** (run before extracting the backup):
- **Docker mode**: verifies the target container exists and is running (FATAL if not). If running, also checks whether the container's image looks like the backup's webserver type — mismatch is a WARN (you may be migrating config between different webserver images intentionally).
- **Native mode**: detects the webserver process(es) running on the host via `pgrep -x` and `systemctl is-active`. Reports mismatch as WARN (e.g. backup is nginx but host runs apache). If no webserver process is detected at all, emits a WARN — this is normal for fresh hosts or during migration.
- All preflight results appear in the log and the email report under the **Preflight Checks** section.
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
└── database.sql
```

### Lightweight Mode
```
YYYYMMDD_HHMMSS_foldername_lightweight.zip
├── files/
│   ├── wp-content/         ← Themes, plugins, uploads
│   ├── wp-config.php
│   └── .htaccess (if exists)
└── database.sql
```

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

## Troubleshooting

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

### Webserver restore failed but safety backups were preserved
On failure, the script leaves the pre-existing target config in place under `<target>.backup.<timestamp>`. Inspect those directories to manually recover. They are automatically removed only on success.

### "Post-restore reload failed" (webserver_restore.sh)
The restore itself succeeded, but the in-place reload command (`apachectl -k graceful` / `nginx -s reload` / `lswsctrl reload`) failed — usually because the new config has a syntax error. Inspect the webserver error log, fix the config, and reload manually.

## License

Provided as-is for educational and operational purposes. Test thoroughly in your environment before production use.
