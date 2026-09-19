#!/bin/bash

# WordPress Restore Script
# Restores WordPress files and database from backup created by wp_backup.sh
# Auto-detects Docker or native database services
# Usage: ./wp_restore.sh -b /path/to/backup.zip -w /path/to/wordpress

# Default values
BACKUP_FILE=""
WORDPRESS_DIR=""
SHOW_HELP=false
DB_TYPE=""
DB_CONTAINER=""
IS_DOCKER=false
BACKUP_MODE=""
# Resolved DB config from .dbinfo sidecar (preferred over parsing
# wp-config.php, which may use env-based helpers and produce wrong values).
BACKUP_DB_NAME=""
BACKUP_DB_USER=""
BACKUP_DB_PASSWORD=""
BACKUP_DB_HOST=""
BACKUP_DB_TYPE=""
BACKUP_DB_CONTAINER=""
BACKUP_SOURCE=""
# Container-direct mode: restore files into a running WordPress Docker
# container using 'docker cp' instead of writing to a host path. Use when
# WordPress lives in a named volume (no host bind mount).
WP_CONTAINER=""
WP_CONTAINER_DOCROOT="/var/www/html"
# Tracks backup paths created as safety net during restore (e.g. www.backup.<TS>).
# These are auto-removed on SUCCESS, but PRESERVED on ERROR so the user can
# roll back manually if anything went wrong mid-restore.
declare -a RESTORE_SAFETY_BACKUPS=()

# Post-restore customization options
NEW_URL=""                  # Replace site URL throughout database (e.g., http://localhost:8088)
OLD_URL=""                  # Old URL to search for (auto-detected from backup if empty)
NEW_TITLE=""                # New site title (updates blogname option)
ADMIN_USER=""               # New admin username to create/update
ADMIN_PASSWORD=""           # Admin password (requires ADMIN_USER)
ADMIN_EMAIL=""              # Admin email (requires ADMIN_USER)
SKIP_FILES=false            # If true, skip file restoration
SKIP_DB=false               # If true, skip database restoration
DRY_RUN=false               # If true, print actions without executing
FIX_MODE=false              # If true, skip restore entirely; only run post-restore customizations
                            # (URL/title/admin) against the live site. In this mode
                            # -b is OPTIONAL (no backup needed) and -w is required so we can read
                            # wp-config.php to get DB credentials from the live installation.
# Reset-DB flow: read credentials + table_prefix from the LIVE wp-config.php
# (target container/host BEFORE we overwrite files), DROP all tables with
# that prefix, then IMPORT the backup's database. Finally, patch the
# restored wp-config.php so its $table_prefix matches the backup (creds
# stay from the live config so they always work).
#
# In -c mode (container-direct) this is the DEFAULT — solves the
# "container from .dbinfo doesn't exist anymore" cross-stack restore
# problem by ignoring .dbinfo entirely and trusting the live config that
# WordPress actually uses to connect. In -w mode it's opt-in (-r/--reset-db)
# because host-mode restores are more sensitive to destructive ops.
RESET_DB=false
ASSUME_YES=false            # -y/--yes: skip confirmation prompts
# Live-target credentials read BEFORE file restore. Used by reset-db flow.
LIVE_DB_NAME=""
LIVE_DB_USER=""
LIVE_DB_PASSWORD=""
LIVE_DB_HOST=""
LIVE_DB_PREFIX=""
# Backup-side table_prefix read from the backup's wp-config.php. Used to
# patch the restored wp-config.php after a reset-db import.
BACKUP_TABLE_PREFIX=""
# When live wp-config uses getenv_docker() helpers and the container has
# lost its env vars, fall back to prompting the user for creds.
LIVE_DB_CREDENTIALS_PROMPTED=false
LIVE_WP_CONFIG=""            # tmp path to live wp-config.php pulled from target

# Function to display help
show_help() {
    echo "WordPress Restore Script"
    echo "=================================="
    echo ""
    echo "Usage:"
    echo "  Restore (host):     $0 -b BACKUP_FILE -w WORDPRESS_DIR [options]"
    echo "  Restore (Docker):   $0 -b BACKUP_FILE -c WP_CONTAINER [options]"
    echo "  Fix mode (-f):      $0 -f -w WORDPRESS_DIR [post-restore options]"
    echo ""
    echo "Required Options (restore mode):"
    echo "  -b BACKUP_FILE       Path to the backup ZIP file (required unless -f)"
    echo "  -w WORDPRESS_DIR     Path to the WordPress installation directory on the host"
    echo "                       (required unless -c is used; mutually exclusive with -c)"
    echo "  -c WP_CONTAINER      Name or ID of a running WordPress Docker container."
    echo "                       Use this when WordPress files live inside Docker with"
    echo "                       no host bind mount. Files are pushed via 'docker cp'."
    echo "  -d DOCROOT           Document root inside the WordPress container"
    echo "                       (default: /var/www/html, used with -c)"
    echo ""
    echo "Modes:"
    echo "  -f, --fix-mode       Fix mode: do NOT restore files or database. Only run"
    echo "                       post-restore customizations (-u, -t, -A) against the"
    echo "                       live site. -b is not needed; DB credentials are read from"
    echo "                       the live WordPress installation at -w or -c."
    echo ""
    echo "Post-Restore Customization:"
    echo "  -u NEW_URL           Replace site URL throughout database (e.g., http://localhost:8088)"
    echo "  -U OLD_URL           Old URL to search for (default: auto-detect from backup or live site)"
    echo "  -t NEW_TITLE         Set new site title (updates 'blogname' option)"
    echo "  -A ADMIN_USER        Create/update admin user with this username"
    echo "  -P ADMIN_PASSWORD    Admin user password (requires -A)"
    echo "  -E ADMIN_EMAIL       Admin user email (requires -A)"
    echo ""
    echo "Restore Scope:"
    echo "  --skip-files         Skip file restoration (DB only)"
    echo "  --skip-db            Skip database restoration (files only)"
    echo "  --dry-run            Show what would be done without executing"
    echo ""
    echo "Reset-DB Flow (read live wp-config.php + DROP/IMPORT):"
    echo "  -r, --reset-db       DESTRUCTIVE: read credentials + table_prefix from the"
    echo "                       LIVE wp-config.php (target container/host BEFORE file"
    echo "                       restore), DROP all tables with that prefix, IMPORT"
    echo "                       the backup's database, then patch the restored"
    echo "                       wp-config.php so its \$table_prefix matches the backup"
    echo "                       (creds stay from live config so WordPress can connect)."
    echo "                       Skips .dbinfo entirely — fixes cross-stack restores."
    echo "                       Default in -c mode; opt-in in -w mode."
    echo "  -y, --yes            Skip the DROP-TABLES confirmation prompt"
    echo ""
    echo "Other:"
    echo "  -h                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Basic restore (auto-detects environment AND backup mode)"
    echo "  $0 -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress"
    echo ""
    echo "  # Restore and change URL to new domain"
    echo "  $0 -b /backups/backup.zip -w /var/www/html/wordpress \\"
    echo "     -U https://oldsite.com -u https://newsite.com"
    echo ""
    echo "  # Restore and set site title + new admin user"
    echo "  $0 -b /backups/backup.zip -w /var/www/html/wordpress \\"
    echo "     -t 'My New Site' -A newadmin -P 'SecurePass123' -E admin@example.com"
    echo ""
    echo "  # Preview restore without making changes"
    echo "  $0 -b /backups/backup.zip -w /var/www/html/wordpress --dry-run"
    echo ""
    echo "  # Cross-stack restore with -c: drop live tables, import, patch prefix"
    echo "  $0 -b /backups/szreypower.zip -c wp-dev-environment-wordpress-app -y"
    echo ""
    echo "  # Host-mode reset-db (opt-in):"
    echo "  $0 -b /backups/backup.zip -w /var/www/html --reset-db -y"
    echo ""
    echo "  # Restore back into a Docker container (WordPress lives in a named volume)"
    echo "  $0 -b /backups/backup.zip -c my_project-wordpress-app"
    echo ""
    echo "  # Restore into a container and change URL"
    echo "  $0 -b /backups/backup.zip -c my_project-wordpress-app \\"
    echo "     -U https://oldsite.com -u https://newsite.com"
    echo ""
    echo "  # FIX MODE: change live site URL only (no restore, no backup needed)"
    echo "  $0 -f -w /var/www/html/wordpress \\"
    echo "     -U https://oldsite.com -u https://newsite.com"
    echo ""
    echo "  # FIX MODE: reset admin password on live site"
    echo "  $0 -f -w /var/www/html/wordpress \\"
    echo "     -A newadmin -P 'SecurePass123' -E admin@example.com"
    echo ""
    echo "  # FIX MODE: change site title only"
    echo "  $0 -f -w /var/www/html/wordpress -t 'My New Site'"
    echo ""
    echo "Features:"
    echo "  - Auto-detects Docker containers or native database services"
    echo "  - Supports both MySQL and MariaDB"
    echo "  - Restores both WordPress files and database from backup"
    echo "  - Handles environment-specific restoration methods"
    echo "  - Optional URL/title/admin replacement after restore"
    echo "  - Fix mode (-f) for site maintenance without a full restore"
    echo ""
    echo "Note: This script MUST be run as root (use sudo)."
    echo "      Restore needs to chown restored files to match the web server user"
    echo "      (e.g. nobody:65534, www-data:33, or 1000:1000 for OLS)."
    echo ""
    echo "Note: This script will restore both WordPress files and database from the backup"
    echo "      unless -f (fix mode) is used, in which case only the requested customizations"
    echo "      are applied to the live site."
    echo "      In restore mode, existing files and database content will be replaced!"
    echo "      For Docker environments, containers must be running before restoration."
}

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if required tools are installed
check_dependencies() {
    local missing_tools=()
    
    if ! command -v unzip &> /dev/null; then
        missing_tools+=("unzip")
    fi
    
    if [ "$IS_DOCKER" = true ]; then
        if ! command -v docker &> /dev/null; then
            missing_tools+=("docker")
        fi
        
        if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
            missing_tools+=("docker-compose")
        fi
    else
        # Check for native database restore tools
        if [ "$DB_TYPE" = "mariadb" ]; then
            if ! command -v mariadb &> /dev/null; then
                missing_tools+=("mariadb")
            fi
        else
            if ! command -v mysql &> /dev/null; then
                missing_tools+=("mysql")
            fi
        fi
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_message "ERROR: Missing required tools: ${missing_tools[*]}"
        log_message "Please install the missing tools and try again."
        exit 1
    fi
}

# Function to detect if WordPress is running in Docker
detect_docker_environment() {
    log_message "Checking for Docker environment..."
    
    # Check for docker-compose.yml in WordPress directory or parent directories
    local current_dir="$WORDPRESS_DIR"
    local compose_file=""
    
    # Search for docker-compose.yml in current and parent directories
    for i in {0..3}; do
        if [ -f "$current_dir/docker-compose.yml" ]; then
            compose_file="$current_dir/docker-compose.yml"
            break
        fi
        current_dir=$(dirname "$current_dir")
        if [ "$current_dir" = "/" ]; then
            break
        fi
    done
    
    if [ -n "$compose_file" ]; then
        log_message "Found docker-compose.yml at: $compose_file"
        
        # Check if the compose file contains database services
        if grep -qi "mariadb\|mysql" "$compose_file"; then
            IS_DOCKER=true
            DOCKER_COMPOSE_DIR=$(dirname "$compose_file")
            log_message "Detected Docker environment with database service"
            return 0
        fi
    fi
    
    # Check for running WordPress-related Docker containers
    if command -v docker &> /dev/null; then
        local wp_containers=$(docker ps --format "table {{.Names}}" | grep -E "(wordpress|wp|mysql|mariadb)" 2>/dev/null || true)
        if [ -n "$wp_containers" ]; then
            log_message "Found WordPress-related Docker containers running"
            IS_DOCKER=true
            return 0
        fi
    fi
    
    log_message "No Docker environment detected, using native database services"
    IS_DOCKER=false
    return 1
}

# Function to find a running DB container by reading wp-config.php's DB_HOST.
# WordPress Docker stacks normally set DB_HOST to the compose service name
# (e.g. "db"), and docker-compose prefixes container names with the project
# name (e.g. "<project>-db-1" or "<project>-db"). We try several strategies
# so we can connect to whatever DB is actually running for this stack,
# even if the compose file lives outside WORDPRESS_DIR.
#
# Strategy order:
#   1. Exact match: a running container literally named "$DB_HOST"
#   2. Compose v2: "<project>-<service>-1" (suffix "-1")
#   3. Compose v2: "<project>-<service>" (no suffix)
#   4. DB container reachable from a known WP container via shared network
#   5. Any running container whose image is mariadb/mysql
#
# Sets DB_CONTAINER on success, leaves it untouched on failure.
resolve_db_container_from_running_stack() {
    local db_host="${1:-}"
    [ -z "$db_host" ] && return 1
    # Strip optional port (e.g. "db:3306" -> "db")
    local svc="${db_host%%:*}"
    [ -z "$svc" ] && return 1

    # Skip obvious non-container hosts
    case "$svc" in
        localhost|127.0.0.1|0.0.0.0|::1) return 1 ;;
    esac

    if ! command -v docker &>/dev/null; then
        return 1
    fi

    local running
    running=$(docker ps --format '{{.Names}}' 2>/dev/null) || return 1
    [ -z "$running" ] && return 1

    # 1. Exact match
    if echo "$running" | grep -qx "$svc"; then
        DB_CONTAINER="$svc"
        log_message "Resolved DB container (exact name): $DB_CONTAINER"
        return 0
    fi

    # 2/3. Compose project prefixes — derive project name from any running
    # WordPress container on the host so we don't guess wrong.
    local project=""
    if [ -n "$WP_CONTAINER" ]; then
        # WP container was supplied via -c: "<project>-<service>-N" or
        # "<project>-<service>". Strip trailing "-<digits>" then the service.
        local base="${WP_CONTAINER%-[0-9]*}"
        if [ "$base" != "$WP_CONTAINER" ]; then
            project="${base%-*}"
        else
            project="${WP_CONTAINER%-*}"
        fi
    fi
    if [ -z "$project" ]; then
        # Try a WordPress container discovered from the running list
        local wp_candidate
        wp_candidate=$(echo "$running" | grep -E "(wordpress|wp)$|-wordpress-[0-9]+$|-wp-[0-9]+$" | head -1)
        if [ -n "$wp_candidate" ]; then
            local base="${wp_candidate%-[0-9]*}"
            project="${base%-*}"
        fi
    fi
    if [ -n "$project" ]; then
        for cand in "${project}-${svc}-1" "${project}-${svc}"; do
            if echo "$running" | grep -qx "$cand"; then
                DB_CONTAINER="$cand"
                log_message "Resolved DB container (compose project '$project'): $DB_CONTAINER"
                return 0
            fi
        done
    fi

    # 4. Network-based: any mariadb/mysql container that shares a network
    # with a running WordPress container.
    local wp_for_net=""
    if [ -n "$WP_CONTAINER" ] && echo "$running" | grep -qx "$WP_CONTAINER"; then
        wp_for_net="$WP_CONTAINER"
    else
        wp_for_net=$(echo "$running" | grep -E "(wordpress|wp)$|-wordpress-[0-9]+$|-wp-[0-9]+$" | head -1)
    fi
    if [ -n "$wp_for_net" ]; then
        local wp_netids
        wp_netids=$(docker inspect "$wp_for_net" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)
        for net in $wp_netids; do
            local candidates
            candidates=$(docker network inspect "$net" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null) || continue
            for cand in $candidates; do
                if [ "$cand" = "$wp_for_net" ]; then continue; fi
                local img
                img=$(docker inspect "$cand" --format '{{.Config.Image}}' 2>/dev/null)
                case "$img" in
                    *mariadb*|*mysql*) DB_CONTAINER="$cand"; log_message "Resolved DB container (shared network with WP): $DB_CONTAINER (image=$img)"; return 0 ;;
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
        DB_CONTAINER="$any"
        log_message "Resolved DB container (fallback: any running mariadb/mysql): $DB_CONTAINER"
        return 0
    fi

    return 1
}

