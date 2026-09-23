#!/bin/bash

# WordPress Backup Script
# Creates a backup of WordPress files and database
# Auto-detects Docker or native database services
# Usage: ./wp_backup.sh -w /path/to/wordpress [-o /path/to/backup/output] [-l] [-h]

# Default values
WORDPRESS_DIR=""
OUTPUT_DIR="$(pwd)"
SHOW_HELP=false
DB_TYPE=""
DB_CONTAINER=""
DB_DUMP_CMD=""
IS_DOCKER=false
LIGHTWEIGHT=false
EMAIL_TO=""
EMAIL_FROM="admin@companydomain.com"
# Container-direct mode: backup from a running WordPress Docker container
# without requiring a host bind mount. Use when WordPress files live only
# inside a Docker container (named volume) and no folder is mapped to host.
WP_CONTAINER=""
WP_CONTAINER_DOCROOT="/var/www/html"

# Function to display help
show_help() {
    echo "WordPress Backup Script"
    echo "================================"
    echo ""
    echo "Usage:"
    echo "  Host path:   $0 -w WORDPRESS_DIR [-o OUTPUT_DIR] [-l] [-e EMAIL] [-h]"
    echo "  Container:   $0 -c WP_CONTAINER   [-o OUTPUT_DIR] [-l] [-e EMAIL] [-d DOCROOT] [-h]"
    echo ""
    echo "Options:"
    echo "  -w WORDPRESS_DIR     Path to the WordPress installation directory on the host"
    echo "                       (required if -c is not used)"
    echo "  -c WP_CONTAINER      Name or ID of a running WordPress Docker container."
    echo "                       Use this when WordPress files are NOT mapped to the host"
    echo "                       (e.g. named volumes). Files are pulled via 'docker cp'."
    echo "                       Mutually exclusive with -w."
    echo "  -d DOCROOT           Document root inside the WordPress container"
    echo "                       (default: /var/www/html, used with -c)"
    echo "  -o OUTPUT_DIR        Path to the backup output directory (optional, default: current directory)"
    echo "  -l                   Lightweight mode: backup only wp-content, wp-config.php,"
    echo "                       and .htaccess (optional, default: full backup)"
    echo "  -e EMAIL             Send backup report to this email address (optional)"
    echo "  -h                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Host path (folder mapped from container)"
    echo "  $0 -w /var/www/html/wordpress"
    echo "  $0 -w /var/www/html/wordpress -o /backups -l"
    echo "  $0 -w /home/user/website -e admin@example.com"
    echo ""
    echo "  # Container-direct (WordPress lives only inside Docker)"
    echo "  $0 -c my_project-wordpress-app -o /backups"
    echo "  $0 -c my_project-wordpress-app -l -d /var/www/html -e admin@example.com"
    echo ""
    echo "Output format: [timestamp]_[wordpress-folder-name].zip"
    echo "Example: 20250530_143022_wordpress.zip"
    echo "          20250530_143022_wordpress_lightweight.zip (lightweight mode)"
    echo "          20250530_143022_wp-dev-environment-wordpress-app.zip (container-direct)"
    echo ""
    echo "Features:"
    echo "  - Auto-detects Docker containers or native database services"
    echo "  - Supports both MySQL and MariaDB"
    echo "  - Container-direct mode (-c) for WordPress Docker with no host bind mount"
    echo "  - Full mode: backs up entire WordPress directory + database"
    echo "  - Lightweight mode: backs up wp-content + wp-config.php + .htaccess + database"
    echo "  - Verifies backup integrity"
}

# Function to log messages
log_message() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    if [ -n "$LOG_FILE" ]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

# Initialize log file (captures entire backup session)
init_log_file() {
    LOG_FILE=$(mktemp /tmp/wp_backup_XXXXXX.log)
    : > "$LOG_FILE"
    export LOG_FILE
}

# ---- Shared helpers ----
# Most of these exist to centralize patterns that were duplicated across
# backup_database_docker() / backup_database_native() / check_dependencies() /
# backup_files*() so the dump path, password handling, and a docker
# container-running probe are written once.

# db_dump_client_binary: return "mariadb-dump" or "mysqldump" based on $DB_TYPE.
# Default to mysqldump when DB_TYPE is empty/unset (matches detect_native_database_service fallback).
db_dump_client_binary() {
    if [ "${DB_TYPE:-}" = "mariadb" ]; then
        echo "mariadb-dump"
    else
        echo "mysqldump"
    fi
}

# db_password_arg: return "-p<password>" for mysqldump/mariadb-dump, or empty when
# no password is set. Empty-password semantics match the original inline code
# (which guarded the -p<pass> concat on -n "$DB_PASSWORD").
db_password_arg() {
    local pass="$1"
    if [ -n "$pass" ]; then
        echo "-p${pass}"
    fi
}

