# Release Notes

All notable changes to this project will be documented in this file.

This project adheres to a simple versioning scheme. Versions are tagged in git
(e.g. `v.1.0`, `v.1.1`). Patch releases contain bug fixes only; minor releases
add new features; major releases introduce breaking changes.

---

## [Unreleased]

### Added

**Live-config-aware wp-config.php patching (always on)** (`wp_restore.sh`).

Before restoring files, the script reads DB credentials from the **live** `wp-config.php` on the target — host path (`-w`) or container (`-c`). Three forms are supported on the right-hand side of `define(...)` calls:

- **Literal**: `define('DB_NAME', 'wordpress');` — read directly
- **`getenv_docker()`**: `define('DB_NAME', getenv_docker('WORDPRESS_DB_NAME', 'wordpress'));` — first tries `WORDPRESS_DB_*` env vars on the WP container, then falls back to the **DB container's** `MYSQL_*` / `MARIADB_*` env vars (since official WordPress and MariaDB images use different env var names). The literal fallback is used only as a last resort.
- **`$_ENV[]` / `getenv()`** — also supported

After restore, the new `wp-config.php` is patched via `sed` so its `DB_NAME` / `DB_USER` / `DB_PASSWORD` / `DB_HOST` and `$table_prefix` reflect the credentials that actually imported the data. WordPress can connect on first request — no manual editing. Runs in **both** `-c` and `-w` modes, with or without `-r`. If the target has no live wp-config yet (fresh directory), the script soft-fails and falls back to `.dbinfo` creds so the restore can still proceed.

**`-r` / `--reset-db` clarified** (`wp_restore.sh`).

`-r` now controls **only the destructive part** of restore: DROP live tables + IMPORT backup SQL using live credentials. Previously, the docs implied `-r` also gated the wp-config.php patching — that actually happens unconditionally. The `-c` mode still auto-enables `-r` for cross-stack safety; `-w` requires explicit `-r`.

**`-y` / `--yes` flag** (`wp_restore.sh`).

Skips the DROP-TABLES confirmation prompt when `-r` is in effect. Useful for cron/automation runs.

**Robust webserver service detection** (`webserver_backup.sh`, `webserver_restore.sh`).

When a `docker-compose.yml` contains multiple services whose images match a
known webserver type (e.g. several `nginx:alpine` instances, or a sidecar
`nginx` plus a real `nginx`/`openlitespeed`/`apache`), the script can no
longer accidentally pick the wrong one. Service detection now follows an
**early-return priority chain** — the first hit wins, lower-priority
detectors are skipped entirely:

| # | Priority | Method | Notes |
|---|----------|--------|-------|
| 1 | **D** (lowest) | First service whose image matches the detected webserver type | Legacy fallback (preserved for back-compat) |
| 2 | **C** | Image matches webserver type **AND** exposes a webserver port (`80`/`443`/`8080`/`8443`) | Resolves `${VAR:-default}` interpolation from compose `.env` |
| 3 | **B** | `$WEBSERVER_SERVICE` env var | Explicit, bypasses all heuristics |
| 4 | **A** (highest) | Compose label `wp-backup: webserver` (or shorthand `wp-backup=webserver` in list form) | Explicit user intent |

Key user-facing additions:

- **`WEBSERVER_SERVICE` env var** — forces the webserver service name when
  auto-detection is wrong. Set with `export WEBSERVER_SERVICE=myservice`
  before running either `webserver_backup.sh` or `webserver_restore.sh`.
- **Compose label `wp-backup: webserver`** — opt-in marker on a service to
  declare it as the webserver. Supports both YAML map form
  (`labels: wp-backup: webserver`) and list/shorthand form
  (`labels: - "wp-backup=webserver"`).
- **`.env` interpolation for ports** — port specs such as
  `"${WEB_PORT:-80}:80"` now correctly resolve from
  `$DOCKER_COMPOSE_DIR/.env` during the port-based heuristic. Previously a
  service exposing only an interpolated webserver port (e.g. `WEB_PORT=443`)
  could be missed.

### Fixed

**`wp_restore.sh` — wp-config.php patching**

