# WordPress Server Backup Scripts

A collection of robust bash scripts for backing up WordPress installations in different environments. These scripts create comprehensive backups including both WordPress files and database dumps, with automatic environment detection and error handling.

## Scripts Overview

### Backup Scripts
| Script | Purpose | Environment |
|--------|---------|-------------|
| `wp_native_backup.sh` | Backup WordPress on native/bare metal servers | Native MySQL/MariaDB |
| `wp_docker_backup.sh` | Backup WordPress running in Docker containers | Docker with MySQL/MariaDB |
| `wp_universal_backup.sh` | Universal backup script with auto-detection | Both Native and Docker |

### Recovery Scripts
| Script | Purpose | Environment |
|--------|---------|-------------|
| `wp_native_recover.sh` | Restore WordPress on native/bare metal servers | Native MySQL/MariaDB |
| `wp_docker_recover.sh` | Restore WordPress running in Docker containers | Docker with MySQL/MariaDB |
| `wp_universal_recover.sh` | Universal recovery script with auto-detection | Both Native and Docker |

## Features

✅ **Complete Backups**: Files + Database in a single ZIP archive  
✅ **Complete Recovery**: Restore files + Database from backup archives  
✅ **Auto-Detection**: Database service type (MySQL/MariaDB) and environment detection  
✅ **Docker Support**: Full Docker container integration  
✅ **Error Handling**: Comprehensive validation and error reporting  
✅ **Integrity Verification**: Backup file verification after creation  
✅ **Timestamped Backups**: Format: `YYYYMMDD_HHMMSS_foldername.zip`  
✅ **Detailed Logging**: Timestamped log messages throughout the process  
✅ **Safe Recovery**: Existing files are backed up before restoration  

## Quick Start

### Universal Scripts (Recommended)
```bash
# Auto-detects environment and database type
# Backup
./wp_universal_backup.sh -w /var/www/html/wordpress -o /backups
# Recovery
./wp_universal_recover.sh -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress
```

### Native Environment
```bash
# For traditional LAMP stack installations
# Backup
./wp_native_backup.sh -w /var/www/html/wordpress -o /backups
# Recovery  
./wp_native_recover.sh -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress
```

### Docker Environment
```bash
# For WordPress running in Docker containers
# Backup
./wp_docker_backup.sh -w /var/www/html/wordpress -o /backups
# Recovery
./wp_docker_recover.sh -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress
```

## Detailed Usage

### 1. wp_native_backup.sh

**Purpose**: Backup WordPress installations running on native/bare metal servers with MySQL or MariaDB.

**Usage**:
```bash
./wp_native_backup.sh -w WORDPRESS_DIR [-o OUTPUT_DIR] [-d DATABASE_SERVICE]
```

**Options**:
- `-w WORDPRESS_DIR`: Path to WordPress installation (required)
- `-o OUTPUT_DIR`: Backup output directory (optional, default: current directory)
- `-d DATABASE_SERVICE`: Database type - `mysql` or `mariadb` (optional, auto-detected)
- `-h`: Show help message

**Examples**:
```bash
# Basic backup
./wp_native_backup.sh -w /var/www/html/wordpress

# Specify output directory
./wp_native_backup.sh -w /var/www/html/wordpress -o /backups

# Force MariaDB usage
./wp_native_backup.sh -w /var/www/html/wordpress -d mariadb -o /backups
```

**Requirements**:
- `zip` command
- `mysqldump` or `mariadb-dump` (based on database type)
- Access to WordPress directory and database

### 2. wp-docker-backup.sh

**Purpose**: Backup WordPress installations running in Docker containers.

**Usage**:
```bash
./wp-docker-backup.sh -w WORDPRESS_DIR [-o OUTPUT_DIR] [-d DOCKER_COMPOSE_DIR]
```

**Options**:
- `-w WORDPRESS_DIR`: Path to WordPress installation (required)
- `-o OUTPUT_DIR`: Backup output directory (optional, default: current directory)
- `-d DOCKER_COMPOSE_DIR`: Path to docker-compose.yml directory (optional, default: same as WordPress directory)
- `-h`: Show help message

