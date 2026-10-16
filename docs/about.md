# About `wp-server-backup-scripts`

## What is this project?

`wp-server-backup-scripts` is a suite of four production-ready bash scripts that backup and restore **WordPress installations** and their **webserver configurations**. Both native (bare-metal / VM) and Docker-based deployments are supported — the scripts auto-detect the environment so a single tool works everywhere.

The scripts were originally written for personal WordPress + OpenLiteSpeed/Nginx/Apache hosting and have since grown to handle cross-stack restores, container-direct mode (no host bind mount), bind-mount safety on dev stacks, and proper ownership restore so the restored webserver can actually read its own config.

## Scripts at a Glance

| Script | Purpose |
|--------|---------|
| [`wp_backup.sh`](../wp_backup.sh) | Back up a WordPress installation (files + database) |
| [`wp_restore.sh`](../wp_restore.sh) | Restore WordPress from a backup archive |
| [`webserver_backup.sh`](../webserver_backup.sh) | Back up webserver configuration (Apache, OLS, Nginx) |
| [`webserver_restore.sh`](../webserver_restore.sh) | Restore webserver configuration from a backup archive |

The two pairs are intentionally separated:

- The `wp_*` scripts operate at the **filesystem + database** level. They are **webserver-agnostic** — anything that can serve WordPress files (Nginx, Apache, OpenLiteSpeed, LiteSpeed Enterprise, Caddy, …) is supported, because the scripts never touch the webserver process.
- The `webserver_*` scripts back up the **webserver configuration** itself (vhost files, modules, mime types, custom includes, …) which lives outside the WordPress docroot.

## Who is it for?

- **Homelab / self-hosters** running WordPress on a VPS with Nginx, Apache, or OpenLiteSpeed.
- **Developers** with local Docker Compose stacks (`wordpress + mariadb + nginx` style) who want a reliable, scripted way to snapshot, restore, and migrate their dev environments.
- **Small teams** that need a no-JS-framework, no-daemon, cron-friendly backup tool backed by simple ZIP files — easy to copy off-site, easy to inspect.

## Design Principles

The scripts follow a few non-negotiable rules that explain most of their shape:

1. **One tool, both worlds** — Docker or native is auto-detected from `docker-compose.yml`, running containers, and installed packages. No two-track documentation, no per-mode scripts.
2. **Safe by default** — every restore moves existing files aside first; bind mounts inside the WP container are detected and protected from destructive operations; lightweight restores refuse to run into an empty directory.
3. **No proprietary archive format** — backups are plain ZIP files. You can `unzip -l` them, restore them by hand, copy them to any host.
4. **Cross-stack restores just work** — restoring a backup made on one Docker stack into a different stack is the default, not an edge case. A 5-step DB container discovery chain, live `wp-config.php` patching, and `.dbinfo` sidecar handling all exist to make this frictionless.
5. **Webserver-readable after restore** — `chown` rules are per webserver type (Apache → `root:www-data`, Nginx → `root:root`, OLS → `nobody:nogroup`) so the restored config is owned correctly without manual intervention.
6. **Portable archives** — `zip -X` strips the source machine's UID/GID from the archive, so backups move cleanly between hosts.
7. **Transparent operations** — every action logs with a timestamp; `--dry-run` is supported on both restore scripts; failure paths still trigger email notifications.

## Headline Features

### WordPress

