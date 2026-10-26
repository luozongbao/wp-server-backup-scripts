---
name: verify-scripts
description: "Verify changes to the wp-server-backup-scripts bash suite. Use when editing, refactoring, or fixing wp_backup.sh, wp_restore.sh, webserver_backup.sh, webserver_restore.sh, or lib/container_resolution.sh — this repo has NO test suite and NO CI, so verification is a manual procedure that must be run explicitly before a change can be called done. Triggers: backup script change, restore script change, shell script edit, verify, test, check the scripts, sanity check, before releasing."
---

# Verifying the backup scripts

This repo ships **no automated tests, no CI, and no test framework**. A change
to a `.sh` file is verified by nothing except the steps below. Skipping them
means shipping unverified destructive code.

## What is and is not available

| Tool | State |
|------|-------|
| `bash` | 5.2.x — syntax check with `bash -n` |
| `docker` | installed; a stack may or may not be running (`docker ps`) |
| `shellcheck` | **not installed**, and there is no `.shellcheckrc` — never report results for it |
| `docker compose` | may be present; check before relying on it |
| Test suite | **none exists** |
| CI | **none exists** |

## Level 1 — always run (seconds, no side effects)

````bash
cd /home/zongbao/projects/wp-server-backup-scripts
for f in *.sh lib/*.sh; do bash -n "$f" && echo "OK   $f" || echo "FAIL $f"; done
for f in wp_backup.sh wp_restore.sh webserver_backup.sh webserver_restore.sh; do
  ./"$f" -h >/dev/null 2>&1 && echo "OK   $f -h" || echo "FAIL $f -h"
done
````

Both loops must print `OK` for every file. `-h` exits before the root check, so
it works as a non-root user.

If you have installed `shellcheck`, run it as well:

````bash
shellcheck -x *.sh lib/*.sh
````

## Level 2 — targeted behaviour check

Pick the check matching what you changed:

| Change | Check |
|--------|-------|
| New/changed CLI flag | `./<script> --help` lists it; a missing required argument is rejected cleanly; `show_help()` was updated, including its examples block |
| `lib/container_resolution.sh` change | Exercise the chain against a live stack — see Level 3 |
| DB container discovery change | The chain still resolves in order: exact → compose prefix → shared network → single-DB fallback. `DB_CONTAINER` must never end up as a literal `${VAR:-default}` string |
| Docroot probing change | `./wp_backup.sh -c <container>` finds `wp-config.php` on a non-`/var/www/html` image (e.g. `litespeedtech/openlitespeed`) **without** `-d` |
| Backup change | Run a real backup into a temp dir and inspect the archive: `unzip -l` shows the files, `unzip -p <zip> .dbinfo` shows resolved (non-placeholder) credentials |
| Restore change | **Always** test against a disposable target, never a live site — see Level 3 |
| Ownership / chown change | Restored files are owned per `map_default_owner_for_type()` (Apache `root:www-data`, Nginx `root:root`, OLS `nobody:nogroup`) or `33:33` inside a WP container |
| Email change | `send_email_notification` needs `msmtp`. Verify the `From:` resolution order: `-f` → `-v` env file → `./wp_backup.env` → `/etc/wp-server-backup-script.env` → `~/.msmtprc` |

## Level 3 — live-stack verification

Only run this against a **disposable** stack, never a production site.

````bash
docker ps                                   # find a WP container + a DB container
````

**Round-trip check** (backup → inspect archive):

````bash
TMP=$(mktemp -d)
./wp_backup.sh -c <wp_container> -o "$TMP"
ls -l "$TMP"                                # expect YYYYMMDD_HHMMSS_<name>.zip
unzip -l "$TMP"/*.zip | head -30            # files + database.sql + .dbinfo
unzip -p "$TMP"/*.zip .dbinfo               # DB_HOST must be a real service/container, never "wordpress"
````

**Bind-mount safety check** — the highest-risk behaviour in the repo. The
expected results are documented in
[README.md](../../../README.md#verification-after-a-restore):

````bash
docker exec <wp_container> bash -c '
  stat -c "%n %U:%G" /var/www/html/wp-config.php /var/www/html/wp-content/themes/<bind-mounted-theme>
  grep -E "<bind-mounted-theme>" /proc/self/mountinfo
  ls -la /var/www/html/ | grep backup || echo "(no orphans)"
'
````

Expected: `wp-config.php` → `www-data:www-data 33:33`; the bind mount
destination still at its original path (not nested inside a `.backup.<ts>/`
directory); no `.backup.<ts>` orphans left in the docroot; host-side theme and
plugin files untouched (compare mtimes before and after).

## Level 4 — restore safety gate

Before shipping any change to `wp_restore.sh` or `webserver_restore.sh`,
confirm all four invariants still hold:

1. No `rm -rf` / `mv` path can reach a bind mount destination. Every
   destructive call is guarded by `path_is_under_bind_mount` /
   `path_contains_bind_mount`.
2. A failed restore **preserves** the safety backup and tells the user where it
   is — `die()` prints the `RESTORE_SAFETY_BACKUPS` entries.
3. The scripts still refuse to run as non-root.
4. `--dry-run` still produces a preview and touches nothing.

Check (3) mechanically:

````bash
./wp_restore.sh -b /nonexistent.zip -w /tmp/scratch   # must fail fast, not half-restore
./webserver_restore.sh -b /nonexistent.zip             # must fail fast
````

## Reporting

State what you actually ran. If a level could not be run — no Docker stack, no
`msmtp`, no disposable target — say so explicitly rather than implying the
change is verified. There is no CI to catch what you skipped.