# container_is_running: returns 0 if a Docker container with the given name is
# currently running (matches running=True in docker inspect). Returns non-zero
# on missing/stopped container. Wraps the inline `docker ps --format ... |
# grep -qx "$name"` checks scattered across the script.
container_is_running() {
    local name="$1"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"
}

# _execute_db_dump: run a database dump command (already shaped for docker-exec
# or native), capture its stdout to $output_file, and validate the result the
# same way the original backup_database_docker/native did:
#   - On dump success: log size + return 0
#   - On dump failure: log ERROR + return 1
#   - On empty output:  log "ERROR: Database backup file is empty" + return 1
# Mirrors the structure of wp_restore.sh's _execute_db_import.
_execute_db_dump() {
    local dump_cmd="$1"
    local output_file="$2"
    local label="$3"      # "Docker" or "native mysql"/"native mariadb"
    local fail_hint="$4"  # second-line hint on failure (matches originals' second-line logs)

    if eval "$dump_cmd" > "$output_file" 2>/dev/null; then
        log_message "Database backup created successfully: $output_file"
        if [ -s "$output_file" ]; then
            local backup_size
            backup_size=$(du -h "$output_file" | cut -f1)
            log_message "Database backup size: $backup_size"
            return 0
        else
            log_message "ERROR: Database backup file is empty"
            return 1
        fi
    else
        log_message "ERROR: Failed to create database backup using $label"
        log_message "$fail_hint"
        return 1
    fi
}

# _dir_size: a tiny wrapper around `du -sh <path> | cut -f1`. Returns the
# human-readable size of <path> on stdout, or "0" if du is unavailable.
_dir_size() {
    du -sh "$1" 2>/dev/null | cut -f1
}

# Send backup report via email using msmtp
send_email_notification() {
    local status="$1"   # SUCCESS or FAILED
    local exit_code="$2"

    # Skip if no recipient configured or msmtp missing
    if [ -z "$EMAIL_TO" ]; then
        log_message "Email notification skipped (no recipient specified)"
        return 0
    fi

    if ! command -v msmtp &> /dev/null; then
        log_message "WARNING: msmtp not installed, skipping email notification"
        return 1
    fi

    local subject_prefix="[WordPress Backup]"
    if [ "$status" = "SUCCESS" ]; then
        local subject="${subject_prefix} ✅ SUCCESS - ${WORDPRESS_FOLDER_NAME} (${TIMESTAMP})"
    else
        local subject="${subject_prefix} ❌ FAILED - ${WORDPRESS_FOLDER_NAME} (${TIMESTAMP})"
    fi

    local backup_size_line="N/A"
    if [ -f "$BACKUP_PATH" ]; then
        backup_size_line=$(du -h "$BACKUP_PATH" | cut -f1)
    fi

    {
        echo "From: ${EMAIL_FROM}"
        echo "To: ${EMAIL_TO}"
        echo "Subject: ${subject}"
        echo "Date: $(date -R)"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=utf-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        echo "WordPress Backup Report"
        echo "======================="
        echo ""
        echo "Status          : ${status}"
        echo "Exit code       : ${exit_code}"
        echo "WordPress dir   : ${WORDPRESS_DIR}"
        echo "Backup file     : ${BACKUP_PATH:-N/A}"
        echo "Backup size     : ${backup_size_line}"
        echo "Mode            : $([ "$LIGHTWEIGHT" = true ] && echo "Lightweight" || echo "Full")"
        echo "Environment     : $([ "$IS_DOCKER" = true ] && echo "Docker ($DB_CONTAINER)" || echo "Native ($DB_TYPE)")"
        echo "Database        : ${DB_TYPE:-N/A}"
        echo "Timestamp       : ${TIMESTAMP}"
        echo "Finished at     : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host            : $(hostname)"
        echo ""
        echo "----- Backup Log -----"
        if [ -f "$LOG_FILE" ]; then
            cat "$LOG_FILE"
        else
            echo "(no log file found)"
        fi
    } | msmtp --account=default "$EMAIL_TO"

    if [ $? -eq 0 ]; then
        log_message "Backup report sent successfully to ${EMAIL_TO}"
    else
        log_message "WARNING: Failed to send backup report to ${EMAIL_TO}"
    fi
}