- **Two backup modes** — Full (entire WordPress directory) or Lightweight (`wp-content` + `wp-config.php` + `.htaccess`).
- **Container-direct mode (`-c`)** — back up & restore WordPress running in Docker **without** a host folder mapping. Uses `docker cp` + a `.dbinfo` sidecar to carry resolved DB credentials (so the literal `"wordpress"` placeholder from `getenv_docker()` never leaks into the archive).
- **Smart DB container discovery** — 5-step fallback chain (exact name → compose project prefix → shared Docker network → last-resort single-DB host) so cross-stack restores find the right DB even when the container name in `.dbinfo` is stale.
- **Live-config-aware `wp-config.php` patching** — reads credentials from the **live** `wp-config.php` on the target (host path or container) before restoring files; handles `getenv_docker('WORDPRESS_DB_*', 'literal')` by resolving against the running WP container's environment, falls back to the DB container's `MYSQL_*` / `MARIADB_*` env vars, and prompts only as a last resort. After restore, the new `wp-config.php` is patched so `DB_NAME` / `DB_USER` / `DB_PASSWORD` / `DB_HOST` reflect the credentials that actually imported the data.
- **Reset-DB flow (`-c` default, `-r` opt-in for `-w`)** — drops existing tables with the live prefix and imports the backup's SQL using live credentials, then patches `$table_prefix` to match the backup. Solves cross-stack restores where the old DB credentials in `.dbinfo` are stale.
- **Post-restore customizations** — URL replacement, site title change, admin user creation. Perfect for migrations to new domains.
- **Bind-mount safety (automatic)** — when a WP container has bind mounts layered on the named volume (e.g. `./mytheme/` → `/var/www/html/wp-content/themes/MyTheme`), the restore refuses `rm -rf` on any safety backup that contains a bind mount destination, hardlink-copies non-bind paths into the safety backup instead of `mv`-renaming the parent, and ignores stale `0:0` ownership read from a previous broken run.
- **Root-required for restore** — both restore scripts abort with a clear "use sudo" message at startup if not run as root.

### Webserver

- **Multi-webserver support** — Apache (Debian/Ubuntu + RHEL layouts), OpenLiteSpeed / LiteSpeed Enterprise, Nginx.
- **Auto-detection** of webserver type from packages, processes, and known config paths.
- **Docker + native targets** for both backup and restore.
- **Preflight checks** on restore — verifies target container, webserver process, image/type compatibility before overwriting.
- **Safety backups** — existing target config is renamed to `<target>.backup.<timestamp>` before overwrite, auto-cleaned on success, preserved on failure.
- **Graceful reload by default**, with `--restart` for hard restart when reload cannot pick up changes (new listen sockets, new modules, etc.).
- **Per-type ownership mapping on restore** — Apache → `root:www-data`, Nginx → `root:root`, OpenLiteSpeed → `nobody:nogroup`. Prevents "Permission denied" when the webserver runs as a non-root UID.

## Project Layout

```
.
├── README.md              # Full user-facing documentation
├── RELEASE.md             # Version history (semantic, git-tagged)
├── wp_backup.sh           # WordPress backup (full + lightweight)
├── wp_restore.sh          # WordPress restore (Docker + native)
├── webserver_backup.sh    # Webserver config backup
├── webserver_restore.sh   # Webserver config restore
├── docs/                  # Long-form / explanatory docs (this folder)
│   └── about.md           # ← you are here
└── issue/                 # Post-mortems on real-world restore failures
    ├── issue1.md          # rm -rf walking into a bind-mounted host directory
    └── issue2.md          # wp-config.php ownership after docker cp
```

## Dependencies

- `bash` (4.0+)
- `zip` (backup) / `unzip` (restore)
- Docker environments: `docker`, `docker-compose` (or `docker compose`)
- Native WordPress: `mysqldump` / `mariadb-dump`, `mysql` / `mariadb`
- Email notifications (optional): `msmtp`

The scripts only require dependencies for the environment they detect — Docker-mode scripts do not need `mysqldump` on the host, native-mode scripts do not need `docker` on PATH.

## Versioning

The project follows a simple versioning scheme documented in [`RELEASE.md`](../RELEASE.md). Versions are tagged in git (e.g. `v.1.0`, `v.1.1`):

- **Patch** releases — bug fixes only.
- **Minor** releases — additive features.
- **Major** releases — breaking changes.

| Version | Date | Theme |
|---------|------|-------|
| `v.1.0` | — | Initial public release (four scripts, Docker + native, dry-run, email notifications). |
| `v.1.1.0` | 2026-09-19 | **Ownership Restore & Service Detection Hardening** — `webserver_restore.sh` per-type chown defaults; `wp_restore.sh` `getenv_docker()` aware `wp-config.php` patching; robust webserver service detection (compose labels, port heuristic, `${VAR:-default}` interpolation). |

## Where to Next?

- New user wanting to make a backup right now → read [`README.md`](../README.md) "Quick Start".
- Operator running scheduled backups via cron → [`README.md`](../README.md) "Email Notifications" + cron example sections.
- Hit a real-world failure mode → check [`issue/issue1.md`](../issue/issue1.md) and [`issue/issue2.md`](../issue/issue2.md) for two documented bugs and how the scripts now avoid them.
- Want the changelog of a specific version → [`RELEASE.md`](../RELEASE.md).