**Examples**:
```bash
# Basic Docker backup
./wp-docker-backup.sh -w /var/www/html/wordpress

# Specify docker-compose location
./wp-docker-backup.sh -w /var/www/html/wordpress -d /docker/wordpress -o /backups
```

**Requirements**:
- `zip` command
- `docker` command
- `docker-compose` command
- Running Docker containers
- Access to docker-compose.yml file

**Features**:
- Auto-detects database type from docker-compose.yml
- Creates additional backup_info.txt with environment details
- Validates container status before backup

### 3. wp-universal-backup.sh (Recommended)

**Purpose**: Universal backup script that automatically detects whether WordPress is running in Docker or native environment.

**Usage**:
```bash
./wp-universal-backup.sh -w WORDPRESS_DIR [-o OUTPUT_DIR]
```

**Options**:
- `-w WORDPRESS_DIR`: Path to WordPress installation (required)
- `-o OUTPUT_DIR`: Backup output directory (optional, default: current directory)
- `-h`: Show help message

**Examples**:
```bash
# Universal backup (auto-detection)
./wp-universal-backup.sh -w /var/www/html/wordpress

# With custom output directory
./wp-universal-backup.sh -w /var/www/html/wordpress -o /backups
```

**Auto-Detection Logic**:
1. **Docker Detection**: Searches for docker-compose.yml in WordPress directory and parent directories
2. **Database Detection**: Analyzes docker-compose.yml or system processes to identify MySQL/MariaDB
3. **Container Detection**: Identifies database container names automatically
4. **Fallback**: Uses native database services if Docker is not detected

## Backup Contents

Each backup creates a ZIP file containing:

```
backup_YYYYMMDD_HHMMSS_sitename.zip
├── files/
│   └── [complete WordPress directory structure]
├── database.sql
└── backup_info.txt (Docker backups only)
```

## Configuration Requirements

### WordPress Configuration
- Valid `wp-config.php` file with database credentials
- Readable WordPress directory structure

### Database Access
**Native Environment**:
- MySQL/MariaDB server running
- Valid database credentials in wp-config.php
- Database user with appropriate permissions

**Docker Environment**:
- Docker containers running
- Accessible docker-compose.yml file
- Database container accessible via Docker exec

## Error Handling

The scripts include comprehensive error handling for:

- ❌ Missing required tools (zip, docker, mysqldump, etc.)
- ❌ Invalid WordPress directory or missing wp-config.php
- ❌ Database connection failures
- ❌ Container accessibility issues
- ❌ Insufficient permissions
- ❌ Backup integrity verification failures

## Permissions

Ensure all scripts have execute permissions:
```bash
chmod +x wp_native_backup.sh wp_docker_backup.sh wp_universal_backup.sh
chmod +x wp_native_recover.sh wp_docker_recover.sh wp_universal_recover.sh
```

## Security Considerations

- Database passwords are temporarily visible in process lists during backup
- Ensure backup directories have appropriate access restrictions
- Consider encryption for backup files containing sensitive data
- Store backup files in secure locations

## Troubleshooting

### Common Issues

**"Database backup file is empty"**:
- Check database credentials in wp-config.php
- Verify database service is running
- Ensure database user has appropriate permissions

**"Container not running" (Docker)**:
- Start Docker containers: `docker-compose up -d`
- Verify container names match docker-compose.yml

**"Permission denied"**:
- Check file/directory permissions
- Run with appropriate user privileges
- Ensure script has execute permissions

### Debug Mode
Add `set -x` at the beginning of any script for detailed execution tracing.

## Recovery Scripts Usage

### 1. wp_native_recover.sh

**Purpose**: Restore WordPress installations from backups on native/bare metal servers with MySQL or MariaDB.

**Usage**:
```bash
./wp_native_recover.sh -b BACKUP_FILE -w WORDPRESS_DIR [-d DATABASE_SERVICE]
```

**Options**:
- `-b BACKUP_FILE`: Path to the backup ZIP file (required)
- `-w WORDPRESS_DIR`: Path to WordPress installation directory (required)
- `-d DATABASE_SERVICE`: Database type - `mysql` or `mariadb` (optional, auto-detected)
- `-h`: Show help message

