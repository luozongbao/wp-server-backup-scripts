#!/bin/bash

# WordPress Universal Backup Script
# Creates a backup of WordPress files and database
# Auto-detects Docker or native database services
# Usage: ./wp-universal-backup.sh -w /path/to/wordpress [-o /path/to/backup/output] [-h]

# Default values
WORDPRESS_DIR=""
OUTPUT_DIR="$(pwd)"
SHOW_HELP=false
DB_TYPE=""
DB_CONTAINER=""
DB_DUMP_CMD=""
IS_DOCKER=false

# Function to display help
show_help() {
    echo "WordPress Universal Backup Script"
    echo "================================"
    echo ""
    echo "Usage: $0 -w WORDPRESS_DIR [-o OUTPUT_DIR] [-h]"
    echo ""
    echo "Options:"
    echo "  -w WORDPRESS_DIR     Path to the WordPress installation directory (required)"
    echo "  -o OUTPUT_DIR        Path to the backup output directory (optional, default: current directory)"
    echo "  -h                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -w /var/www/html/wordpress"
    echo "  $0 -w /var/www/html/wordpress -o /backups"
    echo "  $0 -w /home/user/website -o /home/user/backups"
    echo ""
    echo "Output format: [timestamp]_[wordpress-folder-name].zip"
    echo "Example: 20250530_143022_wordpress.zip"
    echo ""
    echo "Features:"
    echo "  - Auto-detects Docker containers or native database services"
    echo "  - Supports both MySQL and MariaDB"
    echo "  - Creates compressed backup with files and database"
    echo "  - Verifies backup integrity"
}

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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
        if [ "$DB_TYPE" = "mariadb" ]; then
            if ! command -v mariadb-dump &> /dev/null; then
                missing_tools+=("mariadb-dump")
            fi
        else
            if ! command -v mysqldump &> /dev/null; then
                missing_tools+=("mysqldump")
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

# Function to create database backup (Docker)
backup_database_docker() {
    local output_file="$1"
    
    log_message "Creating database backup using Docker..."
    
    # Check if container is running
    if ! docker ps --format "table {{.Names}}" | grep -q "^${DB_CONTAINER}$"; then
        log_message "ERROR: Database container '$DB_CONTAINER' is not running"
        log_message "Please start your Docker containers first"
        return 1
    fi
    
    # Create database dump command for Docker
    local docker_dump_cmd=""
    
    if [ "$DB_TYPE" = "mariadb" ]; then
        docker_dump_cmd="docker exec $DB_CONTAINER mariadb-dump -u$DB_USER"
    else
        docker_dump_cmd="docker exec $DB_CONTAINER mysqldump -u$DB_USER"
    fi
    
    if [ -n "$DB_PASSWORD" ]; then
        docker_dump_cmd="$docker_dump_cmd -p$DB_PASSWORD"
    fi
    
    docker_dump_cmd="$docker_dump_cmd --single-transaction --routines --triggers $DB_NAME"
    
    # Execute database dump
    if eval "$docker_dump_cmd" > "$output_file" 2>/dev/null; then
        log_message "Database backup created successfully: $output_file"
        
        # Check if backup file has content
        if [ -s "$output_file" ]; then
            local backup_size=$(du -h "$output_file" | cut -f1)
            log_message "Database backup size: $backup_size"
            return 0
        else
            log_message "ERROR: Database backup file is empty"
            return 1
        fi
    else
        log_message "ERROR: Failed to create database backup using Docker"
        log_message "Please check database credentials and container status"
        return 1
    fi
}

# Function to create database backup (Native)
backup_database_native() {
    local output_file="$1"
    
    log_message "Creating database backup using native $DB_TYPE..."
    
    # Create database dump command based on service type
    local dump_cmd=""
    if [ "$DB_TYPE" = "mariadb" ]; then
        dump_cmd="mariadb-dump -h$DB_HOST -u$DB_USER"
    else
        dump_cmd="mysqldump -h$DB_HOST -u$DB_USER"
    fi
    
    if [ -n "$DB_PASSWORD" ]; then
        dump_cmd="$dump_cmd -p$DB_PASSWORD"
    fi
    
    dump_cmd="$dump_cmd --single-transaction --routines --triggers $DB_NAME"
    
    # Execute database dump
    if eval "$dump_cmd" > "$output_file" 2>/dev/null; then
        log_message "Database backup created successfully: $output_file"
        
        # Check if backup file has content
        if [ -s "$output_file" ]; then
            local backup_size=$(du -h "$output_file" | cut -f1)
            log_message "Database backup size: $backup_size"
            return 0
        else
            log_message "ERROR: Database backup file is empty"
            return 1
        fi
    else
        log_message "ERROR: Failed to create database backup using native $DB_TYPE"
        log_message "Please check database credentials and service availability"
        return 1
    fi
}

# Function to create files backup
backup_files() {
    local wordpress_dir="$1"
    local temp_dir="$2"
    
    log_message "Creating files backup..."
    
    # Copy WordPress files to temporary directory
    if cp -r "$wordpress_dir" "$temp_dir/files/" 2>/dev/null; then
        log_message "WordPress files copied successfully"
        
        # Calculate files backup size
        local files_size=$(du -sh "$temp_dir/files" | cut -f1)
        log_message "WordPress files size: $files_size"
        return 0
    else
        log_message "ERROR: Failed to copy WordPress files"
        return 1
    fi
}

# Parse command line arguments
while getopts "w:o:h" opt; do
    case $opt in
        w)
            WORDPRESS_DIR="$OPTARG"
            ;;
        o)
            OUTPUT_DIR="$OPTARG"
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
if [ -z "$WORDPRESS_DIR" ]; then
    echo "ERROR: Missing required parameter -w (WordPress directory)"
    echo ""
    show_help
    exit 1
fi

# Validate WordPress directory
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

# Generate timestamp and backup filename
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
WORDPRESS_FOLDER_NAME=$(basename "$WORDPRESS_DIR")
BACKUP_FILENAME="${TIMESTAMP}_${WORDPRESS_FOLDER_NAME}.zip"
BACKUP_PATH="$OUTPUT_DIR/$BACKUP_FILENAME"

log_message "Starting WordPress Universal Backup process"
log_message "WordPress directory: $WORDPRESS_DIR"
log_message "Output directory: $OUTPUT_DIR"
log_message "Backup filename: $BACKUP_FILENAME"
log_message "Environment: $([ "$IS_DOCKER" = true ] && echo "Docker" || echo "Native")"
log_message "Database type: $DB_TYPE"

# Create temporary directory
TEMP_DIR=$(mktemp -d)
mkdir -p "$TEMP_DIR/files"

# Cleanup function
cleanup() {
    log_message "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Extract database configuration
if ! extract_db_config "$WORDPRESS_DIR"; then
    log_message "ERROR: Failed to extract database configuration"
    exit 1
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
if ! backup_files "$WORDPRESS_DIR" "$TEMP_DIR"; then
    log_message "ERROR: Files backup failed"
    exit 1
fi

# Create final zip archive
log_message "Creating final backup archive..."
cd "$TEMP_DIR"

# Check if the backup path is valid
if [ ! -d "$(dirname "$BACKUP_PATH")" ]; then
    log_message "ERROR: Backup directory does not exist: $(dirname "$BACKUP_PATH")"
    exit 1
fi

# Create zip archive with better error handling
zip_output=$(zip -r "$BACKUP_PATH" . 2>&1)
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

log_message "WordPress Universal Backup process completed"
log_message "Environment: $([ "$IS_DOCKER" = true ] && echo "Docker ($DB_CONTAINER container)" || echo "Native ($DB_TYPE service)")"