# Function to check if required tools are installed
check_dependencies() {
    local missing_tools=()
    
    if ! command -v zip &> /dev/null; then
        missing_tools+=("zip")
    fi
    
    if [ "$IS_DOCKER" = true ]; then
        if ! command -v docker &> /dev/null; then
            missing_tools+=("docker")
        fi
        
        if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
            missing_tools+=("docker-compose")
        fi
    else
        # Check for native database dump tools
        local dump_bin
        dump_bin=$(db_dump_client_binary)
        if ! command -v "$dump_bin" &> /dev/null; then
            missing_tools+=("$dump_bin")
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

# Function to detect database type and container (for Docker)
detect_docker_database_info() {
    local compose_file="$DOCKER_COMPOSE_DIR/docker-compose.yml"
    
    if [ ! -f "$compose_file" ]; then
        log_message "ERROR: docker-compose.yml not found in $DOCKER_COMPOSE_DIR"
        return 1
    fi
    
    log_message "Analyzing docker-compose.yml for database configuration..."
    
    # Detect database type
    if grep -qi "mariadb" "$compose_file"; then
        DB_TYPE="mariadb"
        log_message "Detected database type: MariaDB"
    elif grep -qi "mysql" "$compose_file"; then
        DB_TYPE="mysql"
        log_message "Detected database type: MySQL"
    else
        log_message "ERROR: Could not detect database type (MariaDB/MySQL) in docker-compose.yml"
        return 1
    fi
    
    # Find database container name
    local container_line=$(grep -A 10 -B 5 "$DB_TYPE" "$compose_file" | grep -E "container_name:" | head -1)
    if [ -n "$container_line" ]; then
        DB_CONTAINER=$(echo "$container_line" | sed 's/.*container_name:\s*//' | tr -d '"' | tr -d "'" | xargs)
    else
        # Try to find service name if container_name is not specified
        DB_CONTAINER=$(grep -B 5 -A 10 "$DB_TYPE" "$compose_file" | grep -E "^\s*[a-zA-Z0-9_-]+:" | head -1 | sed 's/:\s*$//' | sed 's/^\s*//')
    fi
    
    if [ -z "$DB_CONTAINER" ]; then
        log_message "ERROR: Could not determine database container name"
        return 1
    fi
    
    log_message "Database container: $DB_CONTAINER"
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
    if command -v mariadb &> /dev/null || command -v mariadb-dump &> /dev/null; then
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

# Function to extract database configuration from wp-config.php
extract_db_config() {
    local wp_config="$1/wp-config.php"

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

# Function to extract DB config from inside a WordPress container.
# Strategy:
#   1) Try to read env vars WORDPRESS_DB_* from the container directly
#      (official WordPress image injects these).
#   2) Fall back to pulling wp-config.php and resolving getenv_docker()
#      expressions by substituting env values.
#   3) Fall back to parsing literal define() values in wp-config.php
#      (works when wp-config.php uses static values instead of helpers).
extract_db_config_from_container() {
    local container="$1"
    local docroot="$2"
    local tmp_dir="$3"

    log_message "Extracting DB configuration from container '$container'..."

    local tmp_wp_config="$tmp_dir/wp-config.php"

    # Pull wp-config.php (we may already have it, but make it idempotent)
    if ! docker cp "$container:$docroot/wp-config.php" "$tmp_wp_config" 2>/dev/null; then
        log_message "ERROR: Failed to copy wp-config.php from container '$container'"
        return 1
    fi

    # Step 1: read env vars from container
    local env_name env_user env_pass env_host
    env_name=$(docker exec "$container" printenv WORDPRESS_DB_NAME 2>/dev/null || true)
    env_user=$(docker exec "$container" printenv WORDPRESS_DB_USER 2>/dev/null || true)
    env_pass=$(docker exec "$container" printenv WORDPRESS_DB_PASSWORD 2>/dev/null || true)
    env_host=$(docker exec "$container" printenv WORDPRESS_DB_HOST 2>/dev/null || true)

    # Step 2: parse getenv_docker() default values from wp-config.php so
    # we can fall back to them when env vars are missing. Pattern:
    #   getenv_docker('WORDPRESS_DB_NAME', 'wordpress')
    local def_name def_user def_pass def_host
    def_name=$(grep -E "getenv_docker\(\s*['\"]WORDPRESS_DB_NAME['\"]" "$tmp_wp_config" 2>/dev/null \
        | sed -n "s/.*WORDPRESS_DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    def_user=$(grep -E "getenv_docker\(\s*['\"]WORDPRESS_DB_USER['\"]" "$tmp_wp_config" 2>/dev/null \
        | sed -n "s/.*WORDPRESS_DB_USER['\"][[:space:]]*,[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    def_pass=$(grep -E "getenv_docker\(\s*['\"]WORDPRESS_DB_PASSWORD['\"]" "$tmp_wp_config" 2>/dev/null \
        | sed -n "s/.*WORDPRESS_DB_PASSWORD['\"][[:space:]]*,[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    def_host=$(grep -E "getenv_docker\(\s*['\"]WORDPRESS_DB_HOST['\"]" "$tmp_wp_config" 2>/dev/null \
        | sed -n "s/.*WORDPRESS_DB_HOST['\"][[:space:]]*,[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/p")

    # Step 3: parse literal define('DB_NAME', 'value') as final fallback
    if [ -z "$def_name" ]; then
        def_name=$(grep "define.*DB_NAME" "$tmp_wp_config" | sed -n "s/.*DB_NAME.*['\"]\\([^'\"]*\\)['\"].*/\\1/p" | head -1)
    fi
    if [ -z "$def_user" ]; then
        def_user=$(grep "define.*DB_USER" "$tmp_wp_config" | sed -n "s/.*DB_USER.*['\"]\\([^'\"]*\\)['\"].*/\\1/p" | head -1)
    fi
    if [ -z "$def_pass" ]; then
        def_pass=$(grep "define.*DB_PASSWORD" "$tmp_wp_config" | sed -n "s/.*DB_PASSWORD.*['\"]\\([^'\"]*\\)['\"].*/\\1/p" | head -1)
    fi
    if [ -z "$def_host" ]; then
        def_host=$(grep "define.*DB_HOST" "$tmp_wp_config" | sed -n "s/.*DB_HOST.*['\"]\\([^'\"]*\\)['\"].*/\\1/p" | head -1)
    fi

    DB_NAME="${env_name:-$def_name}"
    DB_USER="${env_user:-$def_user}"
    DB_PASSWORD="${env_pass:-$def_pass}"
    DB_HOST="${env_host:-$def_host}"

    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_HOST" ]; then
        log_message "ERROR: Could not extract DB config from container env or wp-config.php"
        return 1
    fi

    log_message "Database (resolved): $DB_NAME on $DB_HOST (user=$DB_USER, source=$([ -n "$env_name" ] && echo "env" || echo "wp-config.php"))"
    return 0
}

# Function to validate that the WP container exists and is running, and copy
# wp-config.php to a temp path so the rest of the script can extract DB info
# uniformly from a file.
prepare_container_direct_mode() {
    local container="$1"
    local docroot="$2"
    local tmp_wp_config="$3"

    log_message "Preparing container-direct mode for container: $container"
    log_message "Document root inside container: $docroot"

    # Verify container exists
    if ! docker inspect "$container" >/dev/null 2>&1; then
        log_message "ERROR: Container '$container' does not exist"
        return 1
    fi

    # Verify container is running
    local state=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)
    if [ "$state" != "true" ]; then
        log_message "ERROR: Container '$container' is not running"
        return 1
    fi

    # Verify docroot contains wp-config.php
    if ! docker exec "$container" test -f "$docroot/wp-config.php" 2>/dev/null; then
        log_message "ERROR: wp-config.php not found at $docroot/wp-config.php inside container '$container'"
        return 1
    fi

    # Pull wp-config.php out so we can reuse extract_db_config() unchanged
    if ! docker cp "$container:$docroot/wp-config.php" "$tmp_wp_config" 2>/dev/null; then
        log_message "ERROR: Failed to copy wp-config.php out of container '$container'"
        return 1
    fi

    log_message "Container-direct mode prepared successfully"
    return 0
}

# Function to find the database container that pairs with the WordPress
# container. Strategy:
#   1) Look for docker-compose.yml near the WP container and match service
#      names referenced by DB_HOST (e.g. "db") to a running container with
#      a mysql/mariadb image.
#   2) If DB_HOST is a DNS service name, look up docker network aliases.
#   3) Fallback: scan all running mysql/mariadb containers and pick the one
#      sharing at least one docker network with the WP container.
#
# IMPORTANT: This function is called via $(...) so its stdout is captured
# as the container name. Therefore ALL log output must go to stderr (>&2).
find_db_container_for_wp() {
    local wp_container="$1"
    local db_host="$2"

    log_message "Resolving database container for '$wp_container' (DB_HOST='$db_host')..." >&2

    # Normalize "host:port" or "host"
    local db_service="${db_host%%:*}"

    # Try to find docker-compose.yml near the WP container by inspecting its
    # labels (compose sets label com.docker.compose.project.config_files).
    local compose_file=""
    local config_files=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$wp_container" 2>/dev/null || true)
    if [ -n "$config_files" ] && [ "$config_files" != "<no value>" ]; then
        # Take the first path in the (possibly comma-separated) list
        compose_file="${config_files%%,*}"
        if [ -f "$compose_file" ]; then
            log_message "Found compose file via container labels: $compose_file" >&2
        else
            compose_file=""
        fi
    fi

    # Strategy 1: match by service name in compose file
    if [ -n "$compose_file" ]; then
        # Find a service block whose name matches db_service OR whose
        # container_name is set to db_service
        local matched_container=""
        local current_service=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_-]+):[[:space:]]*$ ]]; then
                current_service="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ container_name:[[:space:]]*([^[:space:]]+) ]]; then
                local cn="${BASH_REMATCH[1]}"
                if [ "$cn" = "$db_service" ] || [ "$cn" = "${PROJECT_NAME:-}_${db_service}" ] || [ "$cn" = "${PROJECT_NAME:-}-${db_service}" ]; then
                    matched_container="$cn"
                fi
            fi
            if [ "$current_service" = "$db_service" ] && [ -z "$matched_container" ]; then
                # Try to find a running container whose name starts with
                # the project prefix + service name
                local project=$(basename "$(dirname "$compose_file")")
                local candidate="${project}-${db_service}"
                if docker inspect "$candidate" >/dev/null 2>&1; then
                    matched_container="$candidate"
                fi
            fi
        done < "$compose_file"

        if [ -n "$matched_container" ] && docker ps --format '{{.Names}}' | grep -qx "$matched_container"; then
            echo "$matched_container"
            return 0
        fi
    fi

    # Strategy 2: a container literally named db_service (DB_HOST value)
    if docker ps --format '{{.Names}}' | grep -qx "$db_service"; then
        local candidate_state=$(docker inspect -f '{{.State.Running}}' "$db_service" 2>/dev/null)
        if [ "$candidate_state" = "true" ]; then
            echo "$db_service"
            return 0
        fi
    fi

    # Strategy 3: scan all running mysql/mariadb containers and pick the one
    # sharing a network with the WP container
    local wp_networks=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$wp_container" 2>/dev/null)
    local candidates=$(docker ps --format '{{.Names}}\t{{.Image}}' | awk '$2 ~ /mysql|mariadb/ {print $1}')

    for cand in $candidates; do
        local cand_networks=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$cand" 2>/dev/null)
        for net in $wp_networks; do
            if [[ " $cand_networks " == *" $net "* ]]; then
                log_message "Picked DB container '$cand' via shared network '$net'" >&2
                echo "$cand"
                return 0
            fi
        done
    done

    return 1
}

# Pull WordPress files out of the container into a temp directory using
# 'docker cp'. Used in container-direct mode.
#
# Note: wp-config.php is already in $temp_dir/files/ from
# prepare_container_direct_mode(); we skip re-copying it so the archive
# structure matches the host-path mode (which produces files/wp-config.php).
backup_files_from_container() {
    local container="$1"
    local docroot="$2"
    local temp_dir="$3"

    if [ "$LIGHTWEIGHT" = true ]; then
        log_message "Creating lightweight backup from container (wp-content, .htaccess)..."
        log_message "(wp-config.php was already pulled in prepare step)"

        # Copy wp-content
        if docker exec "$container" test -d "$docroot/wp-content" >/dev/null 2>&1; then
            if docker cp "$container:$docroot/wp-content" "$temp_dir/files/" 2>/dev/null; then
                log_message "wp-content pulled from container"
            else
                log_message "ERROR: Failed to docker cp wp-content"
                return 1
            fi
        else
            log_message "WARNING: wp-content not found at $docroot/wp-content in container"
        fi

        # Copy .htaccess if present (wp-config.php already pulled in prepare step)
        if docker exec "$container" test -f "$docroot/.htaccess" >/dev/null 2>&1; then
            if docker cp "$container:$docroot/.htaccess" "$temp_dir/files/" 2>/dev/null; then
                log_message ".htaccess pulled from container"
            else
                log_message "WARNING: Failed to docker cp .htaccess (non-critical)"
            fi
        fi

        # Marker file so restore script knows this is lightweight
        echo "lightweight" > "$temp_dir/files/.backup_mode"
        local files_size
        files_size=$(_dir_size "$temp_dir/files")
        log_message "Lightweight backup size: $files_size"
        return 0
    else
        log_message "Creating full files backup from container..."
        # docker cp requires a trailing /. to copy directory contents into
        # $temp_dir/files/. We exclude wp-config.php from the bulk copy and
        # restore it from the prepare step's file so we don't end up with
        # two copies in the final archive with different mtimes.
        if docker cp "$container:$docroot/." "$temp_dir/files/" 2>/dev/null; then
            # Re-pull wp-config.php from container to ensure it is exactly
            # what prepare step pulled (and to overwrite whatever bulk copy
            # put there, since the bulk copy may differ in metadata).
            if ! docker cp "$container:$docroot/wp-config.php" "$temp_dir/files/wp-config.php" 2>/dev/null; then
                log_message "WARNING: Failed to refresh wp-config.php from container"
            fi
            log_message "WordPress files pulled from container successfully"
            local files_size
            files_size=$(_dir_size "$temp_dir/files")
            log_message "WordPress files size: $files_size"
            return 0
        else
            log_message "ERROR: Failed to docker cp WordPress files from container"
            return 1
        fi
    fi
}

# Function to create database backup (Docker)
backup_database_docker() {
    local output_file="$1"

    log_message "Creating database backup using Docker..."

    # Check if container is running
    if ! container_is_running "$DB_CONTAINER"; then
        log_message "ERROR: Database container '$DB_CONTAINER' is not running"
        log_message "Please start your Docker containers first"
        return 1
    fi

    # MySQL 8 needs --no-tablespaces for non-root users (PROCESS privilege).
    # Safe for MariaDB as well — ignored if the server doesn't recognize it.
    local docker_dump_cmd="docker exec $DB_CONTAINER $(db_dump_client_binary) -u$DB_USER $(db_password_arg "$DB_PASSWORD") --single-transaction --routines --triggers --no-tablespaces $DB_NAME"

    _execute_db_dump "$docker_dump_cmd" "$output_file" "Docker" "Please check database credentials and container status"
}

# Function to create database backup (Native)
backup_database_native() {
    local output_file="$1"

    log_message "Creating database backup using native $DB_TYPE..."

    local dump_cmd="$(db_dump_client_binary) -h$DB_HOST -u$DB_USER $(db_password_arg "$DB_PASSWORD") --single-transaction --routines --triggers --no-tablespaces $DB_NAME"

    _execute_db_dump "$dump_cmd" "$output_file" "native $DB_TYPE" "Please check database credentials and service availability"
}

# Function to create files backup
backup_files() {
    local wordpress_dir="$1"
    local temp_dir="$2"
    
    if [ "$LIGHTWEIGHT" = true ]; then
        log_message "Creating lightweight files backup (wp-content, wp-config.php, .htaccess)..."
        
        # Copy wp-content directory
        if [ -d "$wordpress_dir/wp-content" ]; then
            if cp -r "$wordpress_dir/wp-content" "$temp_dir/files/" 2>/dev/null; then
                log_message "wp-content directory copied successfully"
            else
                log_message "ERROR: Failed to copy wp-content directory"
                return 1
            fi
        else
            log_message "WARNING: wp-content directory not found"
        fi
        
        # Copy wp-config.php (critical for DB credentials)
        if [ -f "$wordpress_dir/wp-config.php" ]; then
            if cp "$wordpress_dir/wp-config.php" "$temp_dir/files/" 2>/dev/null; then
                log_message "wp-config.php copied successfully"
            else
                log_message "ERROR: Failed to copy wp-config.php"
                return 1
            fi
        else
            log_message "ERROR: wp-config.php not found"
            return 1
        fi
        
        # Copy .htaccess if exists (Apache/OLS rewrite rules)
        if [ -f "$wordpress_dir/.htaccess" ]; then
            if cp "$wordpress_dir/.htaccess" "$temp_dir/files/" 2>/dev/null; then
                log_message ".htaccess copied successfully"
            else
                log_message "WARNING: Failed to copy .htaccess (non-critical)"
            fi
        fi
        
        # Create a marker file so restore script knows this is lightweight
        echo "lightweight" > "$temp_dir/files/.backup_mode"

        # Calculate files backup size
        local files_size
        files_size=$(_dir_size "$temp_dir/files")
        log_message "Lightweight backup size: $files_size"
        return 0
    else
        log_message "Creating full files backup..."

        # Copy entire WordPress directory
        if cp -r "$wordpress_dir" "$temp_dir/files/" 2>/dev/null; then
            log_message "WordPress files copied successfully"

            # Calculate files backup size
            local files_size
            files_size=$(_dir_size "$temp_dir/files")
            log_message "WordPress files size: $files_size"
            return 0
        else
            log_message "ERROR: Failed to copy WordPress files"
            return 1
        fi
    fi
}

# Parse command line arguments
while getopts "w:c:d:o:le:h" opt; do
    case $opt in
        w)
            WORDPRESS_DIR="$OPTARG"
            ;;
        c)
            WP_CONTAINER="$OPTARG"
            ;;
        d)
            WP_CONTAINER_DOCROOT="$OPTARG"
            ;;
        o)
            OUTPUT_DIR="$OPTARG"
            ;;
        l)
            LIGHTWEIGHT=true
            ;;
        e)
            EMAIL_TO="$OPTARG"
            ;;
        h)
            SHOW_HELP=true
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            show_help
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
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