# Function to detect database type and container (for Docker)
detect_docker_database_info() {
    local compose_file="$DOCKER_COMPOSE_DIR/docker-compose.yml"
    local compose_found=false

    if [ -f "$compose_file" ]; then
        compose_found=true
        log_message "Analyzing docker-compose.yml for database configuration..."

        # Detect database type from compose file
        if grep -qi "mariadb" "$compose_file"; then
            DB_TYPE="mariadb"
            log_message "Detected database type: MariaDB (from compose)"
        elif grep -qi "mysql" "$compose_file"; then
            DB_TYPE="mysql"
            log_message "Detected database type: MySQL (from compose)"
        fi

        # Try to derive a container name from the compose file. This is best-
        # effort: many stacks rely on compose's default naming (<project>-
        # <service>-N) rather than explicit container_name. We still record
        # whatever we find but won't fail if it's empty.
        local container_line=$(grep -A 10 -B 5 "mariadb\|mysql" "$compose_file" | grep -E "container_name:" | head -1)
        if [ -n "$container_line" ]; then
            DB_CONTAINER=$(echo "$container_line" | sed 's/.*container_name:\s*//' | tr -d '"' | tr -d "'" | xargs)
            log_message "Database container (from compose container_name): $DB_CONTAINER"
        else
            local svc_line
            svc_line=$(grep -B 5 -A 10 "mariadb\|mysql" "$compose_file" | grep -E "^\s*[a-zA-Z0-9_-]+:" | head -1 | sed 's/:\s*$//' | sed 's/^\s*//')
            if [ -n "$svc_line" ]; then
                DB_CONTAINER="$svc_line"
                log_message "Database service name (from compose): $DB_CONTAINER"
            fi
        fi
    elif [ -n "$DOCKER_COMPOSE_DIR" ]; then
        log_message "WARN: docker-compose.yml not found in $DOCKER_COMPOSE_DIR"
    fi

    # If DB_TYPE still unknown (compose missing or didn't mention mysql/
    # mariadb), infer it from the BACKUP_DB_TYPE sidecar or default to mysql.
    if [ -z "$DB_TYPE" ]; then
        if [ -n "$BACKUP_DB_TYPE" ]; then
            DB_TYPE="$BACKUP_DB_TYPE"
            log_message "Detected database type from .dbinfo sidecar: $DB_TYPE"
        else
            DB_TYPE="mysql"
            log_message "Assuming database type: mysql (default)"
        fi
    fi

    # Always try to resolve a *running* container for the DB. We pass
    # $DB_HOST (set by extract_db_config from wp-config.php / .dbinfo) so we
    # can find the right container even when the compose file is absent or
    # uses compose's default naming scheme.
    if [ -z "$DB_CONTAINER" ] || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
        if [ -z "${DB_HOST:-}" ] && [ -z "$DB_CONTAINER" ]; then
            # Very early in the run, before the backup is extracted.
            # The main flow will retry us once DB_HOST is populated from
            # wp-config.php / .dbinfo. Stay quiet so we don't print a
            # confusing failure message that gets immediately contradicted.
            :
        elif resolve_db_container_from_running_stack "${DB_HOST:-}"; then
            : # DB_CONTAINER updated by helper
        elif [ "$compose_found" = false ] && [ -z "$DB_CONTAINER" ]; then
            log_message "ERROR: Could not determine database container (no compose file and no running container matches DB_HOST='${DB_HOST:-}')"
            return 1
        elif [ -z "$DB_CONTAINER" ]; then
            log_message "ERROR: Could not determine database container from compose file"
            return 1
        else
            log_message "WARN: Resolved container '$DB_CONTAINER' from compose file is not running; will try fallback discovery"
            resolve_db_container_from_running_stack "${DB_HOST:-}" || true
        fi
    fi

    if [ -n "$DB_CONTAINER" ]; then
        log_message "Database container: $DB_CONTAINER (type=$DB_TYPE)"
    else
        log_message "Database container: <pending — will resolve after backup extraction>"
    fi
    return 0
}

# Function to detect native database service type
detect_native_database_service() {
    log_message "Attempting to auto-detect native database service..."
    
    # Method 1: Check running processes
    if pgrep -f "mariadb\|mysqld.*mariadb" > /dev/null; then
        DB_TYPE="mariadb"
        log_message "Detected MariaDB from running processes"
        return 0
    elif pgrep -f "mysqld" > /dev/null; then
        DB_TYPE="mysql"
        log_message "Detected MySQL from running processes"
        return 0
    fi
    
    # Method 2: Check installed packages (Debian/Ubuntu)
    if command -v dpkg &> /dev/null; then
        if dpkg -l | grep -q "mariadb-server\|mariadb-client"; then
            DB_TYPE="mariadb"
            log_message "Detected MariaDB from installed packages"
            return 0
        elif dpkg -l | grep -q "mysql-server\|mysql-client"; then
            DB_TYPE="mysql"
            log_message "Detected MySQL from installed packages"
            return 0
        fi
    fi
    
    # Method 3: Check for MariaDB-specific command
    if command -v mariadb &> /dev/null; then
        DB_TYPE="mariadb"
        log_message "Detected MariaDB from available commands"
        return 0
    fi
    
    # Method 4: Try connecting and check version
    if command -v mysql &> /dev/null; then
        local version_output=$(mysql --version 2>/dev/null)
        if echo "$version_output" | grep -qi "mariadb"; then
            DB_TYPE="mariadb"
            log_message "Detected MariaDB from version output"
            return 0
        else
            DB_TYPE="mysql"
            log_message "Detected MySQL from version output"
            return 0
        fi
    fi
    
    # Default fallback
    log_message "Could not auto-detect database service, defaulting to MySQL"
    DB_TYPE="mysql"
    return 1
}

# Function to extract and validate backup
extract_backup() {
    local backup_file="$1"
    local temp_dir="$2"
    
    log_message "Extracting backup file..."
    
    # Extract backup to temporary directory
    if unzip -q "$backup_file" -d "$temp_dir"; then
        log_message "Backup extracted successfully"
    else
        log_message "ERROR: Failed to extract backup file"
        return 1
    fi
    
    # Validate backup structure
    if [ ! -f "$temp_dir/database.sql" ]; then
        log_message "ERROR: database.sql not found in backup"
        return 1
    fi
    
    if [ ! -d "$temp_dir/files" ]; then
        log_message "ERROR: files directory not found in backup"
        return 1
    fi
    
    # Detect backup mode (lightweight vs full)
    if [ -f "$temp_dir/files/.backup_mode" ]; then
        BACKUP_MODE="lightweight"
        log_message "Detected backup mode: LIGHTWEIGHT (wp-content + wp-config.php + .htaccess)"
    else
        BACKUP_MODE="full"
        log_message "Detected backup mode: FULL (complete WordPress directory)"
    fi
    
    # Check if files directory contains WordPress files
    local wp_files_dir=$(find "$temp_dir/files" -name "wp-config.php" -type f | head -1)
    if [ -z "$wp_files_dir" ]; then
        log_message "ERROR: wp-config.php not found in backup files"
        return 1
    fi
    
    # Store the WordPress files path
    BACKUP_WP_DIR=$(dirname "$wp_files_dir")
    log_message "WordPress files found in: $BACKUP_WP_DIR"
    
    # Check for backup info file (specific to Docker backups)
    if [ -f "$temp_dir/backup_info.txt" ]; then
        log_message "Backup info file found, displaying backup details:"
        cat "$temp_dir/backup_info.txt"
        echo ""
    fi

    # Load resolved DB config from .dbinfo sidecar if present. The sidecar
    # contains the values AFTER env/getenv_docker() resolution, which is
    # critical for Docker images that use env-driven wp-config.php
    # (otherwise we'd get literal "wordpress" instead of the real DB name).
    if [ -f "$temp_dir/.dbinfo" ]; then
        log_message "Loading resolved DB config from .dbinfo sidecar..."
        # Source each KEY=VALUE line (skip blanks/comments). Use a subshell
        # so we can filter safely.
        while IFS='=' read -r key val; do
            case "$key" in
                DB_NAME)      BACKUP_DB_NAME="$val" ;;
                DB_USER)      BACKUP_DB_USER="$val" ;;
                DB_PASSWORD)  BACKUP_DB_PASSWORD="$val" ;;
                DB_HOST)      BACKUP_DB_HOST="$val" ;;
                DB_TYPE)      BACKUP_DB_TYPE="$val" ;;
                DB_CONTAINER) BACKUP_DB_CONTAINER="$val" ;;
                BACKUP_MODE)  [ "$val" = "lightweight" ] && BACKUP_MODE="lightweight" ;;
                SOURCE)       BACKUP_SOURCE="$val" ;;
                WP_CONTAINER) BACKUP_WP_CONTAINER="$val" ;;
                WP_CONTAINER_DOCROOT) BACKUP_WP_CONTAINER_DOCROOT="$val" ;;
            esac
        done < "$temp_dir/.dbinfo"
        log_message "  DB: $BACKUP_DB_NAME on $BACKUP_DB_HOST (type=$BACKUP_DB_TYPE)"
        log_message "  Source: $BACKUP_SOURCE"
    fi

    return 0
}

