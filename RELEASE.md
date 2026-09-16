# Release Notes

All notable changes to this project will be documented in this file.

This project adheres to a simple versioning scheme. Versions are tagged in git
(e.g. `v.1.0`, `v.1.1`). Patch releases contain bug fixes only; minor releases
add new features; major releases introduce breaking changes.

---

## [Unreleased]

### Added
- (none yet)

### Changed
- (none yet)

### Fixed
- (none yet)

### Removed
- (none yet)

---

## v.1.0 — Initial Release

**Tag:** `v.1.0`
**Date:** First stable release of the WordPress & Webserver Backup Scripts suite.

This is the first public release. It bundles four production-ready bash scripts
for backing up and restoring WordPress installations and webserver
configurations across both Docker and native environments.

### Scripts

| Script | Purpose |
|--------|---------|
| `wp_backup.sh` | Back up a WordPress installation (files + database) |
| `wp_restore.sh` | Restore WordPress from a backup archive |
| `webserver_backup.sh` | Back up webserver configuration (Apache, OLS, Nginx) |
| `webserver_restore.sh` | Restore webserver configuration from a backup archive |

### Features

#### WordPress Backup & Restore
- ✅ **Two backup modes**: Full (entire WordPress directory) or Lightweight
  (`wp-content` + `wp-config.php` + `.htaccess`)
- ✅ **Auto-detection**: Docker vs native environment, MySQL vs MariaDB
- ✅ **Single archive**: Files + database in one ZIP file
- ✅ **Smart restore**: Automatically detects full vs lightweight backup;
  refuses to restore a lightweight backup into an empty directory
- ✅ **Post-restore customization**: Optional URL replacement, site title
  change, admin user creation — perfect for migrations to new domains
- ✅ **Dry-run mode**: Preview changes before applying them (`--dry-run`)
- ✅ **Integrity verification**: Backup is verified after creation
- ✅ **Email notifications**: Optional backup report via `msmtp` (`-e email`)
- ✅ **Timestamped output**: `YYYYMMDD_HHMMSS_foldername[_lightweight].zip`
- ✅ **Safe recovery**: Existing target files are backed up before overwrite
- ✅ **Custom `$table_prefix`**: Honored automatically during restore

#### Webserver Backup & Restore
- ✅ **Multi-webserver support**: Apache, OpenLiteSpeed / LiteSpeed, Nginx
- ✅ **Auto-detection** of webserver type from packages, processes, and known
  config paths
- ✅ **Docker + native targets** for both backup and restore
- ✅ **Preflight checks** (webserver restore) — verifies target container,
  webserver process, and image/type compatibility before overwriting
- ✅ **Safety backups** (webserver restore) — existing target config is
  renamed to `<target>.backup.<timestamp>` before overwrite, auto-cleaned on
  success, preserved on failure
- ✅ **Graceful reload by default**, with `--restart` for hard restart when
  reload cannot pick up changes (new listen sockets, new modules, etc.)
- ✅ **Dry-run mode** (`--dry-run`) and `--force` to skip safety backups
- ✅ **Email notifications** for scheduled webserver backups (`-e email`)

### Web Server Compatibility

The WordPress scripts work at the filesystem and database level only, so they
are compatible with **any** web server that serves WordPress:

| Web Server     | Compatible | Notes |
|----------------|-----------|-------|
| Nginx          | ✅ Yes    | Operates below the web server layer |
| Apache         | ✅ Yes    | `.htaccess` included in lightweight backups |
| OpenLiteSpeed  | ✅ Yes    | `.htaccess` included in lightweight backups |
| LiteSpeed Ent. | ✅ Yes    | `.htaccess` included in lightweight backups |
| Caddy          | ✅ Yes    | Operates below the web server layer |

### Output Formats

**WordPress backups**
```
YYYYMMDD_HHMMSS_foldername.zip                # Full mode
YYYYMMDD_HHMMSS_foldername_lightweight.zip    # Lightweight mode
```

**Webserver backups**
```
YYYYMMDD_HHMMSS_<webserver_type>_config_backup.zip

Examples:
  YYYYMMDD_HHMMSS_nginx_config_backup.zip
  YYYYMMDD_HHMMSS_apache_config_backup.zip
  YYYYMMDD_HHMMSS_openlitespeed_config_backup.zip
```

> The webserver type is embedded in the filename so multi-server backups stay
> identifiable. Restore reads metadata inside the archive, not the filename,
> so it accepts both the new `*_<type>_config_backup.zip` format and the
> legacy `*_webserver_backup.zip` format.

### Dependencies

- `bash` (4.0+)
- `zip` (backup) / `unzip` (restore)
- Docker environments: `docker`, `docker-compose` (or `docker compose`)
- Native WordPress: `mysqldump` / `mariadb-dump`, `mysql` / `mariadb`
- Email notifications (optional): `msmtp`

The scripts only require dependencies for the environment they detect.

### Getting Started

```bash
# 1. Make scripts executable
chmod +x wp_backup.sh wp_restore.sh webserver_backup.sh webserver_restore.sh

# 2. Full WordPress backup (auto-detects Docker or native)
./wp_backup.sh -w /var/www/html/wordpress -o /backups

# 3. Lightweight WordPress backup (smaller, only wp-content + wp-config.php)
./wp_backup.sh -w /var/www/html/wordpress -o /backups -l

# 4. Restore WordPress from a backup
./wp_restore.sh -b /backups/20250530_143022_wordpress.zip \
                -w /var/www/html/wordpress

# 5. Webserver config backup (auto-detects webserver + Docker/native)
./webserver_backup.sh -o /backups

# 6. Webserver config restore
./webserver_restore.sh -b /backups/20250530_143022_nginx_config_backup.zip
```

### Notes

- **Test first**: Always test backup and restore in a non-production
  environment before relying on these scripts.
- **Database credentials**: WordPress backups capture `wp-config.php` which
  contains plaintext database credentials — store backups securely.
- **Webserver backup scope**: Captures **configuration** only. Does not
  include site content (use the WordPress backup), TLS certificates, logs,
  or binary executables.
- See `README.md` for full documentation, scheduled-backup (cron) examples,
  troubleshooting, and detailed option reference.
