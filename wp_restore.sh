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

# Function to restore database (Docker)
restore_database_docker() {
    local sql_file="$1"
    
    log_message "Restoring database using Docker..."
    
    # Check if container is running
    if ! docker ps --format "table {{.Names}}" | grep -q "^${DB_CONTAINER}$"; then
        log_message "ERROR: Database container '$DB_CONTAINER' is not running"
        log_message "Please start your Docker containers first: docker-compose up -d"
        return 1
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
    
    # Execute database restore
    if eval "$docker_restore_cmd" < "$sql_file" 2>/dev/null; then
        log_message "Database restored successfully using Docker"
        return 0
    else
        log_message "ERROR: Failed to restore database using Docker"
        log_message "Please check database credentials and container status"
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
    
    # Execute database restore
    if eval "$restore_cmd" < "$sql_file" 2>/dev/null; then
        log_message "Database restored successfully using native $DB_TYPE"
        return 0
    else
        log_message "ERROR: Failed to restore database using native $DB_TYPE"
        log_message "Please check database credentials and service availability"
        return 1
    fi
}

# Function to detect old URL from backup's wp_options
detect_old_url() {
    local wp_config_path="$1"

    # Try to extract siteurl from the SQL file in the backup
    if [ -f "$TEMP_DIR/database.sql" ]; then
        local detected_url
        detected_url=$(grep -oE "siteurl.*'https?://[^']+'" "$TEMP_DIR/database.sql" 2>/dev/null | head -1 | grep -oE "https?://[^']+")
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
    # 'trap ... RETURN' fires when this function returns, no matter how
    # (success, error, or early-return). Guarantees the temp file is cleaned
    # up even if a command between this point and the return fails.
    trap "rm -f '$query_file'" RETURN
    # Write query to file with no shell expansion (printf preserves $ literally)
    printf '%s\n' "$query" > "$query_file"
    # Pipe into the command; db_cmd ends with the DB name (no -e flag)
    $db_cmd < "$query_file" 2>/dev/null
    local rc=$?
    return $rc
}