# Function to extract database configuration from backup wp-config.php
extract_db_config() {
    local wp_config="$1/wp-config.php"

    # Prefer the resolved values from the .dbinfo sidecar (written by
    # wp_backup.sh). This avoids wrong defaults like "wordpress" when the
    # original wp-config.php uses getenv_docker() or similar env helpers.
    if [ -n "$BACKUP_DB_NAME" ] && [ -n "$BACKUP_DB_USER" ] && [ -n "$BACKUP_DB_HOST" ]; then
        DB_NAME="$BACKUP_DB_NAME"
        DB_USER="$BACKUP_DB_USER"
        DB_PASSWORD="$BACKUP_DB_PASSWORD"
        DB_HOST="$BACKUP_DB_HOST"
        if [ -n "$BACKUP_DB_TYPE" ]; then
            DB_TYPE="$BACKUP_DB_TYPE"
        fi
        if [ -n "$BACKUP_DB_CONTAINER" ]; then
            DB_CONTAINER="$BACKUP_DB_CONTAINER"
        fi
        log_message "Database config from .dbinfo sidecar"
        log_message "Database: $DB_NAME on $DB_HOST (container: ${DB_CONTAINER:-unknown})"
        return 0
    fi

    if [ ! -f "$wp_config" ]; then
        log_message "ERROR: wp-config.php not found in $1"
        return 1
    fi

    # Extract database configuration
    DB_NAME=$(grep "define.*DB_NAME" "$wp_config" | sed -n "s/.*DB_NAME.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    DB_USER=$(grep "define.*DB_USER" "$wp_config" | sed -n "s/.*DB_USER.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    DB_PASSWORD=$(grep "define.*DB_PASSWORD" "$wp_config" | sed -n "s/.*DB_PASSWORD.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    DB_HOST=$(grep "define.*DB_HOST" "$wp_config" | sed -n "s/.*DB_HOST.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")

    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_HOST" ]; then
        log_message "ERROR: Could not extract database configuration from wp-config.php"
        return 1
    fi

    log_message "Database configuration extracted successfully"
    log_message "Database: $DB_NAME on $DB_HOST"
    return 0
}

# Read a single literal-value define() from wp-config.php (returns empty
# string if not found). Used by read_live_wp_config() below.
_wp_config_get_define() {
    local key="$1" file="$2"
    # Match: define( 'KEY', 'value' );  or  define( "KEY", "value" );
    # Also: define('KEY', getenv_docker('NAME', 'fallback')) — handled by
    # the caller separately.
    grep -E "^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]${key}['\"][[:space:]]*,[[:space:]]*['\"][^'\"]*['\"]" "$file" 2>/dev/null \
        | head -1 \
        | sed -nE "s/.*['\"]${key}['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]*)['\"].*/\\1/p"
}

# Read credentials + table_prefix from the LIVE wp-config.php on the target
# (host path for -w, container for -c) — i.e. BEFORE we overwrite files.
# This is what makes the reset-db flow work even when .dbinfo is stale.
#
# Sets: LIVE_DB_NAME, LIVE_DB_USER, LIVE_DB_PASSWORD, LIVE_DB_HOST,
#       LIVE_DB_PREFIX (and a temporary $LIVE_WP_CONFIG file path used by
#       the caller).
#
# Side effects: when live wp-config uses getenv_docker() (DB_* defaults to
# literal "wordpress", "example username", "mysql") we try to resolve the
# real values from the WP container's env vars. If that fails AND
# ASSUME_YES is not set, we prompt the user for credentials. If the user
# cancels, the function returns 1.
read_live_wp_config() {
    local target_path=""           # host path to live wp-config.php (-w mode)
    local target_container=""      # container name (-c mode)
    local docroot="/var/www/html"

    if [ -n "$WORDPRESS_DIR" ]; then
        target_path="$WORDPRESS_DIR/wp-config.php"
    elif [ -n "$WP_CONTAINER" ]; then
        target_container="$WP_CONTAINER"
        docroot="$WP_CONTAINER_DOCROOT"
    else
        log_message "ERROR: read_live_wp_config() needs -w or -c to know where to look"
        return 1
    fi

    # Pull live wp-config.php out to a tmp file we can grep on.
    local tmp_wp=/tmp/live_wp_config_$$.php
    if [ -n "$target_path" ]; then
        if [ ! -f "$target_path" ]; then
            log_message "ERROR: live wp-config.php not found at $target_path"
            log_message "       Reset-db flow requires an existing WordPress installation on the target"
            return 1
        fi
        cp "$target_path" "$tmp_wp" 2>/dev/null || {
            log_message "ERROR: Cannot read $target_path"
            return 1
        }
        log_message "Read live wp-config.php from $target_path"
    else
        if ! docker exec "$target_container" test -f "$docroot/wp-config.php" >/dev/null 2>&1; then
            log_message "ERROR: live wp-config.php not found at $docroot in container '$target_container'"
            return 1
        fi
        if ! docker cp "$target_container:$docroot/wp-config.php" "$tmp_wp" 2>/dev/null; then
            log_message "ERROR: docker cp failed to pull $docroot/wp-config.php from $target_container"
            return 1
        fi
        log_message "Pulled live wp-config.php from container '$target_container:$docroot'"
    fi

    # Extract literal values.
    local lname luser lpass lhost lprefix
    lname=$(_wp_config_get_define "DB_NAME"     "$tmp_wp")
    luser=$(_wp_config_get_define "DB_USER"     "$tmp_wp")
    lpass=$(_wp_config_get_define "DB_PASSWORD" "$tmp_wp")
    lhost=$(_wp_config_get_define "DB_HOST"     "$tmp_wp")

    # Extract $table_prefix (line like "$table_prefix = 'wp_';")
    lprefix=$(grep -E "^[[:space:]]*\\\$(table_prefix|wpdb\\->prefix)" "$tmp_wp" 2>/dev/null \
        | head -1 \
        | sed -nE "s/.*['\"]([^'\"]*)['\"][[:space:]]*;.*/\\1/p")

    # If table_prefix wasn't found, try the more lenient "= 'wp_';" pattern
    if [ -z "$lprefix" ]; then
        lprefix=$(grep -E "table_prefix" "$tmp_wp" 2>/dev/null \
            | head -1 \
            | sed -nE "s/.*=.*['\"]([^'\"]*)['\"].*/\\1/p")
    fi

    # Detect getenv_docker() usage: DB_* is set to a literal placeholder
    # (e.g. "wordpress", "example username", "example password", "mysql")
    # OR to a getenv_docker() call. In either case the literal value is
    # not the real credential.
    local uses_env_helpers=false
    if grep -qE "getenv_docker\s*\(" "$tmp_wp" 2>/dev/null; then
        uses_env_helpers=true
    fi

    if [ "$uses_env_helpers" = true ]; then
        log_message "Live wp-config.php uses getenv_docker() — resolving real credentials from WP container env"
        if [ -z "$target_container" ]; then
            log_message "WARN: getenv_docker() detected but -c was not provided; falling back to literal values"
        else
            local env_name env_user env_pass env_host
            env_name=$(docker exec "$target_container" sh -c 'echo "$WORDPRESS_DB_NAME"' 2>/dev/null)
            env_user=$(docker exec "$target_container" sh -c 'echo "$WORDPRESS_DB_USER"' 2>/dev/null)
            env_pass=$(docker exec "$target_container" sh -c 'echo "$WORDPRESS_DB_PASSWORD"' 2>/dev/null)
            env_host=$(docker exec "$target_container" sh -c 'echo "$WORDPRESS_DB_HOST"' 2>/dev/null)
            # Use env vars when present and non-placeholder.
            [ -n "$env_name" ] && [ "$env_name" != "wordpress" ] && lname="$env_name"
            [ -n "$env_user" ] && [ "$env_user" != "example username" ] && luser="$env_user"
            [ -n "$env_pass" ] && [ "$env_pass" != "example password" ] && lpass="$env_pass"
            [ -n "$env_host" ] && [ "$env_host" != "mysql" ] && lhost="$env_host"
        fi
    fi

    # Final check — if we still have placeholders, prompt the user.
    local needs_prompt=false
    if [ -z "$lname" ] || [ "$lname" = "wordpress" ]; then needs_prompt=true; fi
    if [ -z "$luser" ] || [ "$luser" = "example username" ]; then needs_prompt=true; fi
    if [ -z "$lhost" ]; then needs_prompt=true; fi

    if [ "$needs_prompt" = true ]; then
        log_message ""
        log_message "==================================================================="
        log_message "  Live wp-config.php does not contain usable DB credentials."
        if [ "$uses_env_helpers" = true ]; then
            log_message "  It uses getenv_docker() but the WP container has no"
            log_message "  WORDPRESS_DB_* env vars (or they still hold placeholders)."
        fi
        log_message "  Reset-db flow requires real credentials to connect to the DB."
        log_message "  Please enter them now (or press Ctrl-C to abort)."
        log_message "==================================================================="
        log_message ""

        local input
        if [ -z "$lname" ] || [ "$lname" = "wordpress" ]; then
            printf "DB name (current: '%s'): " "$lname"
            read -r input
            [ -n "$input" ] && lname="$input"
        fi
        if [ -z "$luser" ] || [ "$luser" = "example username" ]; then
            printf "DB user (current: '%s'): " "$luser"
            read -r input
            [ -n "$input" ] && luser="$input"
        fi
        if [ -z "$lpass" ] || [ "$lpass" = "example password" ]; then
            printf "DB password (current: '%s'): " "$lpass"
            read -r input
            [ -n "$input" ] && lpass="$input"
        fi
        if [ -z "$lhost" ]; then
            printf "DB host (current: '%s'): " "$lhost"
            read -r input
            [ -n "$input" ] && lhost="$input"
        fi
        LIVE_DB_CREDENTIALS_PROMPTED=true

        # Re-validate after prompting.
        if [ -z "$lname" ] || [ -z "$luser" ] || [ -z "$lhost" ]; then
            log_message "ERROR: DB credentials are still incomplete; cannot proceed"
            rm -f "$tmp_wp" 2>/dev/null
            return 1
        fi
    fi

    # Default table_prefix if not detected (very unusual — wp-config.php
    # almost always sets it).
    if [ -z "$lprefix" ]; then
        lprefix="wp_"
        log_message "WARN: Could not detect \$table_prefix from live wp-config.php — defaulting to 'wp_'"
    fi

    LIVE_DB_NAME="$lname"
    LIVE_DB_USER="$luser"
    LIVE_DB_PASSWORD="$lpass"
    LIVE_DB_HOST="$lhost"
    LIVE_DB_PREFIX="$lprefix"
    LIVE_WP_CONFIG="$tmp_wp"

    log_message "Live DB config: $LIVE_DB_NAME on $LIVE_DB_HOST (prefix='$LIVE_DB_PREFIX')"
    return 0
}

# Read the table_prefix from the BACKUP's wp-config.php (the file inside
# the backup ZIP, which we extract to $TEMP_DIR/files/wp-config.php during
# extract_backup()). Sets BACKUP_TABLE_PREFIX.
read_backup_table_prefix() {
    local wp_config="$BACKUP_WP_DIR/wp-config.php"
    if [ ! -f "$wp_config" ]; then
        log_message "ERROR: backup wp-config.php not found at $wp_config"
        return 1
    fi
    local prefix
    prefix=$(grep -E "^[[:space:]]*\\\$(table_prefix|wpdb\\->prefix)" "$wp_config" 2>/dev/null \
        | head -1 \
        | sed -nE "s/.*['\"]([^'\"]*)['\"][[:space:]]*;.*/\\1/p")
    if [ -z "$prefix" ]; then
        prefix=$(grep -E "table_prefix" "$wp_config" 2>/dev/null \
            | head -1 \
            | sed -nE "s/.*=.*['\"]([^'\"]*)['\"].*/\\1/p")
    fi
    if [ -z "$prefix" ]; then
        prefix="wp_"
        log_message "WARN: Could not detect \$table_prefix from backup wp-config.php — defaulting to 'wp_'"
    fi
    BACKUP_TABLE_PREFIX="$prefix"
    log_message "Backup table prefix: '$BACKUP_TABLE_PREFIX'"
    return 0
}

# Show tables matching $LIVE_DB_PREFIX in the live database. Returns the
# count via stdout and a newline-separated list of tables in $DROP_TABLES.
# Uses LIVE_DB_* creds. Works for both Docker and native.
list_tables_with_prefix() {
    DROP_TABLES=""
    local query="SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='${LIVE_DB_NAME}' AND TABLE_NAME LIKE '${LIVE_DB_PREFIX}%';"

    local output
    if [ "$IS_DOCKER" = true ]; then
        if [ "$DB_TYPE" = "mariadb" ]; then
            output=$(docker exec "$DB_CONTAINER" mariadb -N -B -u"$LIVE_DB_USER" $( [ -n "$LIVE_DB_PASSWORD" ] && printf -- "-p%s" "$LIVE_DB_PASSWORD" ) "$LIVE_DB_NAME" -e "$query" 2>/dev/null)
        else
            output=$(docker exec "$DB_CONTAINER" mysql -N -B -u"$LIVE_DB_USER" $( [ -n "$LIVE_DB_PASSWORD" ] && printf -- "-p%s" "$LIVE_DB_PASSWORD" ) "$LIVE_DB_NAME" -e "$query" 2>/dev/null)
        fi
    else
        if [ "$DB_TYPE" = "mariadb" ]; then
            output=$(mariadb -N -B -h"$LIVE_DB_HOST" -u"$LIVE_DB_USER" $( [ -n "$LIVE_DB_PASSWORD" ] && printf -- "-p%s" "$LIVE_DB_PASSWORD" ) "$LIVE_DB_NAME" -e "$query" 2>/dev/null)
        else
            output=$(mysql -N -B -h"$LIVE_DB_HOST" -u"$LIVE_DB_USER" $( [ -n "$LIVE_DB_PASSWORD" ] && printf -- "-p%s" "$LIVE_DB_PASSWORD" ) "$LIVE_DB_NAME" -e "$query" 2>/dev/null)
        fi
    fi

    DROP_TABLES="$output"
    if [ -n "$DROP_TABLES" ]; then
        echo "$DROP_TABLES" | wc -l | tr -d ' '
    else
        echo 0
    fi
}

# DROP every table in $DROP_TABLES from $LIVE_DB_NAME. Runs via SET
# FOREIGN_KEY_CHECKS=0 to avoid ordering issues. Idempotent — missing
# tables are silently skipped (the DROP statement just errors, but we
# suppress the error per-table).
drop_tables_for_prefix() {
    if [ -z "${DROP_TABLES:-}" ]; then
        log_message "No tables matched prefix '$LIVE_DB_PREFIX' — nothing to drop"
        return 0
    fi

    local count
    count=$(echo "$DROP_TABLES" | wc -l | tr -d ' ')
    log_message "Dropping $count table(s) with prefix '$LIVE_DB_PREFIX' from database '$LIVE_DB_NAME'..."

    # Build a single SQL script: SET FK_CHECKS=0; DROP TABLE IF EXISTS x;
    # DROP TABLE IF EXISTS y; ...; SET FK_CHECKS=1;
    local sql="SET FOREIGN_KEY_CHECKS=0;\n"
    while IFS= read -r table; do
        [ -z "$table" ] && continue
        # Backtick the identifier — table names in WP are ASCII but be safe.
        sql="${sql}DROP TABLE IF EXISTS \`${table}\`;\n"
    done <<< "$DROP_TABLES"
    sql="${sql}SET FOREIGN_KEY_CHECKS=1;"

    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY-RUN] Would DROP $count table(s) (not executed)"
        echo "$sql" | head -5
        return 0
    fi

    if [ "$IS_DOCKER" = true ]; then
        if [ "$DB_TYPE" = "mariadb" ]; then
            printf "%b" "$sql" | docker exec -i "$DB_CONTAINER" mariadb -u"$LIVE_DB_USER" $( [ -n "$LIVE_DB_PASSWORD" ] && printf -- "-p%s" "$LIVE_DB_PASSWORD" ) "$LIVE_DB_NAME" 2>&1 \
                | grep -v "Using a password" \
                | sed 's/^/  [mysql] /' \
                || true
        else
            printf "%b" "$sql" | docker exec -i "$DB_CONTAINER" mysql -u"$LIVE_DB_USER" $( [ -n "$LIVE_DB_PASSWORD" ] && printf -- "-p%s" "$LIVE_DB_PASSWORD" ) "$LIVE_DB_NAME" 2>&1 \
                | grep -v "Using a password" \
                | sed 's/^/  [mysql] /' \
                || true
        fi
    else
        if [ "$DB_TYPE" = "mariadb" ]; then
            printf "%b" "$sql" | mariadb -h"$LIVE_DB_HOST" -u"$LIVE_DB_USER" $( [ -n "$LIVE_DB_PASSWORD" ] && printf -- "-p%s" "$LIVE_DB_PASSWORD" ) "$LIVE_DB_NAME" 2>&1 \
                | grep -v "Using a password" \
                | sed 's/^/  [mysql] /' \
                || true
        else
            printf "%b" "$sql" | mysql -h"$LIVE_DB_HOST" -u"$LIVE_DB_USER" $( [ -n "$LIVE_DB_PASSWORD" ] && printf -- "-p%s" "$LIVE_DB_PASSWORD" ) "$LIVE_DB_NAME" 2>&1 \
                | grep -v "Using a password" \
                | sed 's/^/  [mysql] /' \
                || true
        fi
    fi

    log_message "DROP phase complete"
    return 0
}

# Patch DB credentials in a wp-config.php file (in place). Used after a
# successful DB import so the restored wp-config.php connects with the
# SAME creds that actually imported the data — otherwise WordPress can
# 500 right after restore when the backup's creds (pointing at the old
# stack) don't match the live container's creds.
#
# Args:
#   $1 — path to wp-config.php to patch. Format:
#          /path/on/host                 (host mode)
#          CONTAINER:/path/in/container (container-direct mode; we
#                                        docker cp the file out, patch, and
#                                        cp it back)
#   $2 — DB_NAME
#   $3 — DB_USER
#   $4 — DB_PASSWORD  (empty string is OK — we'll write an empty literal)
#   $5 — DB_HOST
patch_wp_config_db_creds() {
    local wp_config_path="$1"
    local new_name="$2"
    local new_user="$3"
    local new_pass="$4"
    local new_host="$5"

    if [ -z "$wp_config_path" ] || [ -z "$new_name" ] || [ -z "$new_user" ] || [ -z "$new_host" ]; then
        log_message "ERROR: patch_wp_config_db_creds() needs path, name, user, host"
        return 1
    fi

    # Skip if nothing actually changed (avoids unnecessary docker cp round-trip)
    local actual_path="$wp_config_path"
    local in_container=false
    local container=""
    local cdocroot=""
    if [[ "$wp_config_path" == *":"* ]]; then
        in_container=true
        container="${wp_config_path%%:*}"
        cdocroot="${wp_config_path#*:}"
        actual_path="/tmp/wp_config_creds_$$.php"
        if ! docker cp "$container:$cdocroot" "$actual_path" 2>/dev/null; then
            log_message "ERROR: failed to docker cp $container:$cdocroot for creds patch"
            return 1
        fi
    fi

    if [ ! -f "$actual_path" ]; then
        log_message "ERROR: wp-config.php not found at $actual_path"
        [ "$in_container" = true ] && rm -f "$actual_path"
        return 1
    fi

    # Read current values; bail early if everything already matches.
    local cur_name cur_user cur_host
    cur_name=$(grep "define.*DB_NAME"     "$actual_path" | sed -n "s/.*DB_NAME.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    cur_user=$(grep "define.*DB_USER"     "$actual_path" | sed -n "s/.*DB_USER.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    cur_host=$(grep "define.*DB_HOST"     "$actual_path" | sed -n "s/.*DB_HOST.*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    if [ "$cur_name" = "$new_name" ] && [ "$cur_user" = "$new_user" ] && [ "$cur_host" = "$new_host" ]; then
        log_message "DB creds already match (name/user/host) — skipping patch"
        [ "$in_container" = true ] && rm -f "$actual_path"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY-RUN] Would patch DB creds in $wp_config_path (DB_HOST $cur_host -> $new_host, DB_USER $cur_user -> $new_user, DB_NAME $cur_name -> $new_name)"
        [ "$in_container" = true ] && rm -f "$actual_path"
        return 0
    fi

    # Escape slashes for sed (only used in the host field, e.g. "db" or
    # "127.0.0.1:3306"). Use ASCII Unit Separator as delimiter to avoid
    # colliding with the slashes in the patterns themselves.
    local sep=$'\x1f'
    local new_name_esc new_user_esc new_pass_esc new_host_esc
    new_name_esc=$(printf '%s' "$new_name" | sed "s${sep}\\\\&${sep}\\\\\\&${sep}g")
    new_user_esc=$(printf '%s' "$new_user" | sed "s${sep}\\\\&${sep}\\\\\\&${sep}g")
    new_pass_esc=$(printf '%s' "$new_pass" | sed "s${sep}\\\\&${sep}\\\\\\&${sep}g")
    new_host_esc=$(printf '%s' "$new_host" | sed "s${sep}\\\\&${sep}\\\\\\&${sep}g")

    sed -i -E "s${sep}(define[[:space:]]*\\([[:space:]]*['\"]DB_NAME['\"],[[:space:]]*['\"]).*${sep}\\1${new_name_esc}'${sep}"     "$actual_path"
    sed -i -E "s${sep}(define[[:space:]]*\\([[:space:]]*['\"]DB_USER['\"],[[:space:]]*['\"]).*${sep}\\1${new_user_esc}'${sep}"     "$actual_path"
    sed -i -E "s${sep}(define[[:space:]]*\\([[:space:]]*['\"]DB_PASSWORD['\"],[[:space:]]*['\"]).*${sep}\\1${new_pass_esc}'${sep}" "$actual_path"
    sed -i -E "s${sep}(define[[:space:]]*\\([[:space:]]*['\"]DB_HOST['\"],[[:space:]]*['\"]).*${sep}\\1${new_host_esc}'${sep}"     "$actual_path"

    if [ "$in_container" = true ]; then
        if ! docker cp "$actual_path" "$container:$cdocroot" 2>/dev/null; then
            log_message "ERROR: failed to docker cp patched wp-config.php back to $container:$cdocroot"
            rm -f "$actual_path"
            return 1
        fi
        rm -f "$actual_path"
        log_message "Patched DB creds in $container:$cdocroot (name/user/host)"
    else
        log_message "Patched DB creds in $wp_config_path (name/user/host)"
    fi
    return 0
}

# Patch $table_prefix in a wp-config.php file (in place). Used after a
# reset-db import so the restored wp-config.php's prefix matches the
# tables we just imported (which were dumped from the backup, with the
# backup's prefix).
#
# Args:
#   $1 — path to wp-config.php to patch (host path; for container-direct
#        we docker cp the file out, patch, and cp it back)
patch_wp_config_table_prefix() {
    local wp_config_path="$1"
    local old_prefix="$2"
    local new_prefix="$3"

    if [ -z "$old_prefix" ] || [ -z "$new_prefix" ]; then
        log_message "ERROR: patch_wp_config_table_prefix() needs old and new prefix"
        return 1
    fi
    if [ "$old_prefix" = "$new_prefix" ]; then
        log_message "Table prefix unchanged ('$old_prefix') — skipping patch"
        return 0
    fi

    local actual_path="$wp_config_path"
    local in_container=false
    local container=""
    local cdocroot=""
    if [[ "$wp_config_path" == *":"* ]]; then
        # Format: <container>:<abs_path_in_container>
        in_container=true
        container="${wp_config_path%%:*}"
        cdocroot="${wp_config_path#*:}"
        actual_path="/tmp/wp_config_patch_$$.php"
        if ! docker cp "$container:$cdocroot" "$actual_path" 2>/dev/null; then
            log_message "ERROR: failed to docker cp $container:$cdocroot"
            return 1
        fi
    fi

    if [ ! -f "$actual_path" ]; then
        log_message "ERROR: wp-config.php not found at $actual_path"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY-RUN] Would patch \$table_prefix: '$old_prefix' -> '$new_prefix'"
        return 0
    fi

    # Replace both $table_prefix and $wpdb->prefix (defensive).
    # Use a delimiter unlikely to appear in PHP: ASCII Unit Separator (0x1f).
    local sep=$'\x1f'
    sed -i.bak -E "s${sep}(\\\$(table_prefix|wpdb->prefix)[[:space:]]*=[[:space:]]*['\"]).*${sep}\1${new_prefix}'${sep}g" "$actual_path"
    rm -f "$actual_path.bak"

    if [ "$in_container" = true ]; then
        if ! docker cp "$actual_path" "$container:$cdocroot" 2>/dev/null; then
            log_message "ERROR: failed to docker cp patched wp-config.php back to $container:$cdocroot"
            rm -f "$actual_path"
            return 1
        fi
        rm -f "$actual_path"
        log_message "Patched \$table_prefix '$old_prefix' -> '$new_prefix' in $container:$cdocroot"
    else
        log_message "Patched \$table_prefix '$old_prefix' -> '$new_prefix' in $wp_config_path"
    fi
    return 0
}

# Interactive confirmation prompt. Skipped if ASSUME_YES=true. Returns 0
# (proceed) or 1 (abort).
confirm_destructive_action() {
    local msg="$1"
    if [ "$ASSUME_YES" = true ]; then
        log_message "$msg"
        log_message "--yes supplied — proceeding"
        return 0
    fi
    log_message ""
    log_message "==================================================================="
    log_message "  WARNING: $msg"
    log_message "==================================================================="
    local reply
    printf "Type 'yes' to proceed (anything else aborts): "
    read -r reply
    if [ "$reply" = "yes" ]; then
        return 0
    fi
    return 1
}

# Function to restore database (Docker)
restore_database_docker() {
    local sql_file="$1"

    log_message "Restoring database using Docker..."

    # Check if container is running. If not, try to recover by re-resolving
    # from the running stack (the value we have may be a stale compose
    # service name like "db" rather than the real container name, or the
    # container may be named under a different project).
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
        log_message "WARN: Database container '$DB_CONTAINER' is not running; trying to discover the real running container..."
        if resolve_db_container_from_running_stack "${DB_HOST:-}"; then
            log_message "Discovered running DB container: $DB_CONTAINER"
        fi
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
            log_message "ERROR: Could not find a running database container"
            log_message "  Tried: '$DB_CONTAINER' (from compose / .dbinfo)"
            log_message "  DB_HOST from wp-config.php: '${DB_HOST:-<unset>}'"
            log_message "  Please start your Docker containers first: docker compose up -d"
            log_message "  Or pass the WordPress container with -c to use env-var lookup."
            return 1
        fi
    fi

    # Check if SQL file exists and has content
    if [ ! -s "$sql_file" ]; then
        log_message "ERROR: Database backup file is empty or does not exist"
        return 1
    fi
    
    # Create database restore command for Docker
    local docker_restore_cmd=""
    
    if [ "$DB_TYPE" = "mariadb" ]; then
        docker_restore_cmd="docker exec -i $DB_CONTAINER mariadb -u$DB_USER"
    else
        docker_restore_cmd="docker exec -i $DB_CONTAINER mysql -u$DB_USER"
    fi
    
    if [ -n "$DB_PASSWORD" ]; then
        docker_restore_cmd="$docker_restore_cmd -p$DB_PASSWORD"
    fi
    
    docker_restore_cmd="$docker_restore_cmd $DB_NAME"
    
    # Execute database restore. Capture stdout to a tmpfile so we don't
    # leak DB content (multi-row INSERT...VALUES rows, etc.) to the user's
    # terminal on a successful import. If the command fails, we surface
    # the captured output alongside the error message.
    local _restore_stdout _restore_stderr _restore_rc
    _restore_stdout=$(mktemp)
    _restore_stderr=$(mktemp)
    trap "rm -f '$_restore_stdout' '$_restore_stderr'" RETURN
    eval "$docker_restore_cmd" < "$sql_file" > "$_restore_stdout" 2> "$_restore_stderr"
    _restore_rc=$?
    if [ "$_restore_rc" = 0 ]; then
        log_message "Database restored successfully using Docker"
        return 0
    else
        log_message "ERROR: Failed to restore database using Docker"
        log_message "Please check database credentials and container status"
        # Surface captured output only on failure (truncated to last 30 lines).
        if [ -s "$_restore_stderr" ]; then
            log_message "MySQL stderr (last 30 lines):"
            tail -n 30 "$_restore_stderr" | sed 's/^/  [mysql] /'
        fi
        if [ -s "$_restore_stdout" ]; then
            log_message "MySQL stdout (last 30 lines):"
            tail -n 30 "$_restore_stdout" | sed 's/^/  [mysql] /'
        fi
        return 1
    fi
}

# Function to restore database (Native)
restore_database_native() {
    local sql_file="$1"
    
    log_message "Restoring database using native $DB_TYPE..."
    
    # Check if SQL file exists and has content
    if [ ! -s "$sql_file" ]; then
        log_message "ERROR: Database backup file is empty or does not exist"
        return 1
    fi
    
    # Create database restore command based on service type
    local restore_cmd=""
    if [ "$DB_TYPE" = "mariadb" ]; then
        restore_cmd="mariadb -h$DB_HOST -u$DB_USER"
    else
        restore_cmd="mysql -h$DB_HOST -u$DB_USER"
    fi
    
    if [ -n "$DB_PASSWORD" ]; then
        restore_cmd="$restore_cmd -p$DB_PASSWORD"
    fi
    
    restore_cmd="$restore_cmd $DB_NAME"
    
    # Execute database restore. Capture stdout to a tmpfile so we don't
    # leak DB content (multi-row INSERT...VALUES rows, etc.) to the user's
    # terminal on a successful import. If the command fails, we surface
    # the captured output alongside the error message.
    local _restore_stdout _restore_stderr _restore_rc
    _restore_stdout=$(mktemp)
    _restore_stderr=$(mktemp)
    trap "rm -f '$_restore_stdout' '$_restore_stderr'" RETURN
    eval "$restore_cmd" < "$sql_file" > "$_restore_stdout" 2> "$_restore_stderr"
    _restore_rc=$?
    if [ "$_restore_rc" = 0 ]; then
        log_message "Database restored successfully using native $DB_TYPE"
        return 0
    else
        log_message "ERROR: Failed to restore database using native $DB_TYPE"
        log_message "Please check database credentials and service availability"
        if [ -s "$_restore_stderr" ]; then
            log_message "MySQL stderr (last 30 lines):"
            tail -n 30 "$_restore_stderr" | sed 's/^/  [mysql] /'
        fi
        if [ -s "$_restore_stdout" ]; then
            log_message "MySQL stdout (last 30 lines):"
            tail -n 30 "$_restore_stdout" | sed 's/^/  [mysql] /'
        fi
        return 1
    fi
}

# Function to detect old URL from backup's wp_options
detect_old_url() {
    local wp_config_path="$1"

    # Try to extract siteurl from the SQL file in the backup.
    # IMPORTANT: Use 'grep -m 1' to stop after the first match (not 'head -1'
    # which only stops after a newline, and would leak the rest of a
    # multi-line INSERT that contains serialized data spanning many lines).
    if [ -f "$TEMP_DIR/database.sql" ]; then
        local detected_url
        detected_url=$(grep -oE "'https?://[^']+'" "$TEMP_DIR/database.sql" 2>/dev/null | grep -m 1 -oE "https?://[^']+")
        if [ -n "$detected_url" ]; then
            echo "$detected_url"
            return 0
        fi
    fi

    # Fallback: try to read wp-config.php DB_HOST as a hint (less reliable)
    if [ -f "$wp_config_path" ]; then
        local db_host
        db_host=$(grep -E "DB_HOST" "$wp_config_path" 2>/dev/null | head -1 | grep -oE "'[^']+'" | tr -d "'")
        if [ -n "$db_host" ] && [ "$db_host" != "localhost" ] && [ "$db_host" != "127.0.0.1" ]; then
            echo "http://$db_host"
            return 0
        fi
    fi

    return 1
}

# Function to detect old URL from the LIVE WordPress database (fix mode).
# Reads the 'siteurl' option from the live DB using already-extracted credentials.
# Falls back to the existing detect_old_url() (which needs the SQL dump) if that fails.
detect_old_url_from_live_db() {
    # Need DB credentials to be extracted first; bail out if not.
    if [ -z "$DB_NAME" ]; then
        return 1
    fi
    # Try siteurl first; if missing, fall back to home.
    local detected
    detected=$(run_db_query_capture "SELECT option_value FROM $(get_table_prefix)options WHERE option_name='siteurl' LIMIT 1;" 2>/dev/null | tail -1 | tr -d '\r')
    if [ -z "$detected" ]; then
        detected=$(run_db_query_capture "SELECT option_value FROM $(get_table_prefix)options WHERE option_name='home' LIMIT 1;" 2>/dev/null | tail -1 | tr -d '\r')
    fi
    if [ -n "$detected" ]; then
        echo "$detected"
        return 0
    fi
    return 1
}

# Function to build the mysql/mariadb client command for queries
build_db_query_cmd() {
    # Outputs the prefix command to run a query against the DB.
    # Caller is responsible for appending the SQL.

    if [ "$IS_DOCKER" = true ]; then
        local cmd="docker exec -i $DB_CONTAINER"
        if [ "$DB_TYPE" = "mariadb" ]; then
            cmd="$cmd mariadb"
        else
            cmd="$cmd mysql"
        fi
        cmd="$cmd -u$DB_USER"
        [ -n "$DB_PASSWORD" ] && cmd="$cmd -p$DB_PASSWORD"
        cmd="$cmd -N -B $DB_NAME"
        echo "$cmd"
    else
        local cmd=""
        if [ "$DB_TYPE" = "mariadb" ]; then
            cmd="mariadb"
        else
            cmd="mysql"
        fi
        cmd="$cmd -h$DB_HOST -u$DB_USER"
        [ -n "$DB_PASSWORD" ] && cmd="$cmd -p$DB_PASSWORD"
        cmd="$cmd -N -B $DB_NAME"
        echo "$cmd"
    fi
}

# Function to run a SQL query against the restored database
# Uses temp file + pipe to avoid bash eval double-interpreting '$' in passwords/hashes
# IMPORTANT: build_db_query_cmd already includes 'docker exec' for Docker env,
# so do NOT wrap it again — just pipe into it as stdin to mariadb/mysql.
run_db_query() {
    local query="$1"
    local db_cmd
    db_cmd=$(build_db_query_cmd)
    local query_file
    query_file=$(mktemp)
    # Capture stdout+stderr to temp files; only surface on failure.
    # mysql/mariadb may print table data to stdout during UPDATE statements
    # (e.g. when re-reading triggers, or with verbose modes) - we MUST
    # suppress stdout to avoid leaking DB content into the restore log.
    local _qd_stdout _qd_stderr
    _qd_stdout=$(mktemp)
    _qd_stderr=$(mktemp)
    trap "rm -f '$query_file' '$_qd_stdout' '$_qd_stderr'" RETURN
    # Write query to file with no shell expansion (printf preserves $ literally)
    printf '%s\n' "$query" > "$query_file"
    # Pipe into the command; redirect ALL output to temp files.
    # db_cmd ends with the DB name (no -e flag).
    $db_cmd < "$query_file" > "$_qd_stdout" 2> "$_qd_stderr"
    local rc=$?
    if [ "$rc" != 0 ]; then
        # On failure, surface captured output (truncated) for debugging
        if [ -s "$_qd_stderr" ]; then
            log_message "DB query stderr (last 20 lines):"
            tail -n 20 "$_qd_stderr" | sed 's/^/  [query] /'
        fi
        if [ -s "$_qd_stdout" ]; then
            log_message "DB query stdout (last 20 lines):"
            tail -n 20 "$_qd_stdout" | sed 's/^/  [query] /'
        fi
    fi
    return $rc
}

# Function to capture output of a SQL query (for SELECT statements)
run_db_query_capture() {
    local query="$1"
    local db_cmd
    db_cmd=$(build_db_query_cmd)
    local query_file
    query_file=$(mktemp)
    # For capture we WANT stdout (that's the SELECT result), so only redirect stderr.
    trap "rm -f '$query_file'" RETURN
    printf '%s\n' "$query" > "$query_file"
    local output
    output=$($db_cmd < "$query_file" 2>/dev/null)
    echo "$output"
}

# Function to update URLs throughout the database
update_database_urls() {
    if [ -z "$NEW_URL" ]; then
        return 0
    fi

    # Auto-detect OLD_URL if not specified
    if [ -z "$OLD_URL" ]; then
        local detected
        detected=$(detect_old_url "$TEMP_DIR/files/wp-config.php")
        if [ -n "$detected" ]; then
            OLD_URL="$detected"
            log_message "Auto-detected old URL from backup: $OLD_URL"
        else
            log_message "WARNING: Could not auto-detect old URL; using NEW_URL as-is for siteurl/home only"
            # Without OLD_URL we can only set siteurl/home directly
            run_db_query "UPDATE $(get_table_prefix)options SET option_value='$NEW_URL' WHERE option_name IN ('siteurl', 'home');"
            log_message "Updated siteurl/home to: $NEW_URL"
            return 0
        fi
    fi

    if [ "$OLD_URL" = "$NEW_URL" ]; then
        log_message "Old and new URL are identical; skipping URL replacement"
        return 0
    fi

    log_message "Replacing URLs in database:"
    log_message "  From: $OLD_URL"
    log_message "  To:   $NEW_URL"

    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY-RUN] Would replace '$OLD_URL' with '$NEW_URL' in all wp_options, wp_posts, wp_postmeta, wp_comments, wp_commentmeta, wp_links, wp_term_taxonomy, wp_usermeta"
        return 0
    fi

    local table_prefix
    table_prefix=$(get_table_prefix)

    # Tables that commonly contain URLs (serialized data needs careful handling)
    local tables=(
        "${table_prefix}options"
        "${table_prefix}posts"
        "${table_prefix}postmeta"
        "${table_prefix}comments"
        "${table_prefix}commentmeta"
        "${table_prefix}links"
        "${table_prefix}term_taxonomy"
        "${table_prefix}usermeta"
    )

    # Replace in plain text columns (posts.guid, posts.post_content, posts.post_excerpt, etc.)
    run_db_query "UPDATE ${table_prefix}posts SET guid = REPLACE(guid, '$OLD_URL', '$NEW_URL'), post_content = REPLACE(post_content, '$OLD_URL', '$NEW_URL'), post_excerpt = REPLACE(post_excerpt, '$OLD_URL', '$NEW_URL');"
    run_db_query "UPDATE ${table_prefix}options SET option_value = REPLACE(option_value, '$OLD_URL', '$NEW_URL');"
    run_db_query "UPDATE ${table_prefix}postmeta SET meta_value = REPLACE(meta_value, '$OLD_URL', '$NEW_URL');"
    run_db_query "UPDATE ${table_prefix}comments SET comment_content = REPLACE(comment_content, '$OLD_URL', '$NEW_URL'), comment_author_url = REPLACE(comment_author_url, '$OLD_URL', '$NEW_URL');"
    run_db_query "UPDATE ${table_prefix}commentmeta SET meta_value = REPLACE(meta_value, '$OLD_URL', '$NEW_URL');"
    run_db_query "UPDATE ${table_prefix}links SET link_url = REPLACE(link_url, '$OLD_URL', '$NEW_URL'), link_image = REPLACE(link_image, '$OLD_URL', '$NEW_URL');"
    run_db_query "UPDATE ${table_prefix}usermeta SET meta_value = REPLACE(meta_value, '$OLD_URL', '$NEW_URL');"

    log_message "URL replacement completed"
}