# Validate required parameters
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

# Validate WordPress directory (host mode only)
if [ -n "$WORDPRESS_DIR" ]; then
    if [ ! -d "$WORDPRESS_DIR" ]; then
        log_message "ERROR: WordPress directory does not exist: $WORDPRESS_DIR"
        exit 1
    fi

    if [ ! -f "$WORDPRESS_DIR/wp-config.php" ]; then
        log_message "ERROR: wp-config.php not found. Is this a valid WordPress installation?"
        exit 1
    fi

    # Convert to absolute path
    WORDPRESS_DIR=$(cd "$WORDPRESS_DIR" && pwd)
fi

# Validate output directory
if [ ! -d "$OUTPUT_DIR" ]; then
    log_message "Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to create output directory: $OUTPUT_DIR"
        exit 1
    fi
fi

# Convert to absolute path
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

# Create temporary directory used for both database.sql and files/.
# In container-direct mode we also pull wp-config.php into TEMP_DIR/files/
# early so we can reuse extract_db_config() unchanged.
TEMP_DIR=$(mktemp -d)
mkdir -p "$TEMP_DIR/files"

# Container-direct mode (-c) preparation:
# We need to read wp-config.php from inside the running WP container, and we
# also need a "filesystem view" of WordPress so the rest of the script can
# reuse its host-style functions (extract_db_config, etc.) on the pulled
# wp-config.php.
CONTAINER_DIRECT=false

