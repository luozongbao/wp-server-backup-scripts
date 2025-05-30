#!/bin/bash

# WordPress Docker Backup Script
# Creates a backup of WordPress files and database running in Docker containers
# Usage: ./wp-docker-backup.sh -w /path/to/wordpress [-o /path/to/backup/output] [-d /path/to/docker-compose]

# Default values
WORDPRESS_DIR=""
OUTPUT_DIR="$(pwd)"
DOCKER_COMPOSE_DIR=""
SHOW_HELP=false

# Function to display help
show_help() {
    echo "WordPress Docker Backup Script"
    echo "=============================="
    echo ""
    echo "Usage: $0 -w WORDPRESS_DIR [-o OUTPUT_DIR] [-d DOCKER_COMPOSE_DIR]"
    echo ""
    echo "Options:"
    echo "  -w WORDPRESS_DIR       Path to the WordPress installation directory (required)"
    echo "  -o OUTPUT_DIR          Path to the backup output directory (optional, default: current directory)"
    echo "  -d DOCKER_COMPOSE_DIR  Path to the docker-compose.yml directory (optional, default: same as WordPress directory)"
    echo "  -h                     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -w /var/www/html/wordpress"
    echo "  $0 -w /var/www/html/wordpress -o /backups"
    echo "  $0 -w /var/www/html/wordpress -d /docker/wordpress -o /backups"
    echo ""
    echo "Output format: [timestamp]_[wordpress-folder-name].zip"
    echo "Example: 20250530_143022_wordpress.zip"
    echo ""
    echo "Note: This script detects MariaDB/MySQL from docker-compose.yml and uses appropriate dump commands."
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
    
    if ! command -v docker &> /dev/null; then
        missing_tools+=("docker")
    fi
    
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        missing_tools+=("docker-compose")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_message "ERROR: Missing required tools: ${missing_tools[*]}"
        log_message "Please install the missing tools and try again."
        exit 1
    fi
}

# Function to detect database type and container from docker-compose.yml
detect_database_info() {
    local compose_file="$1/docker-compose.yml"
    
    if [ ! -f "$compose_file" ]; then
        log_message "ERROR: docker-compose.yml not found in $1"
        return 1
    fi
    
    log_message "Analyzing docker-compose.yml for database configuration..."
    
    # Detect database type and container name
    if grep -qi "mariadb" "$compose_file"; then
        DB_TYPE="mariadb"
        DB_DUMP_CMD="mariadb-dump"
        log_message "Detected database type: MariaDB"
    elif grep -qi "mysql" "$compose_file"; then
        DB_TYPE="mysql"
        DB_DUMP_CMD="mysqldump"
        log_message "Detected database type: MySQL"
    else
        log_message "ERROR: Could not detect database type (MariaDB/MySQL) in docker-compose.yml"
        return 1
    fi
    
    # Find database container name
    DB_CONTAINER=$(grep -A 10 -B 5 "$DB_TYPE" "$compose_file" | grep -E "container_name:|service:" | head -1 | sed 's/.*container_name:\s*\|.*:\s*//' | tr -d '"' | tr -d "'")
    
    if [ -z "$DB_CONTAINER" ]; then
        # Try to find service name if container_name is not specified
        DB_CONTAINER=$(grep -B 5 -A 10 "$DB_TYPE" "$compose_file" | grep -E "^\s*[a-zA-Z0-9_-]+:" | head -1 | sed 's/:\s*$//' | sed 's/^\s*//')
        if [ -z "$DB_CONTAINER" ]; then
            log_message "ERROR: Could not determine database container name"
            return 1
        fi
    fi
    
    log_message "Database container: $DB_CONTAINER"
    return 0
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
    
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
        log_message "ERROR: Could not extract database configuration from wp-config.php"
        return 1
    fi
    
    log_message "Database configuration extracted successfully"
    log_message "Database: $DB_NAME"
    log_message "User: $DB_USER"
    log_message "Host: $DB_HOST"
    return 0
}

