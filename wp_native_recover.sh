#!/bin/bash

# WordPress Native Recovery Script
# Restores WordPress files and database from backup created by wp_native_backup.sh
# Usage: ./wp_native_recover.sh -b /path/to/backup.zip -w /path/to/wordpress [-d DATABASE_SERVICE]

# Default values
BACKUP_FILE=""
WORDPRESS_DIR=""
DB_SERVICE=""
SHOW_HELP=false

# Function to display help
show_help() {
    echo "WordPress Native Recovery Script"
    echo "==============================="
    echo ""
    echo "Usage: $0 -b BACKUP_FILE -w WORDPRESS_DIR [-d DATABASE_SERVICE]"
    echo ""
    echo "Options:"
    echo "  -b BACKUP_FILE       Path to the backup ZIP file (required)"
    echo "  -w WORDPRESS_DIR     Path to the WordPress installation directory (required)"
    echo "  -d DATABASE_SERVICE  Database service type: mariadb or mysql (optional, auto-detected if not specified)"
    echo "  -h                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress"
    echo "  $0 -b /backups/backup.zip -w /var/www/html/wordpress -d mariadb"
    echo ""
    echo "Note: This script will restore both WordPress files and database from the backup."
    echo "      Existing files and database content will be replaced!"
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
    
    # Check for database restore tools based on detected/specified service
    if [ "$DB_SERVICE" = "mariadb" ]; then
        if ! command -v mariadb &> /dev/null; then
            missing_tools+=("mariadb")
        fi
    else
        if ! command -v mysql &> /dev/null; then
            missing_tools+=("mysql")
        fi
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_message "ERROR: Missing required tools: ${missing_tools[*]}"
        log_message "Please install the missing tools and try again."
        exit 1
    fi
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
    if command -v mariadb &> /dev/null; then
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

# Function to restore database
restore_database() {
    local sql_file="$1"
    
    log_message "Restoring database using $DB_SERVICE..."
    
    # Check if SQL file exists and has content
    if [ ! -s "$sql_file" ]; then
        log_message "ERROR: Database backup file is empty or does not exist"
        return 1
    fi
    
    # Create database restore command based on service type
    local restore_cmd=""
    if [ "$DB_SERVICE" = "mariadb" ]; then
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
        log_message "Database restored successfully"
        return 0
    else
        log_message "ERROR: Failed to restore database using $DB_SERVICE"
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
while getopts "b:w:d:h" opt; do
    case $opt in
        b)
            BACKUP_FILE="$OPTARG"
            ;;
        w)
            WORDPRESS_DIR="$OPTARG"
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

# Detect database service if not specified
if [ -z "$DB_SERVICE" ]; then
    detect_database_service
fi

# Check dependencies
check_dependencies

log_message "Starting WordPress native recovery process"
log_message "Backup file: $BACKUP_FILE"
log_message "WordPress directory: $WORDPRESS_DIR"
log_message "Database service: $DB_SERVICE"

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

# Restore database
SQL_FILE="$TEMP_DIR/database.sql"
if ! restore_database "$SQL_FILE"; then
    log_message "ERROR: Database restoration failed"
    exit 1
fi

# Restore WordPress files
if ! restore_files "$BACKUP_WP_DIR" "$WORDPRESS_DIR"; then
    log_message "ERROR: Files restoration failed"
    exit 1
fi

log_message "WordPress native recovery completed successfully!"
log_message "WordPress files restored to: $WORDPRESS_DIR"
log_message "Database '$DB_NAME' restored successfully"
log_message ""
log_message "IMPORTANT: Please verify your WordPress installation and update file permissions if needed."