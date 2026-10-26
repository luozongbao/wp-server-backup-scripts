---
applyTo: "**/*.md"
description: "Conventions for documentation in wp-server-backup-scripts — which file holds what (README vs RELEASE vs docs/), the issue post-mortem template, and link integrity rules. Applies when writing or editing README.md, RELEASE.md, docs/about.md, or docs/issues/*.md."
---

# Documentation conventions

## Which file goes where

| File | Holds | Update it when |
|------|-------|-----------------|
| [README.md](../../README.md) | User-facing reference: flags, archive formats, `.dbinfo` layout, bind-mount behaviour, cron/email setup, troubleshooting | A flag changes, a default changes, a mode is added, or behaviour users depend on changes |
| [RELEASE.md](../../RELEASE.md) | Changelog, newest at the top | Every user-visible change, under `## [Unreleased]` |
| [docs/about.md](../../docs/about.md) | Design principles, project layout, rationale, version table | Architecture or project structure changes |
| [docs/issues/](docs/issues/) | Post-mortems for real-world failures | A non-obvious bug is diagnosed and fixed |

**Link, don't duplicate.** The README is ~65 KB and the scripts carry detailed
comments. Do not copy the README's prose into a script comment or vice versa —
reference the other file instead.

## RELEASE.md

Keep the `## [Unreleased]` block at the top with all three headings present
even when empty:

````markdown
## [Unreleased]

### Added
- (none yet)

### Fixed
- (none yet)

### Removed
- (none yet)
````

Then one `## v.X.Y.Z — Short Theme` section per release, each with a `**Tag:**`
and `**Date:**` line. Reuse the vocabulary already in the file: **Added**,
**Fixed**, **Removed**, plus **Changed** when behaviour changes without being a
pure fix. Link the relevant `docs/issues/issueNNN.md` from the entry.

The version number exists **only** here and in the git tag — no script embeds a
version string.

## Issue post-mortems — `docs/issues/issueNNN.md`

Filename is zero-padded three digits: `issue003.md` exists; `issue1.md` and
`issue2.md` are referenced by the README but missing from the repo — if you add
them, use the padded form. Next new file is `issue004.md`.

Required sections, in order:

````markdown
# Issue NNN — One-line title of the failure

**Status**: Implemented | Investigating | Won't fix
**Affects**: [`script.sh`](../../script.sh) — `function_name()`
**Severity**: High | Medium | Low
**Discovered**: YYYY-MM-DD
**Reporter**: <who>

---

## TL;DR
## Reproduction
## Root Cause
## Suggested Fix
## Workaround Until Fixed
## Related
````

- `Affects` names the exact functions — the post-mortem is a map for the next
  person debugging that code.
- `Root Cause` explains the mechanism, not just the symptom.
- `Workaround Until Fixed` gives the user something to run **today**. Omit the
  section only if there genuinely is no workaround.
- `Related` cross-links sibling issues and the release notes.
- Reference code with relative links and line anchors:
  [`wp_backup.sh:339-358`](../../wp_backup.sh#L339-L358).

## Link integrity

Use relative Markdown links for in-repo targets; no absolute URLs.

**Check every link you add or move.** The repo currently has **9 broken link
instances** across [README.md](../../README.md),
[docs/about.md](../../docs/about.md) and
[docs/issues/issue003.md](../../docs/issues/issue003.md) — all pointing at two
missing documents (`issue1.md` and `issue2.md`). There is also a stale
project-layout tree in [docs/about.md](../../docs/about.md) that still shows an
`issue/` directory at the repo root. Do not add to that pile, and repair the
links when you touch the surrounding text.

To find links whose target does not exist:

````bash
cd /home/zongbao/projects/wp-server-backup-scripts
grep -rnoE '\]\([^)]*\.md(#[^)]*)?\)' --include="*.md" . \
  | sed -e 's/](\(.*\))/\1/' -e 's/#.*$//' \
  | while IFS=: read -r file line target; do
      dir=$(dirname "$file")
      [ -f "$dir/$target" ] || echo "BROKEN $file:$line -> $target"
    done
````