# Function to create database backup using Docker
backup_database() {
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
        log_message "ERROR: Failed to create database backup"
        log_message "Please check database credentials and container status"
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
while getopts "w:o:d:h" opt; do
    case $opt in
        w)
            WORDPRESS_DIR="$OPTARG"
            ;;
        o)
            OUTPUT_DIR="$OPTARG"
            ;;
        d)
            DOCKER_COMPOSE_DIR="$OPTARG"
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

# Set default docker-compose directory if not specified
if [ -z "$DOCKER_COMPOSE_DIR" ]; then
    DOCKER_COMPOSE_DIR="$WORDPRESS_DIR"
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

# Validate docker-compose directory
if [ ! -d "$DOCKER_COMPOSE_DIR" ]; then
    log_message "ERROR: Docker-compose directory does not exist: $DOCKER_COMPOSE_DIR"
    exit 1
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

# Convert OUTPUT_DIR to absolute path
if [[ ! "$OUTPUT_DIR" = /* ]]; then
    OUTPUT_DIR="$(pwd)/$OUTPUT_DIR"
fi

# Check dependencies
check_dependencies

# Generate timestamp and backup filename
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
WORDPRESS_FOLDER_NAME=$(basename "$WORDPRESS_DIR")
BACKUP_FILENAME="${TIMESTAMP}_${WORDPRESS_FOLDER_NAME}.zip"
BACKUP_PATH="$OUTPUT_DIR/$BACKUP_FILENAME"

log_message "Starting WordPress Docker backup process"
log_message "WordPress directory: $WORDPRESS_DIR"
log_message "Docker-compose directory: $DOCKER_COMPOSE_DIR"
log_message "Output directory: $OUTPUT_DIR"
log_message "Backup filename: $BACKUP_FILENAME"

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

# Detect database information from docker-compose.yml
if ! detect_database_info "$DOCKER_COMPOSE_DIR"; then
    log_message "ERROR: Failed to detect database information"
    exit 1
fi

# Extract database configuration from wp-config.php
if ! extract_db_config "$WORDPRESS_DIR"; then
    log_message "ERROR: Failed to extract database configuration"
    exit 1
fi

# Create database backup
DB_BACKUP_FILE="$TEMP_DIR/database.sql"
if ! backup_database "$DB_BACKUP_FILE"; then
    log_message "ERROR: Database backup failed"
    exit 1
fi

# Create files backup
if ! backup_files "$WORDPRESS_DIR" "$TEMP_DIR"; then
    log_message "ERROR: Files backup failed"
    exit 1
fi

# Create a backup info file
INFO_FILE="$TEMP_DIR/backup_info.txt"
cat > "$INFO_FILE" << EOF
WordPress Docker Backup Information
===================================

Backup Date: $(date)
WordPress Directory: $WORDPRESS_DIR
Docker-compose Directory: $DOCKER_COMPOSE_DIR
Database Type: $DB_TYPE
Database Container: $DB_CONTAINER
Database Name: $DB_NAME
Database User: $DB_USER
Database Host: $DB_HOST

Backup Contents:
- files/: Complete WordPress file structure
- database.sql: Database dump
- backup_info.txt: This information file
EOF

log_message "Backup information file created"

# Create final zip archive
log_message "Creating final backup archive..."
log_message "Temporary directory: $TEMP_DIR"
log_message "Backup path: $BACKUP_PATH"

cd "$TEMP_DIR"
log_message "Changed to temporary directory: $(pwd)"
log_message "Contents of temp directory:"
ls -la
log_message "Running zip command: zip -r \"$BACKUP_PATH\" ."
if zip -r "$BACKUP_PATH" .; then
    log_message "Backup completed successfully!"
    log_message "Backup file: $BACKUP_PATH"
    
    # Display backup size
    BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
    log_message "Total backup size: $BACKUP_SIZE"
else
    log_message "ERROR: Failed to create backup archive"
    exit 1
fi

# Verify backup integrity
log_message "Verifying backup integrity..."
if zip -T "$BACKUP_PATH" >/dev/null 2>&1; then
    log_message "Backup integrity verified successfully"
else
    log_message "WARNING: Backup integrity verification failed"
fi

log_message "WordPress Docker backup process completed successfully"
log_message "Backup location: $BACKUP_PATH"
