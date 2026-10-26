# AGENTS.md — wp-server-backup-scripts

Production bash tooling that backs up and restores WordPress installations and
their webserver configuration, on both Docker and native hosts.

## Repository layout

| Path | Role |
|------|------|
| [wp_backup.sh](wp_backup.sh) | WordPress backup (full / lightweight; host path `-w` or container-direct `-c`) |
| [wp_restore.sh](wp_restore.sh) | WordPress restore. Largest file (~3.3k lines) — most of the safety logic lives here |
| [webserver_backup.sh](webserver_backup.sh) | Webserver config backup (Apache / OpenLiteSpeed / Nginx) |
| [webserver_restore.sh](webserver_restore.sh) | Webserver config restore |
| [lib/container_resolution.sh](lib/container_resolution.sh) | Shared Docker helpers: 5-step DB-container discovery chain + container docroot auto-probe. Sourced by `wp_backup.sh` and `wp_restore.sh` **only** |
| [README.md](README.md) | User-facing reference — flags, archive formats, `.dbinfo` layout, bind-mount behaviour, cron/email setup |
| [RELEASE.md](RELEASE.md) | Changelog. New work goes under `## [Unreleased]` |
| [docs/about.md](docs/about.md) | Design principles, project layout, rationale |
| [docs/issues/](docs/issues/) | Post-mortems for real-world failures (`issueNNN.md`) |

There is **no build system, no test suite, and no CI**. Do not look for
`make test`, `npm test`, or a `tests/` directory — they do not exist.

## How to verify a change

Validation is manual because nothing runs automatically. These checks work in
this environment:

````bash
bash -n wp_restore.sh            # syntax check — all 5 files pass today
./wp_restore.sh -h               # help/smoke test — exits 0, works as non-root
````

- `shellcheck` is **not installed** and there is no `.shellcheckrc`. Do not
  report a script as "shellcheck-clean" unless you actually installed and ran it.
- Docker **is** available (`/usr/bin/docker`), but no stack is guaranteed to be
  running. Check `docker ps` before relying on container behaviour.
- The restore scripts require **root** (`id -u` must be `0`); they abort with a
  "use sudo" message otherwise. `-h` still works as a non-root user.

For the full verification workflow — including how to exercise the DB-resolution
chain and bind-mount safety against a live stack — use the `verify-scripts`
skill.

## Conventions that differ from common defaults

Full list in [`.github/instructions/shell.instructions.md`](.github/instructions/shell.instructions.md).
The ones most likely to surprise you:

- **No `set -euo pipefail`.** These scripts handle errors explicitly
  (`log_message "ERROR: ..."` plus `return 1` / `exit 1`). Do not introduce
  `set -e` — it changes runtime behaviour of code paths that rely on non-zero
  probes inside `if` / `||` chains.
- **Four different CLI parsers.** Follow the style already in the file you are
  editing rather than normalising across the repo.
- **`webservver` (double "s") is a deliberate, consistent spelling** in
  `webserver_backup.sh` and `webserver_restore.sh`. Renaming one instance
  breaks the symmetry; rename all or none.
- **`container_is_running()` exists in five places** with three different
  implementations. The `lib/` version is the canonical, most defensive one.

## Safety rules — non-negotiable

Restore code deletes and re-owns live server files. These invariants are
load-bearing; breaking them destroys user data.

1. **Never `rm -rf` or `mv` across a bind mount.** WordPress containers often
   layer host bind mounts (e.g. `./mytheme/` → `/var/www/html/wp-content/themes/MyTheme`)
   over a named volume. The kernel tracks bind mounts by *path*, not inode, so a
   rename of the parent leaves the mount visible inside the safety backup and a
   later `rm -rf` unlinks the user's host files. `wp_restore.sh` detects mounts
   via `/proc/self/mountinfo` (`detect_container_bind_mounts`,
   `path_is_under_bind_mount`, `path_contains_bind_mount`) and must keep every
   destructive path outside those subtrees.
2. **Safety backups are preserved on failure.** Existing targets are moved aside
   to `<target>.backup.<timestamp>` and are only removed after a successful run.
   Failures must leave them on disk and tell the user where they are.
3. **Ownership must match the webserver.** `map_default_owner_for_type()` maps
   Apache → `root:www-data`, Nginx → `root:root`, OpenLiteSpeed → `nobody:nogroup`,
   fallback `root:root`. WordPress containers use `33:33` (www-data). Getting this
   wrong produces "Permission denied" on uploads and plugin updates rather than a
   visible error.
4. **Archives stay portable.** Backups use `zip -X` to strip the source host's
   UID/GID. Do not drop the `-X` flag.

## Documentation map — link, don't duplicate

- User-facing flags, archive formats, `.dbinfo` layout, cron examples → [README.md](README.md)
- Changelog and version history → [RELEASE.md](RELEASE.md)
- Design rationale and project layout → [docs/about.md](docs/about.md)
- Failure post-mortems → [docs/issues/](docs/issues/)
- New issue write-up format → [`.github/instructions/docs.instructions.md`](.github/instructions/docs.instructions.md)

## Release process

- The version lives **only** in `RELEASE.md` and the git tag. No script embeds a
  version string, so a release never requires editing the `.sh` files.
- Add entries under `## [Unreleased]` → `### Added` / `### Fixed` / `### Removed`.
  Those three headings are always present; keep them even when empty.
- Git tags in this repo are inconsistent (`v.1.0`, `v.1.0.0`, `v.1.1.1`, `v1.1.0`).
  Follow the newest convention (`v.1.1.1`) rather than adding another variant.
- Default branch is `dev`; `main` is the remote HEAD. Branch names are descriptive
  (`issue003`, `refactor-wp_restore.sh`).

## Known repo issues — fix opportunistically

- `docs/issues/issue1.md` and `docs/issues/issue2.md` are **linked but missing** —
  9 broken link instances across [README.md](README.md),
  [docs/about.md](docs/about.md) and [docs/issues/issue003.md](docs/issues/issue003.md),
  all pointing at those two documents. Either write the files or repoint the links.
- [docs/about.md](docs/about.md) still shows an `issue/` directory at the repo root
  (now `docs/issues/`), and its version table is missing `v.1.1.1`.
- `.gitignore` is **empty** — generated `*.zip` backup archives can be committed
  by accident.
- The `webserver_*` scripts do not source `lib/container_resolution.sh` and carry
  their own `container_is_running()` and webserver-detection helpers.
