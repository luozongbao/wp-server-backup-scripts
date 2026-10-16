# Issue 003 — `${VAR:-default}` interpolation in `container_name:` breaks both `-w` and `-c` backup modes

**Status**: Implemented
**Affects**: [`wp_backup.sh`](../../wp_backup.sh) — `detect_docker_database_info()`, `prepare_container_direct_mode()`, `backup_files_from_container()`
**Severity**: High — backups fail for any compose project that uses shell-style defaults in `container_name:`
**Discovered**: 2026-10-17
**Reporter**: user on `~/projects/docker-wordpress-openlitespeed/`

---

## TL;DR

Two closely related failures, both rooted in the same compose-file convention:

1. **`-w` (host path) mode** — `detect_docker_database_info()` does a naive `grep -A 10 -B 5 mariadb | grep container_name: | sed …` and stores the **literal string** `${COMPOSE_PROJECT_NAME:-wp_ols}_db` as `DB_CONTAINER`. When the script later runs `docker exec $DB_CONTAINER …`, Docker replies *"No such container"* and the backup dies.
2. **`-c` (container-direct) mode** — `WP_CONTAINER_DOCROOT` defaults to `/var/www/html`, but the litespeedtech/openlitespeed image ships WordPress under `/var/www/vhosts/localhost/html` (configurable via the `WP_PATH` env var). The script's `prepare_container_direct_mode()` checks `docker exec "$container" test -f $docroot/wp-config.php` and aborts because `/var/www/html/wp-config.php` does not exist.

Both bugs surface immediately on the `docker-wordpress-openlitespeed` reference stack, but the same composition patterns are common in any project that parameterises compose names. They affect every user whose compose file uses either convention.

---

## Reproduction

### Stack used to reproduce

`~/projects/docker-wordpress-openlitespeed/docker-compose.yml` excerpt (the `container_name:` lines use `${VAR:-default}` interpolation):

```yaml
services:
  wordpress:
    image: litespeedtech/openlitespeed:latest
    container_name: ${COMPOSE_PROJECT_NAME:-wp_ols}_app
    volumes:
      - ./www:/var/www/vhosts/localhost/html
    environment:
      - WP_PATH=${WP_PATH:-/var/www/vhosts/localhost/html}
    networks: [app-network]
  database:
    image: mariadb:10.11
    container_name: ${COMPOSE_PROJECT_NAME:-wp_ols}_db
    networks: [app-network]
```

When started with the default project name, the actual running containers are:

| Service     | Image                              | Resolved container name |
|-------------|------------------------------------|-------------------------|
| `wordpress` | `litespeedtech/openlitespeed:latest` | `ols_app`               |
| `database`  | `mariadb:10.11`                    | `ols_db`                |
| `phpmyadmin`| `phpmyadmin:latest`                | `phpmyadmin`            |

### Failure A — `./wp_backup.sh -w ../docker-wordpress-openlitespeed/www/`

```
[2026-10-17 00:45:21] Checking for Docker environment...
[2026-10-17 00:45:21] Found docker-compose.yml at: /home/zongbao/projects/docker-wordpress-openlitespeed/docker-compose.yml
[2026-10-17 00:45:21] Detected Docker environment with database service
[2026-10-17 00:45:21] Analyzing docker-compose.yml for database configuration...
[2026-10-17 00:45:21] Detected database type: MariaDB
[2026-10-17 00:45:21] Database container: ${COMPOSE_PROJECT_NAME:-wp_ols}_db
[2026-10-17 00:45:21] Starting WordPress Backup process
…
[2026-10-17 00:45:21] Database configuration extracted successfully
[2026-10-17 00:45:21] Database: dbname on database
[2026-10-17 00:45:21] Creating database backup using Docker...
[2026-10-17 00:45:21] ERROR: Database container '${COMPOSE_PROJECT_NAME:-wp_ols}_db' is not running
[2026-10-17 00:45:21] Please start your Docker containers first
[2026-10-17 00:45:21] ERROR: Docker database backup failed
```

The script *correctly* extracted `dbname on database` from `wp-config.php` (i.e. `DB_HOST=database`, the compose **service** name — which works for the in-network connection that WordPress actually uses), but it then tried to talk to a container that does not exist.

### Failure B — `./wp_backup.sh -c ols_app`

```
[2026-10-17 00:51:55] Preparing container-direct mode for container: ols_app
[2026-10-17 00:51:55] Document root inside container: /var/www/html
[2026-10-17 00:51:55] ERROR: wp-config.php not found at /var/www/html/wp-config.php inside container 'ols_app'
```

The container is running and healthy — but `wp-config.php` lives at `/var/www/vhosts/localhost/html/wp-config.php` inside it, not at the default docroot.

---

## Root Cause

### Failure A — `DB_CONTAINER` is stored as a literal `container_name:` string