# Function to get WordPress table prefix from wp-config.php in restored files
get_table_prefix() {
    local wp_config="$WORDPRESS_DIR/wp-config.php"
    if [ -f "$wp_config" ]; then
        local prefix
        prefix=$(grep -E "\\\$table_prefix" "$wp_config" 2>/dev/null | head -1 | sed -E "s/.*table_prefix[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\1/")
        if [ -n "$prefix" ]; then
            echo "$prefix"
            return 0
        fi
    fi
    # Default WordPress prefix
    echo "wp_"
}

# Function to update site title (blogname option)
update_site_title() {
    if [ -z "$NEW_TITLE" ]; then
        return 0
    fi

    log_message "Updating site title to: $NEW_TITLE"

    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY-RUN] Would set blogname option to '$NEW_TITLE'"
        return 0
    fi

    local table_prefix
    table_prefix=$(get_table_prefix)
    local escaped_title="${NEW_TITLE//\'/\'\'}"
    run_db_query "UPDATE ${table_prefix}options SET option_value='$escaped_title' WHERE option_name='blogname';"
    log_message "Site title updated"
}

# Function to create or update admin user
update_admin_user() {
    if [ -z "$ADMIN_USER" ]; then
        return 0
    fi

    if [ -z "$ADMIN_PASSWORD" ] || [ -z "$ADMIN_EMAIL" ]; then
        log_message "ERROR: -A ADMIN_USER requires both -P ADMIN_PASSWORD and -E ADMIN_EMAIL"
        return 1
    fi

    log_message "Setting up admin user: $ADMIN_USER <$ADMIN_EMAIL>"

    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY-RUN] Would create or update admin user '$ADMIN_USER' with email '$ADMIN_EMAIL'"
        return 0
    fi

    local table_prefix
    table_prefix=$(get_table_prefix)

    # WordPress password hashing using PHP (must run inside a container that has PHP)
    # PHP is typically in the web server container (OLS/Apache/nginx), not the DB container.
    # We try: 1) user-supplied $PHP_CONTAINER, 2) auto-detect from compose, 3) fallback list, 4) host php
    local wp_hash
    local php_container=""
    if [ -n "$PHP_CONTAINER" ]; then
        php_container="$PHP_CONTAINER"
    elif [ -n "$COMPOSE_DIR" ]; then
        # Auto-detect web server container from docker-compose.yml (skip db/mariadb/mysql/postgres)
        php_container=$(cd "$COMPOSE_DIR" && docker compose ps --services 2>/dev/null | grep -vE '^(db|database|mariadb|mysql|postgres|redis)' | head -1)
        if [ -n "$php_container" ]; then
            php_container=$(cd "$COMPOSE_DIR" && docker compose ps -q "$php_container" 2>/dev/null)
        fi
    fi
    # Fallback: try common web container names
    if [ -z "$php_container" ] || ! docker exec "$php_container" which php >/dev/null 2>&1; then
        for try in wordpress web app nginx apache httpd ols lsws; do
            local cid
            cid=$(docker ps -q -f "name=$try" 2>/dev/null | head -1)
            if [ -n "$cid" ] && docker exec "$cid" which php >/dev/null 2>&1; then
                php_container="$cid"
                break
            fi
        done
    fi

    if [ "$IS_DOCKER" = true ] && [ -n "$php_container" ] && docker exec "$php_container" which php >/dev/null 2>&1; then
        wp_hash=$(docker exec "$php_container" php -r "echo password_hash(getenv('WP_ADMIN_PASS'), PASSWORD_BCRYPT);" 2>/dev/null < <(echo "$ADMIN_PASSWORD"))
        # The above passes password via stdin env-substitution; safer approach: write to temp file
        local pass_file
        pass_file=$(mktemp)
        chmod 600 "$pass_file"
        # trap RETURN guarantees cleanup on any exit path (error or success)
        trap "rm -f '$pass_file'" RETURN
        printf '%s' "$ADMIN_PASSWORD" > "$pass_file"
        wp_hash=$(docker exec -i "$php_container" php -r "\$p = trim(file_get_contents('php://stdin')); echo password_hash(\$p, PASSWORD_BCRYPT);" < "$pass_file" 2>/dev/null)
    elif command -v php >/dev/null 2>&1; then
        wp_hash=$(php -r "echo password_hash(getenv('WP_ADMIN_PASS'), PASSWORD_BCRYPT);" 2>/dev/null < <(echo "$ADMIN_PASSWORD"))
    else
        log_message "ERROR: PHP not found (tried: compose web service, common names, host). Cannot hash password."
        log_message "       Install php-cli on host (e.g., 'sudo apt install php-cli') or set PHP_CONTAINER env var."
        return 1
    fi

    if [ -z "$wp_hash" ]; then
        log_message "ERROR: Failed to generate password hash (PHP not available?)"
        return 1
    fi

    # Escape single quotes in hash and email for SQL safety
    local safe_hash="${wp_hash//\'/\'\'}"
    local safe_email="${ADMIN_EMAIL//\'/\'\'}"
    local safe_user="${ADMIN_USER//\'/\'\'}"

    # Check if user already exists
    local existing_id
    existing_id=$(run_db_query_capture "SELECT ID FROM ${table_prefix}users WHERE user_login='$safe_user' LIMIT 1;")

    if [ -n "$existing_id" ]; then
        log_message "User '$ADMIN_USER' exists (ID=$existing_id); updating password and email"
        run_db_query "UPDATE ${table_prefix}users SET user_pass='$safe_hash', user_email='$safe_email' WHERE ID=$existing_id;"
    else
        log_message "Creating new admin user '$ADMIN_USER'"
        local registered
        registered=$(date '+%Y-%m-%d %H:%M:%S')
        run_db_query "INSERT INTO ${table_prefix}users (user_login, user_pass, user_nicename, user_email, user_registered, user_status, display_name) VALUES ('$safe_user', '$safe_hash', '$safe_user', '$safe_email', '$registered', 0, '$safe_user');"
        existing_id=$(run_db_query_capture "SELECT ID FROM ${table_prefix}users WHERE user_login='$safe_user' LIMIT 1;")
    fi

    if [ -z "$existing_id" ]; then
        log_message "ERROR: Failed to create or find user '$ADMIN_USER'"
        return 1
    fi

    # Ensure user has administrator role
    run_db_query "DELETE FROM ${table_prefix}usermeta WHERE user_id=$existing_id AND meta_key='${table_prefix}capabilities';"
    run_db_query "INSERT INTO ${table_prefix}usermeta (user_id, meta_key, meta_value) VALUES ($existing_id, '${table_prefix}capabilities', 'a:1:{s:13:\"administrator\";b:1;}');"
    run_db_query "DELETE FROM ${table_prefix}usermeta WHERE user_id=$existing_id AND meta_key='${table_prefix}user_level';"
    run_db_query "INSERT INTO ${table_prefix}usermeta (user_id, meta_key, meta_value) VALUES ($existing_id, '${table_prefix}user_level', '10');"

    log_message "Admin user '$ADMIN_USER' (ID=$existing_id) is configured as administrator"
}

