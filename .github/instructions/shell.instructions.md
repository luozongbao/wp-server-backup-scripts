---
applyTo: "**/*.sh"
description: "Conventions for the bash scripts in wp-server-backup-scripts — logging, error handling, CLI parsing, naming, Docker helpers, and the safety rules that govern restore paths. Applies when editing wp_backup.sh, wp_restore.sh, webserver_backup.sh, webserver_restore.sh, or lib/container_resolution.sh."
---

# Shell script conventions

Applies to `*.sh` at the repo root and `lib/*.sh`.

## Baseline

- Shebang `#!/bin/bash`. Target **bash 4.0+**. Avoid bash 4.3+ only features
  (`declare -n`, `local -n`) so the scripts stay portable on older hosts.
- `lib/container_resolution.sh` is **sourced, never executed**. It begins with
  `# shellcheck shell=bash` and defines functions only.
- **No `set -euo pipefail`** — see "Error handling" below.
- Indent 4 spaces; continuation lines one level deeper.

## Logging

- `log_message "message"` is the single logging entry point. It prefixes
  `[YYYY-MM-DD HH:MM:SS]` and appends to `$LOG_FILE` when that variable is set.
- `log_message "ERROR: ..."` for failures that abort a step.
- `echo "ERROR: ..." >&2` only for argument-validation errors, where the user is
  actively typing and `show_help` follows immediately.
- `init_log_file()` creates the per-run log with
  `mktemp /tmp/<script>_XXXXXX.log`.
- Only the **backup** scripts send email (`send_email_notification`, via
  `msmtp`). `webserver_restore.sh` deliberately removed its `-e` option — restore
  logs stream to the terminal instead.

## Error handling

- Functions return `0`/`1` and the caller checks:
  `if ! foo; then ...; return 1; fi`.
- Fatal paths `exit 1` after logging.
- `die()` exists **only in `wp_restore.sh`**. It logs the error and reports any
  preserved safety backups so the user can roll back. Prefer `die` over a bare
  `exit 1` there — a plain `exit 1` can leave the user unaware of where their
  pre-restore data went.
- `wp_restore.sh` keeps a global array `RESTORE_SAFETY_BACKUPS` holding
  `host:`- and `docker://`-prefixed paths. `cleanup_safety_backups()` removes
  them **only on success**.

## Naming

- Functions: `snake_case`.
- Private helpers: `_` prefix (`_dir_size`, `_execute_db_dump`, `_require_docker_or_skip`).
- Globals and config: `UPPER_CASE` (`DB_CONTAINER`, `WP_CONTAINER_DOCROOT`,
  `RESTORE_SAFETY_BACKUPS`).
- **Keep the `webservver` spelling** (double "s") in `webserver_backup.sh` and
  `webserver_restore.sh` — it is consistent across both files
  (`_webservver_image_regex`, `detect_webservver_type_from_dir`,
  `_webservver_port_regex`). Fix it in both files or neither; a partial rename
  is a net negative.

## CLI parsing — match the file you are editing

| File | Style |
|------|-------|
| `wp_backup.sh` | `getopts "w:c:d:o:le:f:v:h"` preceded by a **long-option normalisation pre-pass** that rewrites `--from=` / `--variable=` / `--help` into `-f` / `-v` / `-h`, then resets `OPTIND=1` |
| `wp_restore.sh` | GNU `getopt` + `eval set -- "$ARGS"` + `while [ $# -gt 0 ]` case loop; long options `--skip-files --skip-db --dry-run --fix-mode --reset-db --yes` |
| `webserver_backup.sh` | plain `getopts "f:o:e:h"` |
| `webserver_restore.sh` | manual `while [[ $# -gt 0 ]]` + `case "$1" in` with `shift 2` / `shift` |

Do **not** normalise the four parsers into one — that is a larger refactor than
most tasks and risks changing CLI behaviour. Add new options in the local style.

Adding a flag means updating **both** the parser and `show_help()`, including
its examples block.

## Docker helpers

- `lib/container_resolution.sh` is the canonical home for shared Docker
  resolution logic. `wp_backup.sh` and `wp_restore.sh` source it with:

````bash
# shellcheck source=lib/container_resolution.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/container_resolution.sh"
````

- The `webserver_*` scripts do **not** source it and keep their own helpers.
- DB container lookup is the **5-step chain** in
  `resolve_db_container_from_running_stack()`: exact name → compose project
  prefix (`<project>-<svc>-1`, `<project>-<svc>`) → shared Docker network with a
  WordPress container → last-resort single mariadb/mysql container. Both `wp_*`
  scripts must use the same chain, or a cross-stack backup/restore pair will
  disagree about which container to talk to.
- The chain is intentionally tolerant of `${VAR:-default}` interpolation in
  compose `container_name:` values — **never** capture the literal placeholder
  string out of `docker-compose.yml`. That was the bug in
  [docs/issues/issue003.md](../../docs/issues/issue003.md).
- `detect_container_docroot()` probes container env vars `WP_PATH`,
  `WORDPRESS_PATH`, `DOCROOT` first, then the supplied docroot, then common
  fallbacks (`/var/www/html`, `/var/www/vhosts/localhost/html`,
  `/opt/bitnami/wordpress`, `/usr/src/wordpress`, `/var/www/vhosts/<hostname>/html`).
- `container_is_running()` exists in **five** places. The `lib/` version is the
  defensive one (empty-name guard plus missing-docker guard). The `webserver_*`
  copies use `docker ps --format "table {{.Names}}"`, which emits a `NAMES`
  header line. Prefer the `lib/` behaviour for new call sites.

## Comment style

Comments explain **why**, not what. The codebase consistently documents
non-obvious behaviour: the reason for a fallback order, the failure mode a
guard prevents, the exact container path or UID involved. Match that density —
a one-line comment above a non-obvious block, and a block comment above a
function that carries a documented contract.

When you fix a subtle bug, record the root cause and the reproduction in
`docs/issues/issueNNN.md` and reference it from the relevant script comment.

## Restore-path safety

The full rules live in [AGENTS.md](../../AGENTS.md). In code:

- Guard every destructive operation with the bind-mount checks
  (`path_is_under_bind_mount`, `path_contains_bind_mount`) before `rm -rf`,
  `mv`, or `chown -R`.
- Hardlink-copy (`cp -al`) non-bind paths into the safety backup instead of
  `mv`-renaming a parent directory that contains bind mounts.
- Skip `chown` on files that live on a bind mount — the user owns those.
- Ignore a `0:0` owner read from a stale safety backup; fall back to the
  docroot owner, then `33:33`.
- Backups must use `zip -X` so archives carry no source-host UID/GID.