# Function to capture output of a SQL query (for SELECT statements)
run_db_query_capture() {
    local query="$1"
    local db_cmd
    db_cmd=$(build_db_query_cmd)
    local query_file
    query_file=$(mktemp)
    # trap RETURN ensures cleanup on any exit path from this function
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
                if docker exec "$container" test -d "$docroot/wp-content" >/dev/null 2>&1; then
                    local ts=$(date +%Y%m%d_%H%M%S)
                    log_message "Backing up existing wp-content inside container to wp-content.backup.$ts"
                    docker exec "$container" sh -c "mv '$docroot/wp-content' '$docroot/wp-content.backup.$ts'" 2>/dev/null || true
                    RESTORE_SAFETY_BACKUPS+=("docker://${container}:${docroot}/wp-content.backup.$ts")
                fi
                # docker cp expects a directory; source ends without / for directories
                if docker cp "$backup_wp_dir/wp-content" "$container:$docroot/" 2>/dev/null; then
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
                if docker exec "$container" test -f "$docroot/wp-config.php" >/dev/null 2>&1; then
                    local ts=$(date +%Y%m%d_%H%M%S)
                    log_message "Backing up existing wp-config.php inside container to wp-config.php.backup.$ts"
                    docker exec "$container" sh -c "mv '$docroot/wp-config.php' '$docroot/wp-config.php.backup.$ts'" 2>/dev/null || true
                    RESTORE_SAFETY_BACKUPS+=("docker://${container}:${docroot}/wp-config.php.backup.$ts")
                fi
                if docker cp "$backup_wp_dir/wp-config.php" "$container:$docroot/" 2>/dev/null; then
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
                if docker exec "$container" test -f "$docroot/.htaccess" >/dev/null 2>&1; then
                    local ts=$(date +%Y%m%d_%H%M%S)
                    log_message "Backing up existing .htaccess inside container to .htaccess.backup.$ts"
                    docker exec "$container" sh -c "mv '$docroot/.htaccess' '$docroot/.htaccess.backup.$ts'" 2>/dev/null || true
                    RESTORE_SAFETY_BACKUPS+=("docker://${container}:${docroot}/.htaccess.backup.$ts")
                fi
                if docker cp "$backup_wp_dir/.htaccess" "$container:$docroot/" 2>/dev/null; then
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
        if docker exec "$container" test -d "$docroot" >/dev/null 2>&1; then
            local ts=$(date +%Y%m%d_%H%M%S)
            log_message "Backing up existing docroot inside container to $docroot.backup.$ts"
            docker exec "$container" sh -c "mv '$docroot' '$docroot.backup.$ts'" 2>/dev/null || true
            RESTORE_SAFETY_BACKUPS+=("docker://${container}:${docroot}.backup.$ts")
            # Recreate empty docroot
            docker exec "$container" mkdir -p "$docroot" 2>/dev/null
        else
            docker exec "$container" mkdir -p "$docroot" 2>/dev/null
        fi

        # Push everything. docker cp requires src/. for directory contents.
        if docker cp "$backup_wp_dir"/. "$container:$docroot/" 2>/dev/null; then
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
            if [ -d "$target_dir/wp-content" ]; then
                local wp_content_backup="$target_dir/wp-content.backup.$(date +%Y%m%d_%H%M%S)"
                log_message "Backing up existing wp-content to: $wp_content_backup"
                if mv "$target_dir/wp-content" "$wp_content_backup"; then
                    RESTORE_SAFETY_BACKUPS+=("$wp_content_backup")
                else
                    log_message "ERROR: Failed to backup existing wp-content"
                    return 1
                fi
            fi

            if cp -r "$backup_wp_dir/wp-content" "$target_dir/"; then
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
            if [ -f "$target_dir/wp-config.php" ]; then
                local wp_config_backup="$target_dir/wp-config.php.backup.$(date +%Y%m%d_%H%M%S)"
                log_message "Backing up existing wp-config.php to: $wp_config_backup"
                if mv "$target_dir/wp-config.php" "$wp_config_backup"; then
                    RESTORE_SAFETY_BACKUPS+=("$wp_config_backup")
                else
                    log_message "ERROR: Failed to backup existing wp-config.php"
                    return 1
                fi
            fi

            if cp "$backup_wp_dir/wp-config.php" "$target_dir/"; then
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
            if [ -f "$target_dir/.htaccess" ]; then
                local htaccess_backup="$target_dir/.htaccess.backup.$(date +%Y%m%d_%H%M%S)"
                log_message "Backing up existing .htaccess to: $htaccess_backup"
                if mv "$target_dir/.htaccess" "$htaccess_backup"; then
                    RESTORE_SAFETY_BACKUPS+=("$htaccess_backup")
                else
                    log_message "ERROR: Failed to backup existing .htaccess"
                    return 1
                fi
            fi

            if cp "$backup_wp_dir/.htaccess" "$target_dir/"; then
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
            # Backup existing directory — tracked for cleanup on success
            local backup_existing="$target_dir.backup.$(date +%Y%m%d_%H%M%S)"
            log_message "Creating backup of existing directory: $backup_existing"
            if ! mv "$target_dir" "$backup_existing"; then
                log_message "ERROR: Failed to backup existing directory"
                return 1
            fi
            RESTORE_SAFETY_BACKUPS+=("$backup_existing")
            mkdir -p "$target_dir"
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
# Allow long options: --skip-files, --skip-db, --dry-run, --fix-mode
ARGS=$(getopt -o "b:w:c:d:u:U:t:A:P:E:fh" -l "skip-files,skip-db,dry-run,fix-mode" -- "$@" 2>/dev/null)
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

    # Detect database configuration based on environment
    if [ "$IS_DOCKER" = true ]; then
        if ! detect_docker_database_info; then
            log_message "ERROR: Failed to detect Docker database configuration"
            exit 1
        fi
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
            rm -rf "$b" 2>/dev/null || log_message "  WARNING: Failed to remove $b"
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
fi

# Validate conflicting flags (restore mode only — fix mode flags already warned above)
if [ "$FIX_MODE" != true ] && [ "$SKIP_FILES" = true ] && [ "$SKIP_DB" = true ]; then
    log_message "ERROR: --skip-files and --skip-db cannot be used together"
    exit 1
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

# RESTORE-ONLY: database restoration (skip in fix mode)
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
