#!/bin/bash

# WordPress Universal Recovery Script
# Restores WordPress files and database from backup created by wp_universal_backup.sh
# Auto-detects Docker or native database services
# Usage: ./wp_universal_recover.sh -b /path/to/backup.zip -w /path/to/wordpress

# Default values
BACKUP_FILE=""
WORDPRESS_DIR=""
SHOW_HELP=false
DB_TYPE=""
DB_CONTAINER=""
IS_DOCKER=false

# Function to display help
show_help() {
    echo "WordPress Universal Recovery Script"
    echo "=================================="
    echo ""
    echo "Usage: $0 -b BACKUP_FILE -w WORDPRESS_DIR [-h]"
    echo ""
    echo "Options:"
    echo "  -b BACKUP_FILE       Path to the backup ZIP file (required)"
    echo "  -w WORDPRESS_DIR     Path to the WordPress installation directory (required)"
    echo "  -h                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress"
    echo "  $0 -b /backups/backup.zip -w /home/user/website"
    echo ""
    echo "Features:"
    echo "  - Auto-detects Docker containers or native database services"
    echo "  - Supports both MySQL and MariaDB"
    echo "  - Restores both WordPress files and database from backup"
    echo "  - Handles environment-specific restoration methods"
    echo ""
    echo "Note: This script will restore both WordPress files and database from the backup."
    echo "      Existing files and database content will be replaced!"
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
    
    return 0
}

# Function to extract database configuration from backup wp-config.php
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

# Function to restore WordPress files
restore_files() {
    local backup_wp_dir="$1"
    local target_dir="$2"
    
    log_message "Restoring WordPress files..."
    
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
        # Backup existing directory
        local backup_existing="$target_dir.backup.$(date +%Y%m%d_%H%M%S)"
        log_message "Creating backup of existing directory: $backup_existing"
        if ! mv "$target_dir" "$backup_existing"; then
            log_message "ERROR: Failed to backup existing directory"
            return 1
        fi
        mkdir -p "$target_dir"
    fi
    
    # Copy WordPress files from backup
    if cp -r "$backup_wp_dir"/* "$target_dir"/; then
        log_message "WordPress files restored successfully"
        
        # Calculate restored files size
        local files_size=$(du -sh "$target_dir" | cut -f1)
        log_message "Restored WordPress files size: $files_size"
        return 0
    else
        log_message "ERROR: Failed to restore WordPress files"
        return 1
    fi
}

# Parse command line arguments
while getopts "b:w:h" opt; do
    case $opt in
        b)
            BACKUP_FILE="$OPTARG"
            ;;
        w)
            WORDPRESS_DIR="$OPTARG"
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
if [ -z "$BACKUP_FILE" ]; then
    echo "ERROR: Missing required parameter -b (backup file)"
    echo ""
    show_help
    exit 1
fi

if [ -z "$WORDPRESS_DIR" ]; then
    echo "ERROR: Missing required parameter -w (WordPress directory)"
    echo ""
    show_help
    exit 1
fi

# Validate backup file
if [ ! -f "$BACKUP_FILE" ]; then
    log_message "ERROR: Backup file does not exist: $BACKUP_FILE"
    exit 1
fi

# Check if backup file is a valid ZIP
if ! unzip -t "$BACKUP_FILE" >/dev/null 2>&1; then
    log_message "ERROR: Invalid or corrupted backup file: $BACKUP_FILE"
    exit 1
fi

# Convert to absolute paths
BACKUP_FILE=$(realpath "$BACKUP_FILE")
WORDPRESS_DIR=$(realpath "$WORDPRESS_DIR")

# Detect environment (Docker or Native)
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

# Check dependencies
check_dependencies

log_message "Starting WordPress Universal Recovery process"
log_message "Backup file: $BACKUP_FILE"
log_message "WordPress directory: $WORDPRESS_DIR"
log_message "Environment: $([ "$IS_DOCKER" = true ] && echo "Docker" || echo "Native")"
log_message "Database type: $DB_TYPE"

# Create temporary directory
TEMP_DIR=$(mktemp -d)

# Cleanup function
cleanup() {
    log_message "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}

# Set trap to cleanup on exit
trap cleanup EXIT

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

# Restore database based on environment
SQL_FILE="$TEMP_DIR/database.sql"
if [ "$IS_DOCKER" = true ]; then
    if ! restore_database_docker "$SQL_FILE"; then
        log_message "ERROR: Docker database restoration failed"
        exit 1
    fi
else
    if ! restore_database_native "$SQL_FILE"; then
        log_message "ERROR: Native database restoration failed"
        exit 1
    fi
fi

# Restore WordPress files
if ! restore_files "$BACKUP_WP_DIR" "$WORDPRESS_DIR"; then
    log_message "ERROR: Files restoration failed"
    exit 1
fi

log_message "WordPress Universal Recovery completed successfully!"
log_message "WordPress files restored to: $WORDPRESS_DIR"
log_message "Database '$DB_NAME' restored successfully"
log_message "Environment: $([ "$IS_DOCKER" = true ] && echo "Docker ($DB_CONTAINER container)" || echo "Native ($DB_TYPE service)")"
log_message ""
log_message "IMPORTANT: Please verify your WordPress installation and update file permissions if needed."
if [ "$IS_DOCKER" = true ]; then
    log_message "           You may need to restart your Docker containers to apply changes."
fi