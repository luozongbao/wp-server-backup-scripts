# WordPress Backup & Restore Scripts

A pair of robust bash scripts for backing up and restoring WordPress installations. Both scripts automatically detect whether WordPress is running in **Docker** or as a **native** installation, so you only need one tool for any environment.

## Scripts

| Script | Purpose |
|--------|---------|
| [`wp_backup.sh`](wp_backup.sh) | Create a backup (files + database) |
| [`wp_restore.sh`](wp_restore.sh) | Restore from a backup archive |

Both scripts work on **any web server** that serves WordPress — Nginx, Apache, OpenLiteSpeed, LiteSpeed Enterprise, or Caddy — because they operate at the filesystem and database level only.

## Features

- ✅ **Two backup modes**: Full (entire WordPress directory) or Lightweight (`wp-content` + `wp-config.php` + `.htaccess`)
- ✅ **Auto-detection**: Docker vs native environment, MySQL vs MariaDB
- ✅ **Single archive**: Files + database in one ZIP file
- ✅ **Smart restore**: Automatically detects full vs lightweight backup; refuses to restore lightweight into an empty directory
- ✅ **Post-restore customization**: Optional URL replacement, site title change, admin user creation — perfect for migrations to new domains
- ✅ **Dry-run mode**: Preview changes before applying them (`--dry-run`)
- ✅ **Integrity verification**: Backup is verified after creation
- ✅ **Timestamped output**: `YYYYMMDD_HHMMSS_foldername[_lightweight].zip`
- ✅ **Safe recovery**: Existing target files are backed up before overwrite

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
```

### Restore

```bash
# Restore (auto-detects environment AND full vs lightweight)
./wp_restore.sh -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress

# Restore a lightweight backup
./wp_restore.sh -b /backups/20250530_143022_wordpress_lightweight.zip -w /var/www/html/wordpress
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
- `-h`: Show help message

**Examples**:
```bash
# Full backup
./wp_backup.sh -w /var/www/html/wordpress -o /backups

# Lightweight backup
./wp_backup.sh -w /var/www/html/wordpress -l -o /backups
```

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

### Common (both scripts)
- `bash` (4.0+)
- `zip` (backup) / `unzip` (restore)

### For Docker environments
- `docker`
- `docker-compose`

### For native environments
- `mysqldump` or `mariadb-dump`
- `mysql` or `mariadb`

The scripts only require dependencies for the environment they detect.

## Installation

```bash
chmod +x wp_backup.sh wp_restore.sh
```

## Permissions

The scripts need read access to the WordPress directory and write access to:
- The output directory (for backup files)
- The target WordPress directory (for restore)

For Docker environments, the scripts also need access to the Docker socket.

## Important Notes

- **Test first**: Always test backup and restore in a non-production environment before relying on these scripts.
- **Database credentials**: The backup captures `wp-config.php` which contains plaintext database credentials — store backups securely.
- **Docker backups**: Database dumps are streamed via `docker exec`, so the Docker daemon must be running.
- **Lightweight safety check**: The restore script refuses to restore a lightweight backup into an empty directory to prevent a broken WordPress installation.
- **Existing files**: On restore, existing files at the target are moved to a timestamped backup folder (not deleted) so you can recover.

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

## License

Provided as-is for educational and operational purposes. Test thoroughly in your environment before production use.