if [ -n "$WP_CONTAINER" ]; then
    CONTAINER_DIRECT=true
    IS_DOCKER=true  # Always Docker when -c is used

    if ! prepare_container_direct_mode "$WP_CONTAINER" "$WP_CONTAINER_DOCROOT" "$TEMP_DIR/files/wp-config.php"; then
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # Redirect extract_db_config to read from the pulled wp-config.php
    WORDPRESS_DIR="$TEMP_DIR/files"
fi

# Detect environment (Docker or Native). In container-direct mode we skip
# auto-detection because we already know the WP container and don't need a
# host-side docker-compose.yml scan.
if [ "$CONTAINER_DIRECT" = false ]; then
    detect_docker_environment
fi

# Detect database configuration based on environment
if [ "$IS_DOCKER" = true ]; then
    if [ "$CONTAINER_DIRECT" = true ]; then
        # Container-direct: resolve DB config from container env vars first
        # (official WordPress image exposes WORDPRESS_DB_* env), then fall
        # back to parsing getenv_docker() defaults in wp-config.php.
        if ! extract_db_config_from_container "$WP_CONTAINER" "$WP_CONTAINER_DOCROOT" "$TEMP_DIR/files"; then
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # Now resolve the DB container from DB_HOST (e.g. "db:3306" -> "db")
        DB_TYPE="mysql"
        DB_CONTAINER=$(find_db_container_for_wp "$WP_CONTAINER" "$DB_HOST")
        if [ -z "$DB_CONTAINER" ]; then
            log_message "ERROR: Could not resolve database container for '$WP_CONTAINER' (DB_HOST='$DB_HOST')"
            log_message "Hint: ensure the DB container is running and shares a docker network with the WordPress container"
            rm -rf "$TEMP_DIR"
            exit 1
        fi

        # Refine DB_TYPE by inspecting the resolved container image
        local_db_image=$(docker inspect -f '{{.Config.Image}}' "$DB_CONTAINER" 2>/dev/null || true)
        case "$local_db_image" in
            *mariadb*) DB_TYPE="mariadb" ;;
            *mysql*)   DB_TYPE="mysql" ;;
        esac
        log_message "Database container: $DB_CONTAINER (image=$local_db_image, type=$DB_TYPE)"
    else
        if ! detect_docker_database_info; then
            log_message "ERROR: Failed to detect Docker database configuration"
            rm -rf "$TEMP_DIR"
            exit 1
        fi
    fi