- `patch_wp_config_db_creds()` previously used a sed pattern (`['\"].*$`) that only matched **literal** values in `wp-config.php`. When the live config used `getenv_docker()` (the default for the official WordPress Docker image), the patch silently failed and the restored wp-config.php kept `getenv_docker('WORDPRESS_DB_NAME', 'wordpress')` calls. Result: WordPress on first request would read the placeholder `"wordpress"` instead of the real DB name, fail to connect, and produce a "Error establishing a database connection" message. The pattern is now rewritten to match the entire right-hand expression up to the closing `;`, so function calls, ternaries, and concatenations are handled correctly. Counts patched lines via `grep -c` and warns if zero matches were rewritten.
- `get_table_prefix()` previously used a sed pattern that captured the whole `getenv_docker('WORDPRESS_TABLE_PREFIX', 'wp_')` expression as the prefix string. Result: URL replacement (`UPDATE $table_prefix = getenv_docker(...)`) raised `ERROR 1064 (42000) You have an error in your SQL syntax` mid-restore. The function now handles three forms — literal, `getenv_docker()` (uses the fallback arg as the prefix), and `getenv()` (resolves against current shell env, falls back to `wp_`) — and prefers `LIVE_DB_PREFIX` when set by `read_live_wp_config()` so the live prefix (the one WordPress actually used to connect) is always the source of truth.
- `patch_wp_config_table_prefix()` previously only matched the literal form `$table_prefix = 'wp_';`. Now also matches the `getenv_docker()` and `getenv()` forms, so the restored wp-config.php ends up with a clean literal prefix after a reset-db import.

**`wp_restore.sh` — restore flow**

- Previously hard-failed when the target directory had no live wp-config.php (e.g. fresh restore). The "READ LIVE WP-CONFIG" block now soft-fails: if no live config is found, it logs a warning and continues with `.dbinfo` creds + a `DB_HOST` derived from the `DB_CONTAINER` name. Lets you restore into a completely empty directory without manual setup.

**`webserver_restore.sh` — ownership & permissions on restore**

- The restore previously used `cp -r` (or `tar | docker exec tar` for container mode) which created files owned by the restore user (`root` when run with `sudo`). Apache/Nginx/OLS running as non-root users (`www-data`, `nginx`, `nobody:65534`) could then fail to read their own config after restore, breaking the webserver silently. `restore_files()` now:
  - **Host mode** — moves the existing target dir aside as a safety backup (also recorded in `RESTORE_SAFETY_BACKUPS` for cleanup on success), copies via `cp -a` (preserves modes/timestamps), `chmod -R u+rwX` to ensure root can traverse, then `chown -R` either to the safety backup's owner (`--reference` style via `stat`) or to a webserver-type default if the target didn't exist beforehand.
  - **Container mode** — adds `--no-same-owner` to the in-container tar so it doesn't try to chown (and fail with EPERM), then `docker exec chown -R` using the same per-type defaults.
  - Added `map_default_owner_for_type()` helper: `apache` → `root:www-data`, `nginx` → `root:root`, `openlitespeed` → `nobody:nogroup` (matches OLS's drop-priv target), with `root:root` as safe fallback.
- `restore_files()` previously required running as root to be useful (for `chown`), but the script accepted non-root invocations and only failed later when individual `cp`/`docker exec` commands stumbled on permission errors. The script now fails fast at startup with the same "use sudo" message as `wp_restore.sh` — only root can chown to other UIDs, and a non-root restore leaves config files un-readable by the webserver.
- The cleanup loop in `cleanup()` only knew how to remove `container:`-prefixed safety backups; the new `host:`-prefixed entries (added by the ownership-preserving restore) would have been logged as un-removable paths on success. The cleanup loop now strips both prefixes, and the failure-log branch shows the user a plain filesystem path (no `host:` / `container:` prefix) so manual recovery instructions are actionable.

**`webserver_backup.sh` — service detection**

- No longer picks the wrong service when `docker-compose.yml` lists another
  webserver-image service first (e.g. `nginx-helper` before `actual-web`).
- awk-based label parser crashed on compose files where `services:` was the
  first indented line. Replaced with a shell/awk two-pass walker that uses
  `lead()` indentation counts and correctly handles both tab-indented and
  space-indented files.
- Port heuristic treated the literal string `"8080:80"` as a port value
  (with quotes), so webserver ports in docker-compose short syntax were
  never matched. Now the host port is extracted before regex matching,
  and `${VAR:-default}` interpolations are resolved against `.env` first.

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