# Function to restore WordPress files into a Docker container using 'docker cp'.
# Used in container-direct mode (-c). The backup is restored INTO the
# container (no host bind mount required) using the document root path
# supplied with -d (default /var/www/html).
restore_files_to_container() {
    local container="$1"
    local docroot="$2"
    local backup_wp_dir="$3"

    # Validate container is running
    if ! docker inspect "$container" >/dev/null 2>&1; then
        log_message "ERROR: Container '$container' does not exist"
        return 1
    fi
    local state=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)
    if [ "$state" != "true" ]; then
        log_message "ERROR: Container '$container' is not running"
        return 1
    fi

    if [ "$BACKUP_MODE" = "lightweight" ]; then
        log_message "Restoring WordPress files to container '$container' (lightweight mode)..."

        # For lightweight restore in container-direct mode, we can't easily
        # check for wp-includes inside the container via a quick stat — use
        # 'docker exec test -d' instead.
        if ! docker exec "$container" test -d "$docroot/wp-includes" >/dev/null 2>&1; then
            log_message "WARNING: Target container docroot does not appear to contain WordPress core (no wp-includes found)."
            log_message "         Lightweight backup only contains wp-content + wp-config.php + .htaccess."
            log_message "         You need to install WordPress core in the container first, then run this restore again."
            return 1
        fi

        # Push wp-content
        if [ -d "$backup_wp_dir/wp-content" ]; then
            if [ "$DRY_RUN" = true ]; then
                log_message "[DRY-RUN] Would docker cp wp-content -> $container:$docroot/"
            else
                # Backup existing wp-content inside container by renaming it
                local wp_content_inside_backup=""
                if docker exec "$container" test -d "$docroot/wp-content" >/dev/null 2>&1; then
                    local ts=$(date +%Y%m%d_%H%M%S)
                    log_message "Backing up existing wp-content inside container to wp-content.backup.$ts"
                    docker exec "$container" sh -c "mv '$docroot/wp-content' '$docroot/wp-content.backup.$ts'" 2>/dev/null || true
                    wp_content_inside_backup="${docroot}/wp-content.backup.$ts"
                    RESTORE_SAFETY_BACKUPS+=("docker://${container}:${wp_content_inside_backup}")
                fi
                # docker cp expects a directory; source ends without / for directories
                if docker cp "$backup_wp_dir/wp-content" "$container:$docroot/" 2>/dev/null; then
                    # 'docker cp' always creates files inside the container as
                    # root:root, regardless of who runs docker on the host.
                    # If the web server runs as a non-root UID (nobody/www-data),
                    # uploads/plugin updates will break. chown to the original
                    # wp-content's owner we just moved out of the way; fall back
                    # to the docroot owner if no prior wp-content existed.
                    local target_owner_group=""
                    if [ -n "$wp_content_inside_backup" ]; then
                        target_owner_group=$(docker exec "$container" stat -c '%u:%g' "$wp_content_inside_backup" 2>/dev/null || true)
                    fi
                    [ -z "$target_owner_group" ] && target_owner_group=$(docker exec "$container" stat -c '%u:%g' "$docroot" 2>/dev/null || echo "")
                    if [ -n "$target_owner_group" ]; then
                        docker exec "$container" chown -R "$target_owner_group" "$docroot/wp-content" 2>/dev/null \
                            || log_message "WARNING: Could not chown wp-content to $target_owner_group inside container"
                    fi
                    log_message "wp-content restored to container"
                else
                    log_message "ERROR: Failed to docker cp wp-content to container"
                    return 1
                fi
            fi
        fi

        # Push wp-config.php
        if [ -f "$backup_wp_dir/wp-config.php" ]; then
            if [ "$DRY_RUN" = true ]; then
                log_message "[DRY-RUN] Would docker cp wp-config.php -> $container:$docroot/"
            else
                local wp_config_inside_backup=""
                if docker exec "$container" test -f "$docroot/wp-config.php" >/dev/null 2>&1; then
                    local ts=$(date +%Y%m%d_%H%M%S)
                    log_message "Backing up existing wp-config.php inside container to wp-config.php.backup.$ts"
                    docker exec "$container" sh -c "mv '$docroot/wp-config.php' '$docroot/wp-config.php.backup.$ts'" 2>/dev/null || true
                    wp_config_inside_backup="${docroot}/wp-config.php.backup.$ts"
                    RESTORE_SAFETY_BACKUPS+=("docker://${container}:${wp_config_inside_backup}")
                fi
                if docker cp "$backup_wp_dir/wp-config.php" "$container:$docroot/" 2>/dev/null; then
                    local target_owner_group=""
                    if [ -n "$wp_config_inside_backup" ]; then
                        target_owner_group=$(docker exec "$container" stat -c '%u:%g' "$wp_config_inside_backup" 2>/dev/null || true)
                    fi
                    [ -z "$target_owner_group" ] && target_owner_group=$(docker exec "$container" stat -c '%u:%g' "$docroot" 2>/dev/null || echo "")
                    if [ -n "$target_owner_group" ]; then
                        docker exec "$container" chown "$target_owner_group" "$docroot/wp-config.php" 2>/dev/null \
                            || log_message "WARNING: Could not chown wp-config.php to $target_owner_group inside container"
                    fi
                    log_message "wp-config.php restored to container"
                else
                    log_message "ERROR: Failed to docker cp wp-config.php to container"
                    return 1
                fi
            fi
        else
            log_message "ERROR: wp-config.php not found in backup"
            return 1
        fi

        # Push .htaccess
        if [ -f "$backup_wp_dir/.htaccess" ]; then
            if [ "$DRY_RUN" = true ]; then
                log_message "[DRY-RUN] Would docker cp .htaccess -> $container:$docroot/"
            else
                local htaccess_inside_backup=""
                if docker exec "$container" test -f "$docroot/.htaccess" >/dev/null 2>&1; then
                    local ts=$(date +%Y%m%d_%H%M%S)
                    log_message "Backing up existing .htaccess inside container to .htaccess.backup.$ts"
                    docker exec "$container" sh -c "mv '$docroot/.htaccess' '$docroot/.htaccess.backup.$ts'" 2>/dev/null || true
                    htaccess_inside_backup="${docroot}/.htaccess.backup.$ts"
                    RESTORE_SAFETY_BACKUPS+=("docker://${container}:${htaccess_inside_backup}")
                fi
                if docker cp "$backup_wp_dir/.htaccess" "$container:$docroot/" 2>/dev/null; then
                    local target_owner_group=""
                    if [ -n "$htaccess_inside_backup" ]; then
                        target_owner_group=$(docker exec "$container" stat -c '%u:%g' "$htaccess_inside_backup" 2>/dev/null || true)
                    fi
                    [ -z "$target_owner_group" ] && target_owner_group=$(docker exec "$container" stat -c '%u:%g' "$docroot" 2>/dev/null || echo "")
                    if [ -n "$target_owner_group" ]; then
                        docker exec "$container" chown "$target_owner_group" "$docroot/.htaccess" 2>/dev/null \
                            || log_message "WARNING: Could not chown .htaccess to $target_owner_group inside container"
                    fi
                    log_message ".htaccess restored to container"
                else
                    log_message "WARNING: Failed to docker cp .htaccess (non-critical)"
                fi
            fi
        fi

        log_message "Lightweight restore to container completed"
        return 0
    else
        log_message "Restoring WordPress files to container '$container' (full mode)..."

        if [ "$DRY_RUN" = true ]; then
            log_message "[DRY-RUN] Would docker cp $backup_wp_dir/. -> $container:$docroot/"
            log_message "[DRY-RUN] (existing files would be backed up inside container first)"
            return 0
        fi

        # Backup entire docroot inside container by renaming it
        local docroot_inside_backup=""
        if docker exec "$container" test -d "$docroot" >/dev/null 2>&1; then
            local ts=$(date +%Y%m%d_%H%M%S)
            log_message "Backing up existing docroot inside container to $docroot.backup.$ts"
            docker exec "$container" sh -c "mv '$docroot' '$docroot.backup.$ts'" 2>/dev/null || true
            docroot_inside_backup="${docroot}.backup.$ts"
            RESTORE_SAFETY_BACKUPS+=("docker://${container}:${docroot_inside_backup}")
            # Recreate empty docroot
            docker exec "$container" mkdir -p "$docroot" 2>/dev/null
        else
            docker exec "$container" mkdir -p "$docroot" 2>/dev/null
        fi

        # Push everything. docker cp requires src/. for directory contents.
        if docker cp "$backup_wp_dir"/. "$container:$docroot/" 2>/dev/null; then
            # 'docker cp' always creates files inside the container as
            # root:root. chown the freshly-pushed tree to the original
            # docroot owner so the web server (nobody/33/1000) can read
            # and write it. Uses the safety backup we just moved out of
            # the way; falls back to nothing if there was no original.
            local target_owner_group=""
            if [ -n "$docroot_inside_backup" ]; then
                target_owner_group=$(docker exec "$container" stat -c '%u:%g' "$docroot_inside_backup" 2>/dev/null || true)
            fi
            if [ -n "$target_owner_group" ]; then
                docker exec "$container" chown -R "$target_owner_group" "$docroot" 2>/dev/null \
                    || log_message "WARNING: Could not chown restored docroot to $target_owner_group inside container"
            fi
            log_message "WordPress files restored to container successfully"
            return 0
        else
            log_message "ERROR: Failed to docker cp WordPress files to container"
            return 1
        fi
    fi
}