else
    if ! detect_native_database_service; then
        log_message "WARNING: Database service auto-detection may not be accurate"
    fi
fi

# Check dependencies
check_dependencies

# Generate timestamp and backup filename
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
if [ "$CONTAINER_DIRECT" = true ]; then
    WORDPRESS_FOLDER_NAME="$WP_CONTAINER"
else
    WORDPRESS_FOLDER_NAME=$(basename "$WORDPRESS_DIR")
fi
if [ "$LIGHTWEIGHT" = true ]; then
    BACKUP_FILENAME="${TIMESTAMP}_${WORDPRESS_FOLDER_NAME}_lightweight.zip"
else
    BACKUP_FILENAME="${TIMESTAMP}_${WORDPRESS_FOLDER_NAME}.zip"
fi
BACKUP_PATH="$OUTPUT_DIR/$BACKUP_FILENAME"

log_message "Starting WordPress Backup process"
if [ "$CONTAINER_DIRECT" = true ]; then
    log_message "WordPress container: $WP_CONTAINER (docroot: $WP_CONTAINER_DOCROOT)"
    log_message "Files will be pulled via 'docker cp'"
else
    log_message "WordPress directory: $WORDPRESS_DIR"
fi
log_message "Output directory: $OUTPUT_DIR"
log_message "Backup filename: $BACKUP_FILENAME"
log_message "Backup mode: $([ "$LIGHTWEIGHT" = true ] && echo "Lightweight (wp-content + wp-config.php + .htaccess)" || echo "Full (entire WordPress directory)")"
log_message "Environment: $([ "$IS_DOCKER" = true ] && echo "Docker" || echo "Native")"
log_message "Database type: $DB_TYPE"
if [ -n "$EMAIL_TO" ]; then
    log_message "Email notification: $EMAIL_TO"
