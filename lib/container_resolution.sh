# shellcheck shell=bash
#
# lib/container_resolution.sh - shared helpers for resolving Docker
# containers (DB container, WordPress container docroot).
#
# Sourced by both wp_backup.sh and wp_restore.sh. Must NOT be executed
# directly — it defines shell functions only.
#
# Provided helpers:
#   resolve_db_container_from_running_stack <DB_HOST> [WP_CONTAINER] [VARNAME]
#   detect_container_docroot <CONTAINER> [INITIAL_DOCROOT] [VARNAME]
#   container_is_running <NAME>
#
# Calling convention: helpers write their result into the named variable
# (default: $DB_CONTAINER / $WP_CONTAINER_DOCROOT) and return 0 on success,
# 1 on failure. This avoids the "$(... )" command-substitution pattern that
# would force ALL log output to stderr.
#
# All functions are tolerant of:
#   - Missing docker binary (degrade gracefully — return non-zero).
#   - Empty / unset arguments.
#   - Compose file with `${VAR:-default}` interpolation in container_name.
#   - Cross-stack restores (backup taken on stack A, restored on stack B).

# require_docker: bail out of the calling helper if `docker` is missing.
# Centralizes the "is docker installed?" guard so individual helpers stay
# focused on their own logic.
_require_docker_or_skip() {
    if ! command -v docker &>/dev/null; then
        return 1
    fi
    return 0
}

# container_is_running: 0 if a container with this exact name is currently
# running (not merely existing). Wraps `docker ps --format`. Returns
# non-zero on missing/stopped container or absent docker CLI.
#
# This is intentionally tolerant of missing docker so callers (e.g. a
# native-mode path) don't have to special-case it.
container_is_running() {
    local name="$1"
    [ -z "$name" ] && return 1
    _require_docker_or_skip || return 1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"
}

# _list_running_containers: emit one running container name per line.
# Returns 1 if docker is missing or no containers are running.
_list_running_containers() {
    _require_docker_or_skip || return 1
    docker ps --format '{{.Names}}' 2>/dev/null
}

# _wp_container_from_running_list: pick a "likely WordPress container"
# from the running list when no explicit WP_CONTAINER was given. Used
# as a fallback so we can derive the compose project name on hosts where
# the user passed only `DB_HOST=db` and the script is auto-discovering.
#
# Naming heuristic — anything that ends in:
#   - "wordpress" / "wp"             (hand-curated service names)
#   - "-wordpress-<N>" / "-wp-<N>"   (compose default naming)
#   - "_wordpress-<N>" / "_wp-<N>"   (compose with explicit container_name)
_wp_container_from_running_list() {
    local running="$1"
    echo "$running" \
        | grep -E '(wordpress|wp)$|-wordpress-[0-9]+$|-wp-[0-9]+$|_wordpress-[0-9]+$|_wp-[0-9]+$' \
        | head -1
}

# _derive_compose_project_from_container: strip the trailing "-<digits>"
# (compose replica suffix) and the service name from a container like
# "ols_db-1" -> "ols". Best-effort; returns empty on weird input.
_derive_compose_project_from_container() {
    local name="$1"
    [ -z "$name" ] && return 0
    local base="${name%-[0-9]*}"
    if [ "$base" != "$name" ]; then
        echo "${base%-*}"
    else
        echo "${name%-*}"
    fi
}