**Examples**:
```bash
# Basic recovery
./wp_native_recover.sh -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress

# Force MariaDB usage
./wp_native_recover.sh -b /backups/backup.zip -w /var/www/html/wordpress -d mariadb
```

**Requirements**:
- `unzip` command
- `mysql` or `mariadb` client (based on database type)
- Access to WordPress directory and database
- Database must exist and be accessible

### 2. wp_docker_recover.sh

**Purpose**: Restore WordPress installations from backups in Docker containers.

**Usage**:
```bash
./wp_docker_recover.sh -b BACKUP_FILE -w WORDPRESS_DIR [-d DOCKER_COMPOSE_DIR]
```

**Options**:
- `-b BACKUP_FILE`: Path to the backup ZIP file (required)
- `-w WORDPRESS_DIR`: Path to WordPress installation directory (required)
- `-d DOCKER_COMPOSE_DIR`: Path to docker-compose.yml directory (optional, default: same as WordPress directory)
- `-h`: Show help message

**Examples**:
```bash
# Basic Docker recovery
./wp_docker_recover.sh -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress

# Specify docker-compose location
./wp_docker_recover.sh -b /backups/backup.zip -w /var/www/html/wordpress -d /docker/wordpress
```

**Requirements**:
- `unzip` command
- `docker` command
- `docker-compose` command
- Running Docker containers
- Access to docker-compose.yml file

**Features**:
- Auto-detects database type from docker-compose.yml
- Reads backup_info.txt with environment details
- Validates container status before restoration

### 3. wp_universal_recover.sh (Recommended)

**Purpose**: Universal recovery script that automatically detects whether WordPress is running in Docker or native environment.

**Usage**:
```bash
./wp_universal_recover.sh -b BACKUP_FILE -w WORDPRESS_DIR
```

**Options**:
- `-b BACKUP_FILE`: Path to the backup ZIP file (required)
- `-w WORDPRESS_DIR`: Path to WordPress installation directory (required)
- `-h`: Show help message

**Examples**:
```bash
# Universal recovery (auto-detection)
./wp_universal_recover.sh -b /backups/20250530_143022_wordpress.zip -w /var/www/html/wordpress
```

**Auto-Detection Logic**:
1. **Docker Detection**: Searches for docker-compose.yml in WordPress directory and parent directories
2. **Database Detection**: Analyzes docker-compose.yml or system processes to identify MySQL/MariaDB
3. **Container Detection**: Identifies database container names automatically
4. **Fallback**: Uses native database services if Docker is not detected

## Recovery Process

All recovery scripts follow this process:

1. **Validation**: Verify backup file integrity and structure
2. **Extraction**: Extract backup contents to temporary directory
3. **Configuration**: Read database settings from backup's wp-config.php
4. **Environment Detection**: Determine restoration method (Docker/Native)
5. **Database Restoration**: Restore database using appropriate method
6. **File Restoration**: Copy WordPress files to target directory
7. **Verification**: Confirm successful restoration

### Important Recovery Notes

⚠️ **CAUTION**: Recovery scripts will replace existing WordPress files and database content!

- Existing WordPress directory will be backed up as `[directory].backup.[timestamp]`
- Database content will be completely replaced
- File permissions may need to be adjusted after recovery
- For Docker environments, containers must be running
- Test recovery in non-production environment first

## Output Format

Backup files follow the naming convention:
```
YYYYMMDD_HHMMSS_[wordpress-folder-name].zip
```

Example: `20250530_143022_wordpress.zip`

## Dependencies

### All Backup Scripts
- `zip` - For creating compressed archives
- `bash` - Shell environment (version 4.0+)

### All Recovery Scripts
- `unzip` - For extracting backup archives
- `bash` - Shell environment (version 4.0+)

### Native Scripts
- `mysqldump` or `mariadb-dump` - Database backup tools
- `mysql` or `mariadb` - Database restore tools

### Docker Scripts
- `docker` - Docker engine
- `docker-compose` - Container orchestration

### Universal Scripts
- Combination of above based on detected environment

---

## License

These scripts are provided as-is for educational and operational purposes. Test thoroughly in your environment before production use.