# Function to restore WordPress files
restore_files() {
    local backup_wp_dir="$1"
    local target_dir="$2"
    
    if [ "$BACKUP_MODE" = "lightweight" ]; then
        log_message "Restoring WordPress files (lightweight mode)..."
        
        # Create target directory if it doesn't exist
        if [ ! -d "$target_dir" ]; then
            log_message "Creating WordPress directory: $target_dir"
            mkdir -p "$target_dir"
            if [ $? -ne 0 ]; then
                log_message "ERROR: Failed to create WordPress directory"
                return 1
            fi
            NEW_DIR=true
        else
            NEW_DIR=false
        fi
        
        # For lightweight restore, we MUST have an existing WordPress core
        # (or user must install one). Check if wp-includes exists.
        if [ "$NEW_DIR" = false ] && [ ! -d "$target_dir/wp-includes" ]; then
            log_message "WARNING: Target directory exists but does not appear to be a WordPress installation (no wp-includes found)."
            log_message "         Lightweight backup only contains wp-content + wp-config.php + .htaccess."
            log_message "         You need to install WordPress core first, then run this restore again."
            log_message "         Or use a full backup to restore the entire WordPress installation."
            return 1
        fi
        
        # Restore wp-content directory
        if [ -d "$backup_wp_dir/wp-content" ]; then
            # Backup existing wp-content if exists
            local wp_content_backup=""
            if [ -d "$target_dir/wp-content" ]; then
                wp_content_backup="$target_dir/wp-content.backup.$(date +%Y%m%d_%H%M%S)"
                log_message "Backing up existing wp-content to: $wp_content_backup"
                if mv "$target_dir/wp-content" "$wp_content_backup"; then
                    RESTORE_SAFETY_BACKUPS+=("$wp_content_backup")
                else
                    log_message "ERROR: Failed to backup existing wp-content"
                    return 1
                fi
            fi

            if cp -r "$backup_wp_dir/wp-content" "$target_dir/"; then
                # Restore ownership/mode of the original wp-content so the
                # web server (nobody/33/1000) can read/write uploads. Without
                # this, uploads/plugin updates would silently fail with
                # 'Permission denied'. Reference the safety backup we just
                # moved out of the way (root is guaranteed by startup check).
                if [ -n "$wp_content_backup" ] && [ -d "$wp_content_backup" ]; then
                    chown -R --reference="$wp_content_backup" "$target_dir/wp-content" 2>/dev/null \
                        || log_message "WARNING: Could not chown wp-content to match original owner"
                fi
                log_message "wp-content restored successfully"
            else
                log_message "ERROR: Failed to restore wp-content"
                return 1
            fi
        else
            log_message "WARNING: wp-content not found in backup"
        fi

        # Restore wp-config.php
        if [ -f "$backup_wp_dir/wp-config.php" ]; then
            # Backup existing wp-config.php if exists
            local wp_config_backup=""
            if [ -f "$target_dir/wp-config.php" ]; then
                wp_config_backup="$target_dir/wp-config.php.backup.$(date +%Y%m%d_%H%M%S)"
                log_message "Backing up existing wp-config.php to: $wp_config_backup"
                if mv "$target_dir/wp-config.php" "$wp_config_backup"; then
                    RESTORE_SAFETY_BACKUPS+=("$wp_config_backup")
                else
                    log_message "ERROR: Failed to backup existing wp-config.php"
                    return 1
                fi
            fi

            if cp "$backup_wp_dir/wp-config.php" "$target_dir/"; then
                # Restore original ownership so the web server can read the
                # file (and the patched DB creds can be loaded by PHP).
                if [ -n "$wp_config_backup" ] && [ -f "$wp_config_backup" ]; then
                    chown --reference="$wp_config_backup" "$target_dir/wp-config.php" 2>/dev/null \
                        || log_message "WARNING: Could not chown wp-config.php to match original owner"
                fi
                log_message "wp-config.php restored successfully"
            else
                log_message "ERROR: Failed to restore wp-config.php"
                return 1
            fi
        else
            log_message "ERROR: wp-config.php not found in backup"
            return 1
        fi

        # Restore .htaccess if exists in backup
        if [ -f "$backup_wp_dir/.htaccess" ]; then
            local htaccess_backup=""
            if [ -f "$target_dir/.htaccess" ]; then
                htaccess_backup="$target_dir/.htaccess.backup.$(date +%Y%m%d_%H%M%S)"
                log_message "Backing up existing .htaccess to: $htaccess_backup"
                if mv "$target_dir/.htaccess" "$htaccess_backup"; then
                    RESTORE_SAFETY_BACKUPS+=("$htaccess_backup")
                else
                    log_message "ERROR: Failed to backup existing .htaccess"
                    return 1
                fi
            fi

            if cp "$backup_wp_dir/.htaccess" "$target_dir/"; then
                if [ -n "$htaccess_backup" ] && [ -f "$htaccess_backup" ]; then
                    chown --reference="$htaccess_backup" "$target_dir/.htaccess" 2>/dev/null \
                        || log_message "WARNING: Could not chown .htaccess to match original owner"
                fi
                log_message ".htaccess restored successfully"
            else
                log_message "WARNING: Failed to restore .htaccess (non-critical)"
            fi
        fi
        
        # Calculate restored files size
        local files_size=$(du -sh "$target_dir" | cut -f1)
        log_message "Restored WordPress size: $files_size"
        log_message "IMPORTANT: Make sure WordPress core files are installed and match the version used during backup."
        return 0
    else
        log_message "Restoring WordPress files (full mode)..."
        
        # Create target directory if it doesn't exist
        if [ ! -d "$target_dir" ]; then
            log_message "Creating WordPress directory: $target_dir"
            mkdir -p "$target_dir"
            if [ $? -ne 0 ]; then
                log_message "ERROR: Failed to create WordPress directory"
                return 1
            fi
        else
            log_message "WARNING: Target directory exists. Contents will be replaced."
            # Capture owner/group/mode of the existing target BEFORE we move it
            # away. The WordPress container (e.g. litespeedtech/openlitespeed)
            # runs as 'nobody:nogroup' and the bind-mounted host path must
            # match that ownership, otherwise PHP/OLS cannot write uploads,
            # caches, or update plugins/themes. By recording the original
            # ownership here and reapplying it to the freshly-created target_dir
            # and its contents below, we keep the container working after
            # restore — and we also let cleanup_safety_backups() actually
            # remove the renamed backup (otherwise 'rm -rf' as the restore
            # user fails with 'Permission denied' on nobody-owned files).
            local target_owner target_group target_mode
            target_owner=$(stat -c '%u' "$target_dir")
            target_group=$(stat -c '%g' "$target_dir")
            target_mode=$(stat -c '%a' "$target_dir")
            # Backup existing directory — tracked for cleanup on success
            local backup_existing="$target_dir.backup.$(date +%Y%m%d_%H%M%S)"
            log_message "Creating backup of existing directory: $backup_existing"
            if ! mv "$target_dir" "$backup_existing"; then
                log_message "ERROR: Failed to backup existing directory"
                return 1
            fi
            RESTORE_SAFETY_BACKUPS+=("$backup_existing")
            # Recreate target_dir, then restore its original ownership/mode.
            # The WordPress container (e.g. litespeedtech/openlitespeed) runs
            # as 'nobody:nogroup' and the bind-mounted host path must match
            # that ownership — otherwise PHP/OLS can't write uploads, cache,
            # or update plugins/themes. 'mkdir' alone would create a dir
            # owned by the restore user, so we chown/chmod it back to the
            # original. Root is guaranteed at this point (script aborts at
            # startup if not).
            mkdir -p "$target_dir"
            chown --reference="$backup_existing" "$target_dir" 2>/dev/null \
                || chown "${target_owner}:${target_group}" "$target_dir" 2>/dev/null || true
            chmod --reference="$backup_existing" "$target_dir" 2>/dev/null \
                || chmod "$target_mode" "$target_dir" 2>/dev/null || true
        fi
        
        # Copy WordPress files from backup.
        # IMPORTANT: 'cp -r src/* dest/' does NOT match dotfiles (.htaccess, .user.ini, .gitignore, etc.)
        # because shell glob '*' excludes hidden files by default. We must use 'src/.' to include
        # all entries — both regular and dotfiles. Without this fix, .htaccess is silently dropped.
        # Also enable dotglob as a belt-and-suspenders measure in case the source path itself
        # is expanded via a different mechanism.
        shopt -s dotglob
        if cp -r "$backup_wp_dir"/. "$target_dir"/; then
            shopt -u dotglob
            # Restore the original target_dir ownership/mode onto every file
            # we just copied. The 'cp -r' above created files owned by the
                # restore user, which would break the WordPress container
                # running as 'nobody' (uploads, cache writes, plugin updates
                # all fail). Using --reference=backup_existing (which we just
                # moved out of the way) preserves the exact uid:gid the
                # container was using. Root is guaranteed at this point.
                if [ -n "${target_owner:-}" ] && [ -n "${target_group:-}" ]; then
                    chown -R --reference="$backup_existing" "$target_dir" 2>/dev/null \
                        || chown -R "${target_owner}:${target_group}" "$target_dir" 2>/dev/null \
                        || log_message "WARNING: Could not chown restored files to ${target_owner}:${target_group}"
                fi
                log_message "WordPress files restored successfully"

                # Verify dotfiles (e.g. .htaccess) actually made it across — a missing
                # .htaccess will silently break pretty-permalinks on Apache/OLS.
            local missing_dotfiles=()
            for df in "$backup_wp_dir"/.[!.]*; do
                [ -e "$df" ] || continue
                local base
                base=$(basename "$df")
                if [ ! -e "$target_dir/$base" ]; then
                    missing_dotfiles+=("$base")
                fi
            done
            if [ ${#missing_dotfiles[@]} -ne 0 ]; then
                log_message "WARNING: Dotfiles missing in restored target: ${missing_dotfiles[*]}"
                log_message "         Trying to copy them individually..."
                local still_missing=()
                for base in "${missing_dotfiles[@]}"; do
                    if ! cp -r "$backup_wp_dir/$base" "$target_dir/" 2>/dev/null; then
                        still_missing+=("$base")
                    fi
                done
                if [ ${#still_missing[@]} -ne 0 ]; then
                    log_message "ERROR: Failed to restore dotfiles: ${still_missing[*]}"
                    return 1
                fi
                log_message "Dotfiles recovered: ${missing_dotfiles[*]}"
            fi

            # Calculate restored files size
            local files_size=$(du -sh "$target_dir" | cut -f1)
            log_message "Restored WordPress files size: $files_size"
            return 0
        else
            shopt -u dotglob
            log_message "ERROR: Failed to restore WordPress files"
            return 1
        fi
    fi
}

# Parse command line arguments
# Allow long options: --skip-files, --skip-db, --dry-run, --fix-mode,
# --reset-db, --yes
ARGS=$(getopt -o "b:w:c:d:u:U:t:A:P:E:fryh" -l "skip-files,skip-db,dry-run,fix-mode,reset-db,yes" -- "$@" 2>/dev/null)
if [ $? -ne 0 ]; then
    show_help
    exit 1
fi
eval set -- "$ARGS"

while [ $# -gt 0 ]; do
    case "$1" in
        -b)
            BACKUP_FILE="$2"
            shift 2
            ;;
        -w)
            WORDPRESS_DIR="$2"
            shift 2
            ;;
        -c)
            WP_CONTAINER="$2"
            CONTAINER_DIRECT=true
            shift 2
            ;;
        -d)
            WP_CONTAINER_DOCROOT="$2"
            shift 2
            ;;
        -u)
            NEW_URL="$2"
            shift 2
            ;;
        -U)
            OLD_URL="$2"
            shift 2
            ;;
        -t)
            NEW_TITLE="$2"
            shift 2
            ;;
        -A)
            ADMIN_USER="$2"
            shift 2
            ;;
        -P)
            ADMIN_PASSWORD="$2"
            shift 2
            ;;
        -E)
            ADMIN_EMAIL="$2"
            shift 2
            ;;
        -f)
            FIX_MODE=true
            shift
            ;;
        -h)
            SHOW_HELP=true
            shift
            ;;
        --skip-files)
            SKIP_FILES=true
            shift
            ;;
        --skip-db)
            SKIP_DB=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --fix-mode)
            FIX_MODE=true
            shift
            ;;
        -r|--reset-db)
            RESET_DB=true
            shift
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        --)
            shift
            ;;
        *)
            echo "Invalid option: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

