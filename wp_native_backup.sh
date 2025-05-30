#!/bin/bash

# WordPress Backup Script
# Creates a backup of WordPress files and database
# Usage: ./wordpress_backup.sh -w /path/to/wordpress -o /path/to/backup/output
# MariaDB Database

# Default values
WORDPRESS_DIR=""
OUTPUT_DIR="$(pwd)"
DB_SERVICE=""
SHOW_HELP=false

# Function to display help
show_help() {
    echo "WordPress Backup Script"
    echo "======================="
    echo ""
    echo "Usage: $0 -w WORDPRESS_DIR [-o OUTPUT_DIR] [-d DATABASE_SERVICE]"
    echo ""
    echo "Options:"
    echo "  -w WORDPRESS_DIR     Path to the WordPress installation directory (required)"
    echo "  -o OUTPUT_DIR        Path to the backup output directory (optional, default: current directory)"
    echo "  -d DATABASE_SERVICE  Database service type: mariadb or mysql (optional, auto-detected if not specified)"
    echo "  -h                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -w /var/www/html/wordpress"
    echo "  $0 -w /var/www/html/wordpress -o /backups"
    echo "  $0 -w /var/www/html/wordpress -d mariadb -o /backups"
    echo "  $0 -w /home/user/website -d mysql -o /home/user/backups"
    echo ""
    echo "Output format: [timestamp]_[wordpressfoldername].zip"
    echo "Example: 20250530_143022_wordpress.zip"
    echo ""
    echo "Note: Script will attempt to auto-detect database service if -d is not specified."
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
    
    # Check for database dump tools based on detected/specified service
    if [ "$DB_SERVICE" = "mariadb" ]; then
        if ! command -v mariadb-dump &> /dev/null; then
            missing_tools+=("mariadb-dump")
        fi
    else
        if ! command -v mysqldump &> /dev/null; then
            missing_tools+=("mysqldump")
        fi
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_message "ERROR: Missing required tools: ${missing_tools[*]}"
        log_message "Please install the missing tools and try again."
        exit 1
    fi
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

# Function to create database backup
backup_database() {
    local output_file="$1"
    
    log_message "Creating database backup using $DB_SERVICE..."
    
    # Create database dump command based on service type
    local dump_cmd=""
    if [ "$DB_SERVICE" = "mariadb" ]; then
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
        log_message "ERROR: Failed to create database backup using $DB_SERVICE"
        log_message "Please check database credentials and service availability"
        return 1
    fi
}

# Function to create files backup
backup_files() {
    local wordpress_dir="$1"
    local temp_dir="$2"
    local zip_file="$3"
    
    log_message "Creating files backup..."
    
    # Copy WordPress files to temporary directory
    cp -r "$wordpress_dir" "$temp_dir/files/" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to copy WordPress files"
        return 1
    fi
    
    log_message "WordPress files copied successfully"
    return 0
}

# Function to detect database service type
detect_database_service() {
    log_message "Attempting to auto-detect database service..."
    
    # Method 1: Check running processes
    if pgrep -f "mariadb\|mysqld.*mariadb" > /dev/null; then
        DB_SERVICE="mariadb"
        log_message "Detected MariaDB from running processes"
        return 0
    elif pgrep -f "mysqld" > /dev/null; then
        DB_SERVICE="mysql"
        log_message "Detected MySQL from running processes"
        return 0
    fi
    
    # Method 2: Check installed packages (Debian/Ubuntu)
    if command -v dpkg &> /dev/null; then
        if dpkg -l | grep -q "mariadb-server\|mariadb-client"; then
            DB_SERVICE="mariadb"
            log_message "Detected MariaDB from installed packages"
            return 0
        elif dpkg -l | grep -q "mysql-server\|mysql-client"; then
            DB_SERVICE="mysql"
            log_message "Detected MySQL from installed packages"
            return 0
        fi
    fi
    
    # Method 3: Check for MariaDB-specific command
    if command -v mariadb &> /dev/null || command -v mariadb-dump &> /dev/null; then
        DB_SERVICE="mariadb"
        log_message "Detected MariaDB from available commands"
        return 0
    fi
    
    # Method 4: Try connecting and check version
    if command -v mysql &> /dev/null; then
        local version_output=$(mysql --version 2>/dev/null)
        if echo "$version_output" | grep -qi "mariadb"; then
            DB_SERVICE="mariadb"
            log_message "Detected MariaDB from version output"
            return 0
        else
            DB_SERVICE="mysql"
            log_message "Detected MySQL from version output"
            return 0
        fi
    fi
    
    # Default fallback
    log_message "Could not auto-detect database service, defaulting to MySQL"
    DB_SERVICE="mysql"
    return 1
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
            DB_SERVICE="$OPTARG"
            if [ "$DB_SERVICE" != "mariadb" ] && [ "$DB_SERVICE" != "mysql" ]; then
                echo "ERROR: Invalid database service '$DB_SERVICE'. Must be 'mariadb' or 'mysql'" >&2
                show_help
                exit 1
            fi
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

# Validate output directory
if [ ! -d "$OUTPUT_DIR" ]; then
    log_message "Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to create output directory: $OUTPUT_DIR"
        exit 1
    fi
fi

# Detect database service if not specified
if [ -z "$DB_SERVICE" ]; then
    detect_database_service
fi

# Check dependencies
check_dependencies

# Generate timestamp and backup filename
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
WORDPRESS_FOLDER_NAME=$(basename "$WORDPRESS_DIR")
BACKUP_FILENAME="${TIMESTAMP}_${WORDPRESS_FOLDER_NAME}.zip"
BACKUP_PATH="$OUTPUT_DIR/$BACKUP_FILENAME"

log_message "Starting WordPress backup process"
log_message "WordPress directory: $WORDPRESS_DIR"
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

# Extract database configuration
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
if ! backup_files "$WORDPRESS_DIR" "$TEMP_DIR" "$BACKUP_PATH"; then
    log_message "ERROR: Files backup failed"
    exit 1
fi

# Create final zip archive
log_message "Creating final backup archive..."
cd "$TEMP_DIR"
if zip -r "$BACKUP_PATH" . >/dev/null 2>&1; then
    log_message "Backup completed successfully!"
    log_message "Backup file: $BACKUP_PATH"
    
    # Display backup size
    BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
    log_message "Backup size: $BACKUP_SIZE"
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

log_message "WordPress backup process completed"