[`wp_backup.sh:339-358`](../../wp_backup.sh#L339-L358):

```bash
local container_line=$(grep -A 10 -B 5 "$DB_TYPE" "$compose_file" | grep -E "container_name:" | head -1)
if [ -n "$container_line" ]; then
    DB_CONTAINER=$(echo "$container_line" | sed 's/.*container_name:\s*//' | tr -d '"' | tr -d "'" | xargs)
fi
```

The script reads the YAML **as text** and stores the literal line. Compose interpolation `${COMPOSE_PROJECT_NAME:-wp_ols}_db` is not shell `${VAR:-default}` syntax (it would need to also resolve via `eval`), and even if it were, `COMPOSE_PROJECT_NAME` is not exported into the shell that runs the script (it lives in the shell that ran `docker compose up`). The result: `DB_CONTAINER` is the unreadable placeholder string `${COMPOSE_PROJECT_NAME:-wp_ols}_db`, and `docker exec` later reports "No such container".

The fallback at lines 348-350 is also unreliable — for this stack it captures the `networks:` key instead of the `database:` service name:

```
$ grep -B 5 -A 10 mariadb docker-compose.yml | grep -E '^\s*[a-zA-Z0-9_-]+:' | head -1
    networks:
```

Worse: even if the fallback finds the service name `database`, the *resolved* container is `<project>_db` (here `ols_db`), not `database`. Compose's naming rule is `<project>-<service>-N` by default, plus the explicit `container_name:` override here.

### Failure B — Hard-coded `/var/www/html` default docroot

[`wp_backup.sh:24`](../../wp_backup.sh#L24):

```bash
WP_CONTAINER_DOCROOT="/var/www/html"
```

…and [`wp_backup.sh:516-546`](../../wp_backup.sh#L516-L546) in `prepare_container_direct_mode()`:

```bash
if ! docker exec "$container" test -f "$docroot/wp-config.php" 2>/dev/null; then
    log_message "ERROR: wp-config.php not found at $docroot/wp-config.php inside container '$container'"
    return 1
fi
```

The litespeedtech/openlitespeed image puts WordPress under `/var/www/vhosts/localhost/html` by default, with `WP_PATH` env var to override it. The official WordPress image (`wordpress:apache` / `wordpress:cli`) actually uses `/var/www/html`, so the default is sensible for that image but wrong for any other WP-in-container image.

`-d` *can* be passed explicitly:

```bash
./wp_backup.sh -c ols_app -d /var/www/vhosts/localhost/html -o ~/backups/
```

…but the user reasonably expected `-c` to "just work" because the container was running. There is no `-d` example in the help text for the OLS image's actual layout, no auto-detection of the docroot, and no clear hint that `-d` is required.

---

## Why This Is a Real Bug (Not User Error)

- The README claims `wp_backup.sh -c <name> -o <dir>` works on the official WordPress image with "no folder mapping required". The litespeedtech/openlitespeed image is the *only* image in the `docker-wordpress-openlitespeed` reference repo and is by far the most common self-hosted WordPress image on homelabs. The script's contract should hold for it too.
- The `-w` mode's failure is a clear bug: `DB_CONTAINER` should never be the literal `${VAR:-default}_db` placeholder string when there is a working `DB_HOST` available from `wp-config.php`. `DB_HOST=database` is a **service** name; the resolved container on the host is `ols_db`. The script must bridge that gap.
- The compose-file parser at [`webserver_backup.sh`](../../webserver_backup.sh) and [`webserver_restore.sh`](../../webserver_restore.sh) already has a `${VAR:-default}` resolver (`resolve_host_port()` plus `load_compose_env()`) — see the v.1.1.0 release notes for context. The same machinery should be reused in `wp_backup.sh`.

---

## Suggested Fix

### For Failure A (DB container resolution)

Replace the placeholder capture with the same 5-step fallback chain used in [`wp_restore.sh` `resolve_db_container_from_running_stack()`](../../wp_restore.sh):

1. **`DB_HOST=database`** — `database` doesn't literally exist; try the compose project prefix → `ols_db`.
2. **`docker inspect` of the WP container's networks** — find mariadb/mysql containers on the same network → `ols_db`.
3. **Last-resort** — pick the only mariadb/mysql container running on the host → `ols_db`.

Algorithm (pseudocode):

```bash
resolve_db_container() {
    local db_host="$1"  # e.g. "database"
    local svc="${db_host%%:*}"

    # 1. Exact match
    if docker ps --format '{{.Names}}' | grep -qx "$svc"; then
        echo "$svc"; return 0
    fi

    # 2. Compose project prefixes derived from WP container
    local wp="$WP_CONTAINER"  # "ols_app"
    local project
    project=$(echo "$wp" | sed -E 's/-[0-9]+$//; s/-[a-z]+$//')  # "ols"
    for cand in "${project}-${svc}-1" "${project}-${svc}" "${project}_${svc}-1" "${project}_${svc}"; do
        if docker ps --format '{{.Names}}' | grep -qx "$cand"; then
            echo "$cand"; return 0
        fi
    done

    # 3. Shared network with the WP container
    local nets
    nets=$(docker inspect "$wp" --format '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)
    for net in $nets; do
        docker network inspect "$net" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
            | tr ' ' '\n' \
            | while read -r cand; do
                [ "$cand" = "$wp" ] && continue
                local img
                img=$(docker inspect "$cand" --format '{{.Config.Image}}' 2>/dev/null)
                case "$img" in *mariadb*|*mysql*) echo "$cand"; return 0 ;; esac
            done
    done

    # 4. Last-resort: only mariadb/mysql container on the host
    docker ps --format '{{.Names}}\t{{.Image}}' \
        | awk 'tolower($2) ~ /mariadb|mysql/ {print $1; exit}'

    return 1
}
```

This **already exists** in `wp_restore.sh` as `resolve_db_container_from_running_stack()` (and is invoked twice during restore — once before extraction, once after `.dbinfo` is populated). Refactor it into a shared helper (e.g. `lib/container_resolution.sh`) sourced by both scripts, then call it from `wp_backup.sh` whenever `DB_CONTAINER` cannot be resolved from `container_name:` directly.

### For Failure B (docroot discovery in `-c` mode)

Two complementary changes:

1. **Probe before failing** — in `prepare_container_direct_mode()`, if the user-supplied (or default) `$docroot` does not contain `wp-config.php`, try a small list of common locations before aborting:

   ```bash
   for try in "$docroot" "/var/www/html" "/var/www/vhosts/localhost/html" "/var/www/vhosts/${HOSTNAME:-localhost}/html"; do
       if docker exec "$container" test -f "$try/wp-config.php" 2>/dev/null; then
           WP_CONTAINER_DOCROOT="$try"
           log_message "Detected docroot inside container: $WP_CONTAINER_DOCROOT"
           break
       fi
   done
   ```

2. **Read `WP_PATH` from the container's env** — `litespeedtech/openlitespeed` exposes `WP_PATH` (and `WP_USER` / `WP_GROUP`) precisely so tools outside the container can locate the docroot. Probe it:

   ```bash
   local wp_path
   wp_path=$(docker exec "$container" printenv WP_PATH 2>/dev/null || true)
   if [ -n "$wp_path" ] && docker exec "$container" test -f "$wp_path/wp-config.php" 2>/dev/null; then
       WP_CONTAINER_DOCROOT="$wp_path"
   fi
   ```

3. **Refuse to silently mis-back-up** — if after the probe we still can't find `wp-config.php`, the error message should list the paths that *were* checked (so the user can pass `-d` confidently):

   ```
   ERROR: wp-config.php not found in container 'ols_app'.
   Tried: /var/www/html, /var/www/vhosts/localhost/html, /var/www/vhosts/$(hostname)/html
   Re-run with -d <path> to specify the document root explicitly.
   ```

4. **Help text** — extend the `-c` example in `show_help()` to include the `-d` flag for the OLS image so the workaround is discoverable:

   ```text
   # Container-direct (OLS image: docroot is /var/www/vhosts/localhost/html)
   $0 -c ols_app -d /var/www/vhosts/localhost/html -o /backups
   ```

---

## Workaround Until Fixed

```bash
# Failure A: nothing the user can do — DB_CONTAINER is computed inside the script.
# Patch: pre-export COMPOSE_PROJECT_NAME so the literal `${VAR:-default}` resolves,
# then the literal string becomes the real container name:
export COMPOSE_PROJECT_NAME=ols   # or whatever docker compose -p <name> uses
./wp_backup.sh -w ../docker-wordpress-openlitespeed/www/ -o ~/backups/

# Failure B: pass -d explicitly:
./wp_backup.sh -c ols_app -d /var/www/vhosts/localhost/html -o ~/backups/
```

(Both verified working as of 2026-10-17 against `~/projects/docker-wordpress-openlitespeed/`.)

---

## Related

- [`issue/issue1.md`](../../issue/issue1.md) — bind-mount `rm -rf` walking into a host directory (resolved in v.1.1.0)
- [`issue/issue2.md`](../../issue/issue2.md) — `wp-config.php` ownership after `docker cp` (resolved in v.1.1.0)
- [RELEASE.md v.1.1.0 — `${VAR:-default}` interpolation for port heuristic](../../RELEASE.md) — `webserver_*` scripts already have the resolver this issue is asking for
- [`wp_restore.sh` `resolve_db_container_from_running_stack()`](../../wp_restore.sh) — the existing 5-step chain that should be hoisted into a shared helper