fi

# Initialize log file for email report
init_log_file
log_message "Log file initialized: $LOG_FILE"

# TEMP_DIR is created earlier so we can pull wp-config.php into it during
# container-direct setup. Skip recreating it here.

# Cleanup function (also sends email notification if configured)
cleanup() {
    local exit_code=$?

    # Send email notification based on exit code
    if [ -n "$EMAIL_TO" ] && [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        if [ $exit_code -eq 0 ]; then
            send_email_notification "SUCCESS" "$exit_code"
        else
            send_email_notification "FAILED" "$exit_code"
        fi
    fi

    log_message "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
    rm -f "$LOG_FILE"
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Extract database configuration. In container-direct mode, the DB config
# was already extracted via extract_db_config_from_container() earlier.
if [ "$CONTAINER_DIRECT" = false ]; then
    if ! extract_db_config "$WORDPRESS_DIR"; then
        log_message "ERROR: Failed to extract database configuration"
        exit 1
    fi
fi

# Create database backup based on environment
DB_BACKUP_FILE="$TEMP_DIR/database.sql"
if [ "$IS_DOCKER" = true ]; then
    if ! backup_database_docker "$DB_BACKUP_FILE"; then
        log_message "ERROR: Docker database backup failed"
        exit 1
    fi
else
    if ! backup_database_native "$DB_BACKUP_FILE"; then
        log_message "ERROR: Native database backup failed"
        exit 1
    fi
fi

# Create files backup
# In container-direct mode, files are pulled via 'docker cp' from the
# WordPress container. In host mode, files are copied from WORDPRESS_DIR.
if [ "$CONTAINER_DIRECT" = true ]; then
    if ! backup_files_from_container "$WP_CONTAINER" "$WP_CONTAINER_DOCROOT" "$TEMP_DIR"; then
        log_message "ERROR: Container files backup failed"
        exit 1
    fi
else
    if ! backup_files "$WORDPRESS_DIR" "$TEMP_DIR"; then
        log_message "ERROR: Files backup failed"
        exit 1
    fi
fi

# Write a small .dbinfo sidecar at the root of the archive. This captures
# the *resolved* database configuration (after getenv_docker() / env
# expansion), so wp_restore.sh can read DB credentials without re-parsing
# wp-config.php (which may use env-based helpers and produce wrong values
# like "wordpress" instead of the real database name).
cat > "$TEMP_DIR/.dbinfo" <<EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_HOST=${DB_HOST}
DB_TYPE=${DB_TYPE}
DB_CONTAINER=${DB_CONTAINER:-}
BACKUP_MODE=$([ "$LIGHTWEIGHT" = true ] && echo "lightweight" || echo "full")
SOURCE=$([ "$CONTAINER_DIRECT" = true ] && echo "container-direct" || echo "host")
WP_CONTAINER=${WP_CONTAINER:-}
WP_CONTAINER_DOCROOT=${WP_CONTAINER_DOCROOT:-}
EOF
log_message "Wrote resolved DB info to .dbinfo"

# Create final zip archive
log_message "Creating final backup archive..."
cd "$TEMP_DIR"

# Check if the backup path is valid
if [ ! -d "$(dirname "$BACKUP_PATH")" ]; then
    log_message "ERROR: Backup directory does not exist: $(dirname "$BACKUP_PATH")"
    exit 1
fi

# Create zip archive with better error handling.
# -X strips "extra attributes" (UID, GID, timestamps) from the archive so
# the backup is portable across hosts/machines with different users — you
# can restore on a fresh box without worrying about the original owner.
zip_output=$(zip -rX "$BACKUP_PATH" . 2>&1)
if [ $? -eq 0 ]; then
    log_message "Backup completed successfully!"
    log_message "Backup file: $BACKUP_PATH"

    # Display backup size
    BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
    log_message "Total backup size: $BACKUP_SIZE"
else
    log_message "ERROR: Failed to create backup archive"
    log_message "Zip error: $zip_output"
    exit 1
fi

# Verify backup integrity
log_message "Verifying backup integrity..."
if zip -T "$BACKUP_PATH" >/dev/null 2>&1; then
    log_message "Backup integrity verified successfully"
else
    log_message "WARNING: Backup integrity verification failed"
fi

log_message "WordPress Backup process completed"
log_message "Environment: $([ "$IS_DOCKER" = true ] && echo "Docker ($DB_CONTAINER container)" || echo "Native ($DB_TYPE service)")"
exit 0