# resolve_db_container_from_running_stack <DB_HOST> [WP_CONTAINER] [VARNAME]
#
# Find the database container that corresponds to <DB_HOST>, even when
# the literal string in the compose file is `${COMPOSE_PROJECT_NAME:-...}_db`
# or similar shell-style interpolation that Docker can't resolve.
#
# Output variable: $3 (default: DB_CONTAINER). Empty on failure.
#
# Strategy chain (first hit wins; mirrors v.1.1.0 contract documented
# in README.md):
#   1. Exact match: a running container literally named "<svc>"
#   2. Compose v2 -N: "<project>-<svc>-1"
#   3. Compose v2:    "<project>-<svc>"
#   4. Shared docker network with a known WordPress container
#   5. Last-resort: any running mariadb/mysql container on the host
#
# Skips strategy chain for obviously non-container hosts
# (localhost, 127.0.0.1, 0.0.0.0, ::1).
resolve_db_container_from_running_stack() {
    local db_host="${1:-}"
    local wp_container="${2:-${WP_CONTAINER:-}}"
    local out_var="${3:-DB_CONTAINER}"

    [ -z "$db_host" ] && return 1

    # Strip optional port (e.g. "db:3306" -> "db")
    local svc="${db_host%%:*}"
    [ -z "$svc" ] && return 1

    case "$svc" in
        localhost|127.0.0.1|0.0.0.0|::1) return 1 ;;
    esac

    if ! _require_docker_or_skip; then
        return 1
    fi

    local running
    running=$(_list_running_containers) || return 1
    [ -z "$running" ] && return 1

    # 1. Exact match
    if echo "$running" | grep -qx "$svc"; then
        printf -v "$out_var" '%s' "$svc"
        log_message "Resolved DB container (exact name): ${!out_var}"
        return 0
    fi

    # 2/3. Compose project prefixes — derive the project name from the WP
    # container so we don't guess wrong. Both "<project>-<svc>-1" (numeric
    # suffix from compose v2) and "<project>-<svc>" (no suffix, used by
    # stacks with explicit container_name) are tried.
    local project=""
    if [ -n "$wp_container" ] && echo "$running" | grep -qx "$wp_container"; then
        project=$(_derive_compose_project_from_container "$wp_container")
    fi
    if [ -z "$project" ]; then
        local wp_candidate
        wp_candidate=$(_wp_container_from_running_list "$running")
        if [ -n "$wp_candidate" ]; then
            project=$(_derive_compose_project_from_container "$wp_candidate")
        fi
    fi
    if [ -n "$project" ]; then
        for cand in "${project}-${svc}-1" "${project}-${svc}"; do
            if echo "$running" | grep -qx "$cand"; then
                printf -v "$out_var" '%s' "$cand"
                log_message "Resolved DB container (compose project '$project'): ${!out_var}"
                return 0
            fi
        done
    fi

    # 4. Network-based: any mariadb/mysql container that shares a network
    # with a running WordPress container. Looks at the literal
    # `docker network inspect` output (Names of attached containers).
    local wp_for_net=""
    if [ -n "$wp_container" ] && echo "$running" | grep -qx "$wp_container"; then
        wp_for_net="$wp_container"
    else
        wp_for_net=$(_wp_container_from_running_list "$running")
    fi
    if [ -n "$wp_for_net" ]; then
        local wp_netids
        wp_netids=$(docker inspect "$wp_for_net" \
            --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null) || true
        for net in $wp_netids; do
            local candidates
            candidates=$(docker network inspect "$net" \
                --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null) || continue
            for cand in $candidates; do
                # Strip leading "/" that `docker network inspect` sometimes
                # leaves on container names (id/prefix edge cases).
                cand="${cand#/}"
                [ -z "$cand" ] && continue
                if [ "$cand" = "$wp_for_net" ]; then continue; fi
                local img
                img=$(docker inspect "$cand" --format '{{.Config.Image}}' 2>/dev/null) || true
                case "$img" in
                    *mariadb*|*mysql*)
                        printf -v "$out_var" '%s' "$cand"
                        log_message "Resolved DB container (shared network with WP): ${!out_var} (image=$img)"
                        return 0
                        ;;
                esac
            done
        done
    fi

    # 5. Last resort: any running mariadb/mysql container. Useful when the
    # host only runs a single DB stack and we just don't know its name.
    local any
    any=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
        | awk 'tolower($2) ~ /mariadb|mysql/ && $2 !~ /^(wordpress|wp):/ {print $1; exit}')
    if [ -n "$any" ]; then
        printf -v "$out_var" '%s' "$any"
        log_message "Resolved DB container (fallback: any running mariadb/mysql): ${!out_var}"
        return 0
    fi

    return 1
}

# detect_container_docroot <CONTAINER> [INITIAL_DOCROOT] [VARNAME]
#
# Probe a running WordPress container to find the document root. Many
# images don't use the canonical /var/www/html; in particular:
#   - litespeedtech/openlitespeed   -> /var/www/vhosts/localhost/html
#                                       (configurable via $WP_PATH)
#   - bitnami/wordpress             -> /opt/bitnami/wordpress
#   - wodby/wordpress              -> /var/www/html
#
# Strategy:
#   1. If $WP_PATH (or $WORDPRESS_PATH / $DOCROOT) is set in the
#      container's environment and contains wp-config.php, use it.
#   2. Try the initial docroot (the user's -d value, or the script's
#      default).
#   3. Try a small set of common locations.
#
# Output variable: $3 (default: WP_CONTAINER_DOCROOT). Empty on failure.
# Returns 0 if a docroot was found, 1 otherwise.
detect_container_docroot() {
    local container="$1"
    local initial="${2:-/var/www/html}"
    local out_var="${3:-WP_CONTAINER_DOCROOT}"

    _require_docker_or_skip || return 1

    if ! docker inspect "$container" >/dev/null 2>&1; then
        return 1
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" != "true" ]; then
        return 1
    fi

    # Helper: returns 0 if "$1/wp-config.php" exists inside the container.
    _docroot_has_wp_config() {
        local d="$1"
        docker exec "$container" test -f "$d/wp-config.php" >/dev/null 2>&1
    }

    # 1. Environment hints — many images expose the docroot as an env var
    # specifically so external tools can find it.
    local env_var
    for env_var in WP_PATH WORDPRESS_PATH DOCROOT; do
        local val
        val=$(docker exec "$container" printenv "$env_var" 2>/dev/null || true)
        # Strip surrounding whitespace / quotes; printenv returns empty
        # for unset, which we'll skip.
        val="${val#"${val%%[![:space:]]*}"}"   # ltrim
        val="${val%"${val##*[![:space:]]}"}"   # rtrim
        val="${val%\"}"; val="${val#\"}"
        val="${val%\'}"; val="${val#\'}"
        [ -z "$val" ] && continue
        if _docroot_has_wp_config "$val"; then
            printf -v "$out_var" '%s' "$val"
            log_message "Detected docroot from \$${env_var}: ${!out_var}"
            return 0
        fi
    done

    # 2. The value the user (or the script default) supplied.
    if _docroot_has_wp_config "$initial"; then
        printf -v "$out_var" '%s' "$initial"
        log_message "Using supplied docroot: ${!out_var}"
        return 0
    fi

    # 3. Common fallback locations. The OLS image's default appears first
    # because the failure was originally reported against it, but every
    # known path is tried.
    local common_paths=(
        "/var/www/html"
        "/var/www/vhosts/localhost/html"
        "/opt/bitnami/wordpress"
        "/usr/src/wordpress"
        "/var/www/vhosts/$(hostname 2>/dev/null)/html"
    )
    for d in "${common_paths[@]}"; do
        if _docroot_has_wp_config "$d"; then
            printf -v "$out_var" '%s' "$d"
            log_message "Detected docroot via fallback probe: ${!out_var}"
            return 0
        fi
    done

    return 1
}