# Show help if requested
if [ "$SHOW_HELP" = true ]; then
    show_help
    exit 0
fi

# Require root (sudo). Restore needs to chown restored files to match the
# web-server user (e.g. nobody:65534, www-data:33, 1000:1000 for OLS image)
# — only root can chown to other UIDs. Fail loudly BEFORE any heavy work
# (unzip, docker cp, DB import) starts so the user doesn't waste minutes
# only to get a half-restored site.
if [ "$(id -u)" -ne 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: This script must be run as root (use sudo)" >&2
    echo "       Example: sudo $0 -b BACKUP_FILE -w WORDPRESS_DIR [options]" >&2
    echo "       Restore needs to chown restored files to match the web server user." >&2
    exit 1
fi

# Validate required parameters based on mode
if [ "$FIX_MODE" = true ]; then
    # Fix mode: -w OR -c required, -b NOT required, at least one post-restore option required
    if [ -z "$WORDPRESS_DIR" ] && [ -z "$WP_CONTAINER" ]; then
        echo "ERROR: Fix mode (-f) requires -w WORDPRESS_DIR or -c WP_CONTAINER"
        echo ""
        show_help
        exit 1
    fi
    if [ -n "$WORDPRESS_DIR" ] && [ -n "$WP_CONTAINER" ]; then
        echo "ERROR: -w and -c are mutually exclusive. Use only one."
        echo ""
        show_help
        exit 1
    fi
    if [ -n "$BACKUP_FILE" ]; then
        log_message "NOTE: -b ignored in fix mode (-f)"
    fi
    if [ -z "$NEW_URL" ] && [ -z "$NEW_TITLE" ] && [ -z "$ADMIN_USER" ]; then
        echo "ERROR: Fix mode requires at least one post-restore option: -u, -t, or -A"
        echo ""
        show_help
        exit 1
    fi
    # --skip-files / --skip-db are meaningless in fix mode
    if [ "$SKIP_FILES" = true ] || [ "$SKIP_DB" = true ]; then
        log_message "NOTE: --skip-files / --skip-db ignored in fix mode (-f)"
    fi
else
    # Restore mode: -b required, AND (-w OR -c) required
    if [ -z "$BACKUP_FILE" ]; then
        echo "ERROR: Missing required parameter -b (backup file). Use -f for fix mode."
        echo ""
        show_help
        exit 1
    fi

    if [ -z "$WORDPRESS_DIR" ] && [ -z "$WP_CONTAINER" ]; then
        echo "ERROR: Either -w WORDPRESS_DIR or -c WP_CONTAINER is required"
        echo ""
        show_help
        exit 1
    fi

    if [ -n "$WORDPRESS_DIR" ] && [ -n "$WP_CONTAINER" ]; then
        echo "ERROR: -w and -c are mutually exclusive. Use only one."
        echo ""
        show_help
        exit 1
    fi
fi

# Validate backup file (restore mode only — fix mode does not need a backup)
if [ "$FIX_MODE" != true ]; then
    if [ ! -f "$BACKUP_FILE" ]; then
        log_message "ERROR: Backup file does not exist: $BACKUP_FILE"
        exit 1
    fi

    # Check if backup file is a valid ZIP
    if ! unzip -t "$BACKUP_FILE" >/dev/null 2>&1; then
        log_message "ERROR: Invalid or corrupted backup file: $BACKUP_FILE"
        exit 1
    fi
fi

# Validate conflicting flags
if [ "$FIX_MODE" != true ] && [ "$SKIP_FILES" = true ] && [ "$SKIP_DB" = true ]; then
    log_message "ERROR: --skip-files and --skip-db cannot be used together"
    exit 1
fi

# Convert to absolute paths
if [ -n "$BACKUP_FILE" ]; then
    BACKUP_FILE=$(realpath "$BACKUP_FILE")
fi
if [ -n "$WORDPRESS_DIR" ]; then
    WORDPRESS_DIR=$(realpath "$WORDPRESS_DIR")
fi

# Detect environment (Docker or Native). Skip auto-detect compose-file probing
# in container-direct mode (-c): the user explicitly told us which container
# to restore into, and .dbinfo sidecar carries the DB target.
if [ "$CONTAINER_DIRECT" = true ]; then
    log_message "Container-direct restore mode (-c): skipping compose-file auto-detection"
    # Auto-enable reset-db flow in -c mode: it's the safest way to handle
    # cross-stack restores (different host/container) because we read credentials
    # from the live wp-config.php instead of relying on a stale .dbinfo sidecar.
    # User can opt out by passing --no-reset-db if such an option is added later.
    if [ "$RESET_DB" != true ]; then
        RESET_DB=true
        log_message "Auto-enabled reset-db flow for -c mode (use --no-reset-db to opt out, if implemented)"
    fi
    # Reuse DB info from .dbinfo sidecar if present (preferred); otherwise
    # fall back to docker container inspection of the WP container.
    IS_DOCKER=true
    if [ -n "$BACKUP_DB_HOST" ] && [ -n "$BACKUP_DB_NAME" ]; then
        DB_HOST="$BACKUP_DB_HOST"
        DB_NAME="$BACKUP_DB_NAME"
        DB_USER="$BACKUP_DB_USER"
        DB_PASSWORD="$BACKUP_DB_PASSWORD"
        DB_TYPE="${BACKUP_DB_TYPE:-mysql}"
        DB_CONTAINER="$BACKUP_DB_CONTAINER"
        log_message "Using DB config from .dbinfo: $DB_NAME@$DB_HOST (type=$DB_TYPE)"
    else
        # Fall back: inspect WP container for env vars (may not be set if backup
        # was made before .dbinfo existed).
        if docker inspect "$WP_CONTAINER" >/dev/null 2>&1; then
            DB_HOST=$(docker exec "$WP_CONTAINER" sh -c 'echo "$WORDPRESS_DB_HOST"' 2>/dev/null)
            DB_NAME=$(docker exec "$WP_CONTAINER" sh -c 'echo "$WORDPRESS_DB_NAME"' 2>/dev/null)
            DB_USER=$(docker exec "$WP_CONTAINER" sh -c 'echo "$WORDPRESS_DB_USER"' 2>/dev/null)
            DB_PASSWORD=$(docker exec "$WP_CONTAINER" sh -c 'echo "$WORDPRESS_DB_PASSWORD"' 2>/dev/null)
            if [ -n "$DB_HOST" ] && [ -n "$DB_NAME" ]; then
                log_message "Read DB config from WP container env vars"
                log_message "Database: $DB_NAME on $DB_HOST"
            else
                log_message "ERROR: Cannot determine DB config (no .dbinfo sidecar and no env vars on container)"
                exit 1
            fi
        else
            log_message "ERROR: Container '$WP_CONTAINER' does not exist"
            exit 1
        fi
    fi
    # Resolve DB_CONTAINER from DB_HOST if it's a compose service name (foo:3306)
    if [ -z "$DB_CONTAINER" ] && [ -n "$DB_HOST" ]; then
        svc="${DB_HOST%%:*}"
        DB_CONTAINER="${PROJECT_NAME}-${svc}"
        unset svc
    fi
else
    detect_docker_environment

    # Detect database configuration based on environment.
    # In Docker mode, this is best-effort at this point: we may not yet
    # know DB_HOST (it's only extracted from the backup later). If the
    # compose file is missing or DB_HOST is unknown, we keep going and
    # retry after extract_db_config() — the helper uses DB_HOST from
    # wp-config.php / .dbinfo to discover the running container.
    if [ "$IS_DOCKER" = true ]; then
        detect_docker_database_info || log_message "INFO: Initial DB container detection deferred until after backup extraction"
    else
        if ! detect_native_database_service; then
            log_message "WARNING: Database service auto-detection may not be accurate"
        fi
    fi
fi

# Check dependencies
check_dependencies

log_message "Starting WordPress Restore process"
log_message "Backup file: $BACKUP_FILE"
if [ "$CONTAINER_DIRECT" = true ]; then
    log_message "Target WP container: $WP_CONTAINER (docroot: $WP_CONTAINER_DOCROOT)"
else
    log_message "WordPress directory: $WORDPRESS_DIR"
fi
log_message "Environment: $([ "$IS_DOCKER" = true ] && echo "Docker" || echo "Native")"
log_message "Database type: ${DB_TYPE:-unknown}"

# Create temporary directory
TEMP_DIR=$(mktemp -d)

# Cleanup function — always called via 'trap cleanup EXIT'.
# - Always removes $TEMP_DIR (it lives under /tmp and is recreated per-run).
# - $RESTORE_SAFETY_BACKUPS contains pre-restore backups (www.backup.<TS>, etc.)
#   These are removed ONLY on success. On error, they are preserved so the user
#   can roll back manually. The caller controls cleanup_safety_backups().
cleanup() {
    # Only remove TEMP_DIR — safety backups are managed by cleanup_safety_backups()
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
}

# Remove all preserved safety backups (called after a fully successful restore).
cleanup_safety_backups() {
    if [ ${#RESTORE_SAFETY_BACKUPS[@]} -eq 0 ]; then
        return 0
    fi
    log_message "Removing preserved safety backups (restore completed successfully):"
    local b
    for b in "${RESTORE_SAFETY_BACKUPS[@]}"; do
        if [ -z "$b" ]; then continue; fi
        # Container-direct safety backups are tracked with a docker:// prefix:
        #   docker://<container>:<abs_path_in_container>
        # Host-path backups are passed straight to rm -rf.
        if [[ "$b" == docker://* ]]; then
            local rest="${b#docker://}"
            local container="${rest%%:*}"
            local cpath="${rest#*:}"
            if [ -n "$container" ] && [ -n "$cpath" ]; then
                log_message "  Removing (in container $container): $cpath"
                docker exec "$container" rm -rf "$cpath" 2>/dev/null \
                    || log_message "  WARNING: Failed to remove $cpath in $container"
            fi
        elif [ -e "$b" ]; then
            log_message "  Removing: $b"
            if ! rm -rf "$b" 2>/dev/null; then
                # The pre-restore backup may be owned by a different user
                # (e.g. 'nobody' from the WordPress container's bind mount),
                # so the restore user (e.g. zongbao) can't remove it. Try
                # chmod'ing the tree first to gain write access to directories,
                # then retry. Best-effort: if we still can't remove it, log a
                # warning so the user knows to clean up manually (e.g. via
                # 'docker run --rm -v ... alpine rm -rf' or sudo).
                chmod -R u+rwX "$b" 2>/dev/null || true
                rm -rf "$b" 2>/dev/null \
                    || log_message "  WARNING: Failed to remove $b (owned by a different user? try: sudo rm -rf \"$b\")"
            fi
        fi
    done
    RESTORE_SAFETY_BACKUPS=()
}

# Emit a clear message about any preserved safety backups, then exit 1.
# Use this in main flow error paths so the user knows where their pre-restore
# data went (for manual rollback) instead of wondering why a folder appeared
# beside their WordPress install.
die() {
    local msg="$1"
    log_message "ERROR: $msg"
    if [ ${#RESTORE_SAFETY_BACKUPS[@]} -ne 0 ]; then
        log_message ""
        log_message "Pre-restore backups PRESERVED for manual rollback:"
        local b
        for b in "${RESTORE_SAFETY_BACKUPS[@]}"; do
            if [ -z "$b" ]; then continue; fi
            if [[ "$b" == docker://* ]]; then
                local rest="${b#docker://}"
                local container="${rest%%:*}"
                local cpath="${rest#*:}"
                log_message "  - (in container $container) $cpath"
            elif [ -e "$b" ]; then
                log_message "  - $b"
            fi
        done
        log_message "Remove them manually once you've confirmed the restored site works."
    fi
    exit 1
}

# Set trap to cleanup on exit. Safety backups are intentionally NOT removed
# by the trap — they are only removed by cleanup_safety_backups() on success.
# On error/abort, they remain in place for manual rollback.
trap cleanup EXIT

if [ "$FIX_MODE" = true ]; then
    # ========================================================================
    # FIX MODE: skip backup extraction and file/database restore entirely.
    # Read credentials from the LIVE WordPress installation, then apply the
    # requested post-restore customizations against the live database.
    # ========================================================================
    log_message "========================================================================"
    log_message "FIX MODE (-f): applying post-restore customizations to LIVE site"
    log_message "No files or database will be restored."
    log_message "========================================================================"

    # In fix mode, we need at least one post-restore option (already validated),
    # and we need the live wp-config.php to read DB credentials.
    if [ ! -f "$WORDPRESS_DIR/wp-config.php" ]; then
        log_message "ERROR: wp-config.php not found in $WORDPRESS_DIR"
        log_message "       Fix mode requires an existing WordPress installation with wp-config.php"
        exit 1
    fi

    # Read DB credentials directly from the live wp-config.php (not from backup).
    # The TEMP_DIR we created above is fine — it's empty and will be cleaned up
    # by the trap on exit. (Some helpers like detect_old_url() touch
    # $TEMP_DIR/files/wp-config.php, but in fix mode we don't call those.)
    if ! extract_db_config "$WORDPRESS_DIR"; then
        log_message "ERROR: Failed to extract database configuration from live wp-config.php"
        exit 1
    fi

    # URL auto-detection in fix mode reads 'siteurl' from the live DB
    # (update_database_urls() will pick this up if OLD_URL is empty).
else
    # ========================================================================
    # RESTORE MODE: extract backup, read credentials from backup's wp-config.
    # ========================================================================

    # Extract and validate backup
    if ! extract_backup "$BACKUP_FILE" "$TEMP_DIR"; then
        log_message "ERROR: Failed to extract or validate backup"
        exit 1
    fi

    # Extract database configuration from backup
    if ! extract_db_config "$BACKUP_WP_DIR"; then
        log_message "ERROR: Failed to extract database configuration"
        exit 1
    fi

    # Now that DB_HOST is known (from .dbinfo sidecar or wp-config.php),
    # re-resolve the DB container if we previously failed or got a stale
    # name. This is the common case when restoring a backup from one
    # Docker stack onto a different one (e.g. szreypower-* -> wp-dev-*).
    if [ "$IS_DOCKER" = true ] && [ "$CONTAINER_DIRECT" != true ]; then
        if [ -z "$DB_CONTAINER" ] || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
            log_message "Re-resolving DB container using DB_HOST='$DB_HOST'..."
            if ! detect_docker_database_info; then
                log_message "ERROR: Failed to detect Docker database configuration after extracting backup"
                exit 1
            fi
        fi
    fi
fi

# RESET-DB FLOW (only when explicitly enabled or auto-enabled by -c mode)
# If RESET_DB=true, we discard all DB_* / DB_CONTAINER values from the backup
# (which may refer to the source stack) and instead read creds from the LIVE
# wp-config.php on the target host/container. We then DROP all tables matching
# the live $table_prefix before importing the backup's SQL.
if [ "$RESET_DB" = true ]; then
    log_message ""
    log_message "========== RESET-DB FLOW =========="

    # 1. Read live credentials from the target.
    if ! read_live_wp_config; then
        log_message "ERROR: Failed to read live wp-config.php (reset-db flow aborted)"
        exit 1
    fi

    # 2. Read the backup's table prefix (so we can patch the live wp-config
    #    to use it post-restore, preserving the live credentials).
    if ! read_backup_table_prefix "$BACKUP_WP_DIR"; then
        log_message "ERROR: Failed to read backup \$table_prefix (reset-db flow aborted)"
        exit 1
    fi

    # 3. List tables currently using the LIVE prefix (these will be dropped).
    #    list_tables_with_prefix echoes the count on stdout; capture it.
    DROP_TABLE_COUNT=$(list_tables_with_prefix "$LIVE_DB_NAME" "$LIVE_DB_USER" "$LIVE_DB_PASSWORD" "$LIVE_DB_HOST" 2>/dev/null) || {
        log_message "ERROR: Failed to enumerate live tables (reset-db flow aborted)"
        exit 1
    }
    # Normalize — strip whitespace/blank lines
    DROP_TABLE_COUNT=$(echo "$DROP_TABLE_COUNT" | grep -E '^[0-9]+$' | head -1)
    [ -z "$DROP_TABLE_COUNT" ] && DROP_TABLE_COUNT=0
    log_message "Live tables matching prefix '$LIVE_DB_PREFIX': $DROP_TABLE_COUNT"

    # 4. Confirm destructive action unless we're in dry-run or have -y/--yes.
    confirm_destructive_action "drop $DROP_TABLE_COUNT tables with prefix '$LIVE_DB_PREFIX' in database '$LIVE_DB_NAME' and import the backup"

    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY-RUN] Would DROP $DROP_TABLE_COUNT tables with prefix '$LIVE_DB_PREFIX'"
        log_message "[DRY-RUN] Would import $TEMP_DIR/database.sql into $LIVE_DB_NAME @ $LIVE_DB_HOST"
        log_message "[DRY-RUN] Would override DB_* with live credentials for restore"
    else
        # 5. Drop the live tables.
        if [ "$DROP_TABLE_COUNT" -gt 0 ]; then
            if ! drop_tables_for_prefix "$LIVE_DB_NAME" "$LIVE_DB_USER" "$LIVE_DB_PASSWORD" "$LIVE_DB_HOST" "$LIVE_DB_PREFIX"; then
                log_message "ERROR: Failed to drop live tables (reset-db flow aborted — backup NOT yet imported)"
                exit 1
            fi
        else
            log_message "No live tables with prefix '$LIVE_DB_PREFIX' — skipping DROP step"
        fi
    fi

    # 6. Override DB_* and DB_CONTAINER with live values for the actual restore.
    DB_NAME="$LIVE_DB_NAME"
    DB_USER="$LIVE_DB_USER"
    DB_PASSWORD="$LIVE_DB_PASSWORD"
    DB_HOST="$LIVE_DB_HOST"
    log_message "Using LIVE credentials for restore: $DB_NAME @ $DB_HOST"

    # 7. Re-resolve DB_CONTAINER for the live DB_HOST (the backup's container
    #    name typically refers to the source stack and won't exist here).
    if [ "$IS_DOCKER" = true ]; then
        if [ -z "$DB_CONTAINER" ] || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
            log_message "Re-resolving DB container for live DB_HOST='$DB_HOST'..."
            if ! detect_docker_database_info; then
                # Last-resort: try the running-stack heuristic, then prompt.
                if ! resolve_db_container_from_running_stack "$DB_HOST" true; then
                    log_message "ERROR: Could not find a running DB container that matches DB_HOST='$DB_HOST'"
                    log_message "  (Hint: confirm the target DB container is on the same docker network)"
                    exit 1
                fi
            fi
            # Some helpers leave DB_CONTAINER blank; use the heuristic explicitly.
            if [ -z "$DB_CONTAINER" ] || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
                resolve_db_container_from_running_stack "$DB_HOST" true || true
            fi
        fi
        log_message "Resolved DB_CONTAINER='$DB_CONTAINER' for live DB_HOST='$DB_HOST'"
    fi
    log_message "=================================="
    log_message ""
fi

# Validate conflicting flags (restore mode only — fix mode flags already warned above)
if [ "$FIX_MODE" != true ] && [ "$SKIP_FILES" = true ] && [ "$SKIP_DB" = true ]; then
    log_message "ERROR: --skip-files and --skip-db cannot be used together"
    exit 1
fi
# Reset-db is incompatible with --skip-db: we DROP live tables, then must
# IMPORT the backup. Skipping the import leaves an empty database.
if [ "$RESET_DB" = true ] && [ "$SKIP_DB" = true ]; then
    log_message "ERROR: --reset-db (or -c auto-enable) cannot be combined with --skip-db"
    log_message "  Reset-db drops live tables before importing the backup."
    exit 1
fi
# In fix mode, reset-db makes no sense (we never touch the DB).
if [ "$RESET_DB" = true ] && [ "$FIX_MODE" = true ]; then
    log_message "INFO: --reset-db/-r is ignored in fix mode (no DB restoration occurs)"
    RESET_DB=false
fi

# Print dry-run summary and EXIT before any modifications
if [ "$DRY_RUN" = true ]; then
    log_message ""
    log_message "========== DRY-RUN PLAN =========="
    log_message "Mode:               $([ "$FIX_MODE" = true ] && echo "FIX (no restore, only customizations)" || echo "RESTORE")"
    if [ "$FIX_MODE" != true ]; then
        log_message "Backup file:        $BACKUP_FILE"
        log_message "Backup mode:        $([ "$BACKUP_MODE" = "lightweight" ] && echo "Lightweight" || echo "Full")"
        log_message "Restore DB:         $([ "$SKIP_DB" = true ] && echo "NO (--skip-db)" || echo "YES")"
        log_message "Restore files:      $([ "$SKIP_FILES" = true ] && echo "NO (--skip-files)" || echo "YES")"
    fi
    if [ "$CONTAINER_DIRECT" = true ]; then
        log_message "Target container:   $WP_CONTAINER (docroot: $WP_CONTAINER_DOCROOT)"
    else
        log_message "Target dir:         $WORDPRESS_DIR"
    fi
    log_message "Environment:        $([ "$IS_DOCKER" = true ] && echo "Docker ($DB_CONTAINER)" || echo "Native ($DB_TYPE)")"
    log_message "Database:           $DB_NAME @ $DB_HOST"
    [ -n "$NEW_URL" ] && log_message "URL replacement:    ${OLD_URL:-<auto-detect>} -> $NEW_URL"
    [ -n "$NEW_TITLE" ] && log_message "Site title:         $NEW_TITLE"
    [ -n "$ADMIN_USER" ] && log_message "Admin user:         $ADMIN_USER <$ADMIN_EMAIL>"
    log_message "================================="
    log_message ""
    log_message "No changes were made. Remove --dry-run to perform the actual run."
    log_message "[DRY-RUN] Post-restore customizations would now be applied:"
    [ -n "$NEW_URL" ] && log_message "  - URL replacement: ${OLD_URL:-<auto-detect>} -> $NEW_URL"
    [ -n "$NEW_TITLE" ] && log_message "  - Site title: $NEW_TITLE"
    [ -n "$ADMIN_USER" ] && log_message "  - Admin user: $ADMIN_USER <$ADMIN_EMAIL>"
    exit 0
fi

# Print dry-run summary if enabled (already handled before this point; kept for safety)
# Note: DRY-RUN exits early at the top of this block to avoid modifying anything.

# RESTORE-ONLY: database restoration (skip in fix mode / --skip-db).
SQL_FILE="$TEMP_DIR/database.sql"
if [ "$FIX_MODE" = true ]; then
    log_message "Skipping database restore (fix mode)"
elif [ "$SKIP_DB" = true ]; then
    log_message "Skipping database restoration (--skip-db)"
else
    if [ "$IS_DOCKER" = true ]; then
        if ! restore_database_docker "$SQL_FILE"; then
            die "Docker database restoration failed"
        fi
    else
        if ! restore_database_native "$SQL_FILE"; then
            die "Native database restoration failed"
        fi
    fi
fi

# RESTORE-ONLY: file restoration (skip in fix mode)
if [ "$FIX_MODE" = true ]; then
    log_message "Skipping file restore (fix mode)"
elif [ "$SKIP_FILES" = true ]; then
    log_message "Skipping file restoration (--skip-files)"
else
    # Dispatch: container-direct mode uses docker cp; otherwise restore to host
    if [ "$CONTAINER_DIRECT" = true ]; then
        if ! restore_files_to_container "$WP_CONTAINER" "$WP_CONTAINER_DOCROOT" "$BACKUP_WP_DIR"; then
            die "Files restoration to container failed"
        fi
    else
        if ! restore_files "$BACKUP_WP_DIR" "$WORDPRESS_DIR"; then
            die "Files restoration failed"
        fi
    fi
fi

# RESET-DB POST-RESTORE: patch the live wp-config.php so $table_prefix and
# $wpdb->prefix match the backup (since the live prefix was DROPPED above and
# the imported SQL uses the backup's tables). We keep the live DB credentials.
if [ "$RESET_DB" = true ] && [ "$FIX_MODE" != true ] && [ "$SKIP_FILES" != true ]; then
    log_message ""
    log_message "Patching wp-config.php \$table_prefix: '$LIVE_DB_PREFIX' -> '$BACKUP_TABLE_PREFIX'"
    # Decide target path format based on mode.
    if [ "$CONTAINER_DIRECT" = true ]; then
        WP_CONFIG_TARGET="${WP_CONTAINER}:${WP_CONTAINER_DOCROOT}/wp-config.php"
    else
        WP_CONFIG_TARGET="${WORDPRESS_DIR%/}/wp-config.php"
    fi
    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY-RUN] Would patch $WP_CONFIG_TARGET (table_prefix '$LIVE_DB_PREFIX' -> '$BACKUP_TABLE_PREFIX')"
    else
        if ! patch_wp_config_table_prefix "$WP_CONFIG_TARGET" "$LIVE_DB_PREFIX" "$BACKUP_TABLE_PREFIX"; then
            log_message "WARNING: Failed to patch \$table_prefix in wp-config.php"
            log_message "  You may need to manually change \$table_prefix to '$BACKUP_TABLE_PREFIX' to match the imported tables."
        else
            log_message "Patched wp-config.php \$table_prefix -> '$BACKUP_TABLE_PREFIX'"
        fi
    fi
    log_message ""
fi

# POST-RESTORE: patch DB credentials in wp-config.php to match the creds
# that ACTUALLY imported the database (DB_NAME/USER/PASSWORD/HOST). The
# backup's wp-config.php may point at the source stack's container or DB
# user, which doesn't exist on the target. If we don't patch this, WordPress
# will 500 right after restore. Runs in both reset-db and non-reset-db
# modes (the DB_* vars at this point are the creds used for the import).
if [ "$FIX_MODE" != true ] && [ "$SKIP_FILES" != true ] && [ -n "${DB_NAME:-}" ] && [ -n "${DB_USER:-}" ]; then
    log_message ""
    log_message "Patching wp-config.php DB credentials to match restore target ($DB_NAME @ $DB_HOST)..."
    # Decide target path format based on mode (same rule as reset-db block above).
    if [ "$CONTAINER_DIRECT" = true ]; then
        WP_CONFIG_TARGET_C="${WP_CONTAINER}:${WP_CONTAINER_DOCROOT}/wp-config.php"
    else
        WP_CONFIG_TARGET_C="${WORDPRESS_DIR%/}/wp-config.php"
    fi
    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY-RUN] Would patch DB creds in $WP_CONFIG_TARGET_C"
    else
        if ! patch_wp_config_db_creds "$WP_CONFIG_TARGET_C" "$DB_NAME" "$DB_USER" "${DB_PASSWORD:-}" "${DB_HOST:-localhost}"; then
            log_message "WARNING: Failed to patch DB credentials in wp-config.php"
            log_message "  You may need to manually edit DB_NAME/DB_USER/DB_PASSWORD/DB_HOST"
            log_message "  to match the live database."
        fi
    fi
    log_message ""
fi

# Post-restore customizations.
# - In fix mode: always run them (that's the whole point of fix mode).
# - In restore mode: skip if --skip-db was used.
# - With --dry-run: already exited above, so we always run real actions here.
if [ "$FIX_MODE" = true ]; then
    log_message ""
    log_message "Applying fix-mode customizations to live site..."
    # Auto-detect OLD_URL from live DB if not specified (fix-mode-specific)
    if [ -z "$OLD_URL" ] && [ -n "$NEW_URL" ]; then
        local detected_live
        detected_live=$(detect_old_url_from_live_db)
        if [ -n "$detected_live" ]; then
            OLD_URL="$detected_live"
            log_message "Auto-detected old URL from live DB: $OLD_URL"
        fi
    fi
    update_database_urls
    update_site_title
    update_admin_user
    log_message "Fix-mode customizations completed"
elif [ "$SKIP_DB" = true ]; then
    log_message ""
    log_message "Skipping post-restore customizations (--skip-db was used)"
else
    if [ -n "$NEW_URL" ] || [ -n "$NEW_TITLE" ] || [ -n "$ADMIN_USER" ]; then
        log_message ""
        log_message "Applying post-restore customizations..."
        update_database_urls
        update_site_title
        update_admin_user
        log_message "Post-restore customizations completed"
    fi
fi

if [ "$FIX_MODE" = true ]; then
    log_message ""
    log_message "========================================================================"
    log_message "FIX MODE completed"
    log_message "Live site at: $WORDPRESS_DIR"
    log_message "Database '$DB_NAME' modified"
    log_message "Environment: $([ "$IS_DOCKER" = true ] && echo "Docker ($DB_CONTAINER container)" || echo "Native ($DB_TYPE service)")"
    log_message "========================================================================"
else
    log_message "WordPress Restore completed successfully!"
    log_message "WordPress files restored to: $WORDPRESS_DIR"
    log_message "Database '$DB_NAME' restored successfully"
    log_message "Environment: $([ "$IS_DOCKER" = true ] && echo "Docker ($DB_CONTAINER container)" || echo "Native ($DB_TYPE service)")"
    log_message "Backup mode: $([ "$BACKUP_MODE" = "lightweight" ] && echo "Lightweight" || echo "Full")"
    log_message ""
    log_message "IMPORTANT: Please verify your WordPress installation and update file permissions if needed."
    if [ "$IS_DOCKER" = true ]; then
        log_message "           You may need to restart your Docker containers to apply changes."
    fi
    if [ "$BACKUP_MODE" = "lightweight" ]; then
        log_message "           This was a lightweight restore - ensure WordPress core files exist and match the backup version."
    fi
    # Success path: remove preserved safety backups (www.backup.<TS>, etc.)
    cleanup_safety_backups
fi
