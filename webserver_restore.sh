#!/bin/bash

# Webserver Restore Script
# Restores webserver configuration from a backup created by webserver_backup.sh
# Supports Apache, OpenLiteSpeed, Nginx — both native and Docker
# Usage: ./webserver_restore.sh -b /path/to/backup.zip [-f /path/to/target] [-c CONTAINER] [-e EMAIL] [--force] [--dry-run] [-h]

# Default values
BACKUP_FILE=""
WEBSERVER_DIR=""        # Target path (-f): native host path, or in-container path when env=docker
WEBSERVER_CONTAINER=""  # Target container (-c); empty = use backup_info / auto-detect
SHOW_HELP=false
DRY_RUN=false
FORCE=false
EMAIL_TO=""
EMAIL_FROM="admin@companydomain.com"
IS_DOCKER=false
WEBSERVER_TYPE=""
DOCKER_COMPOSE_DIR=""
BACKUP_ENV=""
BACKUP_SOURCE=""
BACKUP_HOST=""
BACKUP_TIMESTAMP=""
declare -a RESTORE_SAFETY_BACKUPS=()

# Function to display help
show_help() {
    echo "Webserver Restore Script"
    echo "============================="
    echo ""
    echo "Usage: $0 -b BACKUP_FILE [options]"
    echo ""
    echo "Required Options:"
    echo "  -b BACKUP_FILE       Path to the webserver backup ZIP file (required)"
    echo ""
    echo "Target Options:"
    echo "  -f WEBSERVER_DIR     Target path (native host path, or in-container path when env=docker)."
    echo "                       If omitted, auto-detected from backup metadata or system."
    echo "  -c CONTAINER         Target Docker container (only used when env=docker)."
    echo "                       Defaults to the container recorded in the backup, or auto-detected."
    echo ""
    echo "Restore Behavior:"
    echo "  --force              Skip the safety backup of existing target config"
    echo "  --dry-run            Show what would be done without modifying anything"
    echo "  -e EMAIL             Send restore report to this email address (optional)"
    echo "  -h                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Restore to default native location (auto-detect from backup metadata)"
    echo "  $0 -b /backups/20250530_143022_nginx_config_backup.zip"
    echo ""
    echo "  # Restore to a specific native path"
    echo "  $0 -b /backups/20250530_143022_nginx_config_backup.zip -f /etc/nginx"
    echo ""
    echo "  # Restore to a Docker container"
    echo "  $0 -b /backups/20250530_143022_nginx_config_backup.zip -c my_nginx_container"
    echo ""
    echo "  # Restore to a specific in-container path"
    echo "  $0 -b /backups/20250530_143022_nginx_config_backup.zip -c my_nginx_container -f /etc/nginx"
    echo ""
    echo "  # Preview first"
    echo "  $0 -b /backups/20250530_143022_nginx_config_backup.zip --dry-run"
    echo ""
    echo "  # Force restore (skip safety backup of existing config)"
    echo "  $0 -b /backups/20250530_143022_nginx_config_backup.zip --force"
    echo ""
    echo "Note: Backward compatible with the legacy filename *_webserver_backup.zip —"
    echo "      the script reads .backup_info inside the archive, not the filename."
    echo ""
    echo "Features:"
    echo "  - Restores webserver configuration from a backup archive"
    echo "  - Supports native AND Docker targets (auto-detected from backup metadata)"
    echo "  - Safety-backs up existing target config to <target>.backup.<timestamp>"
    echo "  - Verifies integrity of the backup before restoring"
    echo "  - Verifies post-restore presence of key config files"
    echo "  - Attempts a graceful reload after restore (apache/nginx/openlitespeed)"
    echo ""
    echo "Note: Restoring webserver configuration overwrites the existing config."
    echo "      Existing config is renamed to <target>.backup.<timestamp> first, UNLESS --force is used."
}

# Function to log messages
log_message() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    if [ -n "$LOG_FILE" ]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

# Initialize log file (captures entire restore session)
init_log_file() {
    LOG_FILE=$(mktemp /tmp/webserver_restore_XXXXXX.log)
    : > "$LOG_FILE"
    export LOG_FILE
}

# Send restore report via email using msmtp
send_email_notification() {
    local status="$1"
    local exit_code="$2"

    if [ -z "$EMAIL_TO" ]; then
        log_message "Email notification skipped (no recipient specified)"
        return 0
    fi

    if ! command -v msmtp &> /dev/null; then
        log_message "WARNING: msmtp not installed, skipping email notification"
        return 1
    fi

    local subject_prefix="[Webserver Restore]"
    if [ "$status" = "SUCCESS" ]; then
        local subject="${subject_prefix} ✅ SUCCESS - ${WEBSERVER_TYPE:-unknown} (${BACKUP_TIMESTAMP:-N})"
    else
        local subject="${subject_prefix} ❌ FAILED - ${WEBSERVER_TYPE:-unknown} (${BACKUP_TIMESTAMP:-N})"
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
        echo "Webserver Restore Report"
        echo "==========================="
        echo ""
        echo "Status          : ${status}"
        echo "Exit code       : ${exit_code}"
        echo "Webserver type  : ${WEBSERVER_TYPE:-N/A}"
        echo "Backup file     : ${BACKUP_FILE}"
        echo "Backup source   : ${BACKUP_SOURCE:-N/A}"
        echo "Backup env      : ${BACKUP_ENV:-N/A}"
        echo "Backup host     : ${BACKUP_HOST:-N/A}"
        echo "Target path     : ${WEBSERVER_DIR:-N/A}"
        echo "Target container: ${WEBSERVER_CONTAINER:-N/A}"
        echo "Environment     : $([ "$IS_DOCKER" = true ] && echo "Docker ($WEBSERVER_CONTAINER)" || echo "Native")"
        echo "Dry-run         : ${DRY_RUN}"
        echo "Finished at     : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host            : $(hostname)"
        echo ""
        if [ -n "${PREFLIGHT_RESULTS:-}" ]; then
            echo "----- Preflight Checks -----"
            echo -e "$PREFLIGHT_RESULTS"
            echo ""
        fi
        echo "----- Restore Log -----"
        if [ -f "$LOG_FILE" ]; then
            cat "$LOG_FILE"
        else
            echo "(no log file found)"
        fi
    } | msmtp --account=default "$EMAIL_TO"

    if [ $? -eq 0 ]; then
        log_message "Restore report sent successfully to ${EMAIL_TO}"
    else
        log_message "WARNING: Failed to send restore report to ${EMAIL_TO}"
    fi
}

# Function to check required tools
check_dependencies() {
    local missing_tools=()

    if ! command -v unzip &> /dev/null; then
        missing_tools+=("unzip")
    fi

    if [ "$IS_DOCKER" = true ]; then
        if ! command -v docker &> /dev/null; then
            missing_tools+=("docker")
        fi
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_message "ERROR: Missing required tools: ${missing_tools[*]}"
        log_message "Please install the missing tools and try again."
        exit 1
    fi
}

# Parse a KEY=VALUE file (.backup_info) into shell vars
parse_backup_info() {
    local info_file="$1"
    [ -f "$info_file" ] || return 1

    while IFS='=' read -r key value; do
        # Skip comments and blank lines
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        case "$key" in
            webservver_type) WEBSERVER_TYPE="$value" ;;
            source_dir)      BACKUP_SOURCE="$value" ;;
            container)       [ -n "$value" ] && BACKUP_CONTAINER_FROM_INFO="$value" ;;
            environment)     BACKUP_ENV="$value" ;;
            timestamp)       BACKUP_TIMESTAMP="$value" ;;
            host)            BACKUP_HOST="$value" ;;
        esac
    done < "$info_file"
    return 0
}

# Determine the default in-container config path for the webserver type
default_in_container_path() {
    case "$1" in
        apache) echo "/etc/apache2" ;;
        openlitespeed) echo "/usr/local/lsws/conf" ;;
        nginx) echo "/etc/nginx" ;;
        *) echo "" ;;
    esac
}

# Determine the default native config dir for the webserver type
default_native_config_dir() {
    case "$1" in
        apache)
            if [ -d "/etc/apache2" ]; then echo "/etc/apache2"
            elif [ -d "/etc/httpd" ]; then echo "/etc/httpd"
            else echo ""
            fi ;;
        openlitespeed)
            if [ -d "/usr/local/lsws/conf" ]; then echo "/usr/local/lsws/conf"
            elif [ -d "/usr/local/litespeed/conf" ]; then echo "/usr/local/litespeed/conf"
            else echo ""
            fi ;;
        nginx)
            if [ -d "/etc/nginx" ]; then echo "/etc/nginx"
            else echo ""
            fi ;;
        *) echo "" ;;
    esac
}

# Find a webserver container by inspecting compose files near the recorded compose dir
detect_webserver_container() {
    local compose_dir="$1"
    local type="$2"

    local compose_file=""
    if [ -n "$compose_dir" ]; then
        if [ -f "$compose_dir/docker-compose.yml" ]; then
            compose_file="$compose_dir/docker-compose.yml"
        elif [ -f "$compose_dir/docker-compose.yaml" ]; then
            compose_file="$compose_dir/docker-compose.yaml"
        fi
    fi

    if [ -z "$compose_file" ]; then
        log_message "No docker-compose file at recorded location; scanning all containers..."
        # Last resort: scan running containers for known webserver images
        if command -v docker &> /dev/null; then
            local c
            c=$(docker ps --format "{{.Names}} {{.Image}}" 2>/dev/null \
                | grep -iE "apache|httpd|nginx|openlitespeed|ols|lsws|litespeed" \
                | head -1 | awk '{print $1}')
            echo "$c"
            return 0
        fi
        return 1
    fi

    log_message "Reading webserver container from $compose_file..."

    local service_name=""
    service_name=$(awk -v t="$type" '
        BEGIN { IGNORECASE=1 }
        /^[A-Za-z0-9_.-]+:[[:space:]]*$/ {
            current=$1; sub(/:$/, "", current); in_service=0
        }
        /^[A-Za-z0-9_.-]+:/ {
            line=$0
            if (line ~ /^[^ ]/) in_service=1
        }
        in_service && /image:/ {
            img=$2
            if (img ~ t) { print current; exit }
        }
    ' "$compose_file" 2>/dev/null)

    if [ -z "$service_name" ]; then
        service_name=$(grep -B1 -iE "image:.*(apache|httpd|nginx|openlitespeed|ols|lsws|litespeed)" "$compose_file" \
            | grep -oE "^  [A-Za-z0-9_.-]+:" | head -1 | sed 's/^  //; s/:$//')
    fi

    [ -z "$service_name" ] && return 1

    local container_line=$(grep -A 20 "^[[:space:]]*${service_name}:[[:space:]]*$" "$compose_file" \
        | grep -E "container_name:" | head -1)
    if [ -n "$container_line" ]; then
        echo "$container_line" | sed 's/.*container_name:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs
        return 0
    fi

    if command -v docker &> /dev/null; then
        local c
        c=$(docker compose -f "$compose_file" ps -q "$service_name" 2>/dev/null \
            | xargs -I {} docker ps --format "{{.Names}}" --filter "id={}" 2>/dev/null | head -1)
        if [ -n "$c" ]; then
            echo "$c"
            return 0
        fi
    fi

    echo "$service_name"
    return 0
}

# Move/rename an existing target dir out of the way so we can drop a new one in.
# Adds the resulting path to RESTORE_SAFETY_BACKUPS so cleanup can remove it on SUCCESS.
safety_backup_target() {
    local target="$1"
    local kind="$2"   # "host" or "container"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')

    if [ "$kind" = "host" ]; then
        if [ -d "$target" ]; then
            local backup_path="${target}.backup.${ts}"
            if [ "$DRY_RUN" = true ]; then
                log_message "[DRY-RUN] Would rename $target -> $backup_path"
                return 0
            fi
            if mv "$target" "$backup_path"; then
                log_message "Existing config preserved at: $backup_path"
                RESTORE_SAFETY_BACKUPS+=("$backup_path")
                return 0
            else
                log_message "ERROR: Failed to move existing $target"
                return 1
            fi
        fi
        # No existing target — nothing to do
        return 0
    fi

    # Container kind: do `docker exec mv` if path exists in the container
    local container="$3"
    local backup_path="${target}.backup.${ts}"
    if docker exec "$container" test -e "$target"; then
        if [ "$DRY_RUN" = true ]; then
            log_message "[DRY-RUN] Would rename $container:$target -> $backup_path"
            return 0
        fi
        if docker exec "$container" sh -c "mv '$target' '$backup_path'"; then
            log_message "Existing config preserved in container at: $backup_path"
            RESTORE_SAFETY_BACKUPS+=("container:${container}:${backup_path}")
            return 0
        else
            log_message "ERROR: Failed to move existing config in container"
            return 1
        fi
    fi
    return 0
}

# Map a webserver type to the process names that indicate it's running on the host
_webservver_process_names() {
    case "$1" in
        apache) echo "apache2 httpd" ;;
        openlitespeed) echo "lshttpd openlitespeed litespeed" ;;
        nginx) echo "nginx" ;;
        *) echo "" ;;
    esac
}

# Map a webserver type to image substrings used to detect docker container image
_webservver_image_patterns() {
    case "$1" in
        apache) echo "apache|httpd" ;;
        openlitespeed) echo "openlitespeed|ols|lsws|litespeed" ;;
        nginx) echo "nginx" ;;
        *) echo "" ;;
    esac
}

# Check whether any process matching the webserver type is running on the host.
# Echoes "yes" or "no". Uses pgrep -x (exact match) against the configured process list,
# then falls back to systemctl is-active.
_native_webserver_running() {
    local type="$1"
    local names
    names=$(_webservver_process_names "$type")
    if [ -z "$names" ]; then
        echo "no"
        return 0
    fi

    for n in $names; do
        if pgrep -x "$n" >/dev/null 2>&1; then
            echo "yes"
            return 0
        fi
    done

    # Fallback: systemctl is-active (covers systemd-managed services)
    if command -v systemctl >/dev/null 2>&1; then
        for svc in $names; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                echo "yes"
                return 0
            fi
        done
    fi

    echo "no"
    return 0
}

# Detect the webserver type currently running on the host (best effort).
# Returns one of: apache | openlitespeed | nginx | ""
_native_running_webserver_type() {
    for t in apache nginx openlitespeed; do
        local r
        r=$(_native_webserver_running "$t")
        if [ "$r" = "yes" ]; then
            echo "$t"
            return 0
        fi
    done
    echo ""
    return 0
}

# Check whether the docker container is running.
# Echoes "running" | "stopped" | "missing"
_docker_container_state() {
    local container="$1"
    if [ -z "$container" ]; then
        echo "missing"
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        echo "missing"
        return 0
    fi
    local state
    state=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)
    if [ -z "$state" ]; then
        echo "missing"
    elif [ "$state" = "true" ]; then
        echo "running"
    else
        echo "stopped"
    fi
    return 0
}

# Detect webserver type from the image of a docker container.
# Returns one of: apache | openlitespeed | nginx | ""
_docker_container_webserver_type() {
    local container="$1"
    if [ -z "$container" ] || ! command -v docker >/dev/null 2>&1; then
        echo ""
        return 0
    fi
    local image
    image=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null)
    if [ -z "$image" ]; then
        echo ""
        return 0
    fi

    local t pat
    for t in apache nginx openlitespeed; do
        pat=$(_webservver_image_patterns "$t")
        if echo "$image" | grep -qiE "$pat"; then
            echo "$t"
            return 0
        fi
    done
    echo ""
    return 0
}

# Aggregator: run all preflight checks and decide whether to proceed.
# Returns:
#   0   = proceed (all checks ok, or only warnings, or --force is set)
#   1   = fatal (do not proceed). Caller should NOT continue.
# Sets PREFLIGHT_RESULTS to a multi-line human-readable summary suitable for logs/email.
preflight_check_restore() {
    local backup_type="$1"
    local is_docker="$2"
    local container="$3"

    PREFLIGHT_RESULTS=""
    local fatal=0

    if [ -z "$backup_type" ]; then
        PREFLIGHT_RESULTS="${PREFLIGHT_RESULTS}\n  - [WARN] Could not determine webserver type from backup (skipping type checks)"
        echo "$PREFLIGHT_RESULTS"
        return 0
    fi

    if [ "$is_docker" = true ]; then
        # Docker mode checks
        local state
        state=$(_docker_container_state "$container")
        case "$state" in
            running)
                PREFLIGHT_RESULTS="${PREFLIGHT_RESULTS}\n  - [OK]   Container '$container' is running"
                # Check image matches backup type
                local img_type
                img_type=$(_docker_container_webserver_type "$container")
                if [ -n "$img_type" ] && [ "$img_type" != "$backup_type" ]; then
                    PREFLIGHT_RESULTS="${PREFLIGHT_RESULTS}\n  - [WARN] Backup type is '$backup_type' but container image looks like '$img_type'"
                elif [ -n "$img_type" ]; then
                    PREFLIGHT_RESULTS="${PREFLIGHT_RESULTS}\n  - [OK]   Container image matches backup type ('$backup_type')"
                fi
                ;;
            stopped)
                PREFLIGHT_RESULTS="${PREFLIGHT_RESULTS}\n  - [FATAL] Container '$container' exists but is NOT running — cannot restore into it"
                fatal=1
                ;;
            missing)
                PREFLIGHT_RESULTS="${PREFLIGHT_RESULTS}\n  - [FATAL] Container '$container' does not exist (or docker not available)"
                fatal=1
                ;;
        esac
    else
        # Native mode checks
        local running_type
        running_type=$(_native_running_webserver_type)
        if [ -z "$running_type" ]; then
            PREFLIGHT_RESULTS="${PREFLIGHT_RESULTS}\n  - [WARN] No webserver process detected on host (no nginx/apache2/httpd/lshttpd running)"
            PREFLIGHT_RESULTS="${PREFLIGHT_RESULTS}\n         (this is OK if you are restoring to a fresh host before starting the webserver)"
        else
            PREFLIGHT_RESULTS="${PREFLIGHT_RESULTS}\n  - [OK]   Detected webserver process on host: '$running_type'"
            if [ "$running_type" != "$backup_type" ]; then
                PREFLIGHT_RESULTS="${PREFLIGHT_RESULTS}\n  - [WARN] Backup type is '$backup_type' but host is running '$running_type' — restore will overwrite a different webserver's config"
            else
                PREFLIGHT_RESULTS="${PREFLIGHT_RESULTS}\n  - [OK]   Host webserver type matches backup type ('$backup_type')"
            fi
        fi
    fi

    if [ $fatal -ne 0 ]; then
        echo -e "$PREFLIGHT_RESULTS"
        return 1
    fi
    echo -e "$PREFLIGHT_RESULTS"
    return 0
}

# Stream files into a target — host dir or in-container dir
restore_files() {
    local src_dir="$2"   # source dir on host; $1 is the description echo below
    local dest="$3"      # host path or container:path
    local kind="$4"      # "host" or "container"
    local description="$5"

    log_message "Restoring $description to $dest ($kind)..."

    if [ "$DRY_RUN" = true ]; then
        if [ "$kind" = "host" ]; then
            log_message "[DRY-RUN] Would copy contents of $src_dir -> $dest"
        else
            local container="${dest%%:*}"
            local inpath="${dest#*:}"
            log_message "[DRY-RUN] Would copy contents of $src_dir -> container $container:$inpath"
        fi
        return 0
    fi

    if [ "$kind" = "host" ]; then
        if [ ! -d "$dest" ]; then
            mkdir -p "$dest"
        fi
        if cp -r "$src_dir"/. "$dest"/; then
            log_message "Files copied successfully to $dest"
            return 0
        else
            log_message "ERROR: Failed to copy files to $dest"
            return 1
        fi
    fi

    # Container restore: tar | docker exec tar
    local container="${dest%%:*}"
    local inpath="${dest#*:}"

    # Ensure parent dir exists
    docker exec "$container" mkdir -p "$(dirname "$inpath")" >/dev/null 2>&1 || true

    if tar -C "$src_dir" -cf - . | docker exec -i "$container" tar -xf - -C "$inpath" 2>/dev/null; then
        log_message "Files copied successfully into container $container:$inpath"
        return 0
    else
        log_message "ERROR: Failed to copy files into container $container:$inpath"
        return 1
    fi
}

# Verify post-restore presence of key files
verify_post_restore() {
    local kind="$1"
    local target="$2"

    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY-RUN] Skipping post-restore verification"
        return 0
    fi

    log_message "Verifying restored configuration..."

    local check_path
    if [ "$kind" = "host" ]; then
        check_path="$target"
    else
        local container="${target%%:*}"
        local inpath="${target#*:}"
        if ! check_path=$(docker exec "$container" sh -c "test -d '$inpath' && echo '$inpath' || true"); then
            check_path=""
        fi
    fi

    if [ -z "$check_path" ]; then
        log_message "WARNING: Could not verify restored target (path missing?)"
        return 1
    fi

    local key_files=()
    case "$WEBSERVER_TYPE" in
        apache)
            key_files=("apache2.conf" "httpd.conf" "nginx.conf")
            ;;
        openlitespeed)
            key_files=("httpd_config.conf" "nginx.conf" "httpd.conf")
            ;;
        nginx)
            key_files=("nginx.conf" "httpd.conf" "apache2.conf")
            ;;
        *)
            key_files=("nginx.conf" "httpd.conf")
            ;;
    esac

    local found=false
    local f
    for f in "${key_files[@]}"; do
        if [ "$kind" = "host" ]; then
            if [ -f "$check_path/$f" ]; then
                log_message "  ✓ Found $f"
                found=true
                break
            fi
        else
            local container="${target%%:*}"
            if docker exec "$container" test -f "$check_path/$f"; then
                log_message "  ✓ Found $f"
                found=true
                break
            fi
        fi
    done

    if [ "$found" = false ]; then
        log_message "WARNING: Could not confirm any expected config file in $target"
        log_message "  (This is normal if the source contained only custom files; the backup may still be valid.)"
    fi
}

# Try a graceful reload of the webserver; never fatal if it fails
attempt_reload() {
    if [ "$DRY_RUN" = true ]; then
        log_message "[DRY-RUN] Skipping reload"
        return 0
    fi

    log_message "Attempting graceful reload of $WEBSERVER_TYPE..."

    if [ "$IS_DOCKER" = true ]; then
        local container="$WEBSERVER_CONTAINER"
        local cmd=""
        case "$WEBSERVER_TYPE" in
            apache) cmd="apachectl -k graceful || httpd -k graceful || true" ;;
            nginx) cmd="nginx -s reload || true" ;;
            openlitespeed) cmd="lswsctrl reload || /usr/local/lsws/bin/lswsctrl reload || true" ;;
            *) cmd="true" ;;
        esac
        docker exec "$container" sh -c "$cmd" >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_message "Reload command issued in container $container"
        else
            log_message "WARNING: Reload command failed inside container (non-fatal)"
        fi
        return 0
    fi

    case "$WEBSERVER_TYPE" in
        apache)
            if command -v apachectl &> /dev/null; then
                apachectl -k graceful >/dev/null 2>&1 \
                    || log_message "WARNING: apachectl reload failed (non-fatal)"
                log_message "Reload command issued (apachectl -k graceful)"
            fi
            ;;
        nginx)
            if command -v nginx &> /dev/null; then
                nginx -s reload >/dev/null 2>&1 \
                    || log_message "WARNING: nginx reload failed (non-fatal)"
                log_message "Reload command issued (nginx -s reload)"
            fi
            ;;
        openlitespeed)
            if command -v lswsctrl &> /dev/null; then
                lswsctrl reload >/dev/null 2>&1 \
                    || log_message "WARNING: lswsctrl reload failed (non-fatal)"
                log_message "Reload command issued (lswsctrl reload)"
            fi
            ;;
    esac
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -b) BACKUP_FILE="$2"; shift 2 ;;
        -f) WEBSERVER_DIR="$2"; shift 2 ;;
        -c) WEBSERVER_CONTAINER="$2"; shift 2 ;;
        -e) EMAIL_TO="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h) SHOW_HELP=true; shift ;;
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

# Validate required parameters
if [ -z "$BACKUP_FILE" ]; then
    echo "ERROR: Missing required parameter -b (backup file)"
    echo ""
    show_help
    exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    log_message "ERROR: Backup file does not exist: $BACKUP_FILE"
    exit 1
fi

# Initialize log file for email report
init_log_file
log_message "Log file initialized: $LOG_FILE"

log_message "Starting Webserver Restore process"
log_message "Backup file: $BACKUP_FILE"

# Verify backup integrity
log_message "Verifying backup integrity..."
if unzip -t "$BACKUP_FILE" >/dev/null 2>&1; then
    log_message "Backup integrity verified successfully"
else
    log_message "ERROR: Backup integrity verification failed"
    exit 1
fi

# Check dependencies
check_dependencies

# Create temporary directory
TEMP_DIR=$(mktemp -d)

# Cleanup function
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

    # On SUCCESS: remove the safety backups we created
    # On FAILURE: preserve them so the user can roll back manually
    if [ $exit_code -eq 0 ]; then
        if [ ${#RESTORE_SAFETY_BACKUPS[@]} -gt 0 ]; then
            log_message "Cleaning up safety backups (restore succeeded)..."
            for p in "${RESTORE_SAFETY_BACKUPS[@]}"; do
                if [[ "$p" == container:* ]]; then
                    local rest="${p#container:}"
                    local container="${rest%%:*}"
                    local path="${rest#*:}"
                    docker exec "$container" rm -rf "$path" >/dev/null 2>&1 || true
                else
                    rm -rf "$p" >/dev/null 2>&1 || true
                fi
            done
        fi
    else
        if [ ${#RESTORE_SAFETY_BACKUPS[@]} -gt 0 ]; then
            log_message "Restore failed; safety backups preserved for manual recovery:"
            for p in "${RESTORE_SAFETY_BACKUPS[@]}"; do
                log_message "  - $p"
            done
        fi
    fi

    log_message "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
    rm -f "$LOG_FILE"
}

# Set trap to cleanup on exit
trap cleanup EXIT

# Extract backup
log_message "Extracting backup..."
if ! unzip -q "$BACKUP_FILE" -d "$TEMP_DIR"; then
    log_message "ERROR: Failed to extract backup"
    exit 1
fi

if [ ! -d "$TEMP_DIR/files" ]; then
    log_message "ERROR: Invalid backup structure: 'files/' directory missing"
    exit 1
fi

# Read .backup_info if present
BACKUP_CONTAINER_FROM_INFO=""
if [ -f "$TEMP_DIR/files/.backup_info" ]; then
    parse_backup_info "$TEMP_DIR/files/.backup_info"
    log_message "Backup metadata:"
    log_message "  webserver_type : ${WEBSERVER_TYPE:-N/A}"
    log_message "  source_dir     : ${BACKUP_SOURCE:-N/A}"
    log_message "  container      : ${BACKUP_CONTAINER_FROM_INFO:-N/A}"
    log_message "  environment    : ${BACKUP_ENV:-N/A}"
    log_message "  timestamp      : ${BACKUP_TIMESTAMP:-N/A}"
    log_message "  host           : ${BACKUP_HOST:-N/A}"
else
    log_message "WARNING: No .backup_info found in backup; will try to infer type from contents"
fi

# If type still unknown, try to infer from file names in files/
if [ -z "$WEBSERVER_TYPE" ]; then
    if [ -f "$TEMP_DIR/files/nginx.conf" ]; then
        WEBSERVER_TYPE="nginx"
    elif [ -f "$TEMP_DIR/files/httpd_config.conf" ]; then
        WEBSERVER_TYPE="openlitespeed"
    elif [ -f "$TEMP_DIR/files/apache2.conf" ] || [ -f "$TEMP_DIR/files/httpd.conf" ]; then
        WEBSERVER_TYPE="apache"
    else
        log_message "ERROR: Could not determine webserver type from backup contents"
        exit 1
    fi
    log_message "Inferred webserver type from contents: $WEBSERVER_TYPE"
fi

# Determine target environment
# 1. If BACKUP_ENV says docker → use docker mode (unless -c was given)
# 2. If -f points at a host path → use native mode
# 3. Otherwise default: honor BACKUP_ENV, fallback to native
if [ "$BACKUP_ENV" = "docker" ] && [ -z "$WEBSERVER_CONTAINER" ]; then
    # Try -f as a host path first; if it doesn't exist on host, treat as in-container path
    if [ -n "$WEBSERVER_DIR" ] && [ ! -e "$WEBSERVER_DIR" ]; then
        IS_DOCKER=true
        DOCKER_COMPOSE_DIR=""
        log_message "Target environment: Docker (-f is in-container path; not present on host)"
    elif [ -n "$WEBSERVER_DIR" ] && [ -e "$WEBSERVER_DIR" ]; then
        IS_DOCKER=false
        log_message "Target environment: Native (-f resolves to host path)"
    else
        IS_DOCKER=true
        log_message "Target environment: Docker (inherited from backup metadata)"
    fi
elif [ "$BACKUP_ENV" = "native" ] && [ -z "$WEBSERVER_CONTAINER" ]; then
    IS_DOCKER=false
    log_message "Target environment: Native (inherited from backup metadata)"
elif [ -n "$WEBSERVER_CONTAINER" ]; then
    # -c forces docker mode
    IS_DOCKER=true
    log_message "Target environment: Docker (forced via -c)"
elif [ -n "$WEBSERVER_DIR" ] && [ -e "$WEBSERVER_DIR" ]; then
    IS_DOCKER=false
    log_message "Target environment: Native (-f resolves to host path)"
else
    IS_DOCKER=false
    log_message "Target environment: Native (default)"
fi

# Re-check dependencies with current IS_DOCKER
check_dependencies

# Resolve target container (Docker mode)
if [ "$IS_DOCKER" = true ]; then
    if [ -z "$WEBSERVER_CONTAINER" ]; then
        if [ -n "$BACKUP_CONTAINER_FROM_INFO" ]; then
            WEBSERVER_CONTAINER="$BACKUP_CONTAINER_FROM_INFO"
            log_message "Using container from backup: $WEBSERVER_CONTAINER"
        else
            log_message "No container recorded; auto-detecting..."
            WEBSERVER_CONTAINER=$(detect_webserver_container "$DOCKER_COMPOSE_DIR" "$WEBSERVER_TYPE")
            if [ -z "$WEBSERVER_CONTAINER" ]; then
                log_message "ERROR: Could not determine target webserver container. Use -c to specify."
                exit 1
            fi
            log_message "Detected container: $WEBSERVER_CONTAINER"
        fi
    fi

    # Verify container is running
    if ! docker ps --format "table {{.Names}}" | grep -q "^${WEBSERVER_CONTAINER}$"; then
        log_message "ERROR: Webserver container '$WEBSERVER_CONTAINER' is not running"
        exit 1
    fi

    # Resolve in-container target path
    if [ -z "$WEBSERVER_DIR" ]; then
        WEBSERVER_DIR=$(default_in_container_path "$WEBSERVER_TYPE")
        if [ -z "$WEBSERVER_DIR" ]; then
            log_message "ERROR: No default in-container path for $WEBSERVER_TYPE. Use -f to specify."
            exit 1
        fi
        log_message "Using default in-container path: $WEBSERVER_DIR"
    else
        # If -f is actually a host path that exists, prefer the in-container default
        # (otherwise treat the value as the in-container path)
        if [ -e "$WEBSERVER_DIR" ]; then
            log_message "WARNING: -f points at host path '$WEBSERVER_DIR'; using in-container default instead"
            WEBSERVER_DIR=$(default_in_container_path "$WEBSERVER_TYPE")
            [ -z "$WEBSERVER_DIR" ] && { log_message "ERROR: No default in-container path. Use -f <in-container-path>."; exit 1; }
        fi
    fi
else
    # Native: resolve target dir
    if [ -z "$WEBSERVER_DIR" ]; then
        WEBSERVER_DIR=$(default_native_config_dir "$WEBSERVER_TYPE")
        if [ -z "$WEBSERVER_DIR" ]; then
            log_message "ERROR: No default native config dir for $WEBSERVER_TYPE. Use -f to specify."
            exit 1
        fi
        log_message "Using default native config dir: $WEBSERVER_DIR"
    fi
fi

# Build target string for restore_files
if [ "$IS_DOCKER" = true ]; then
    TARGET="${WEBSERVER_CONTAINER}:${WEBSERVER_DIR}"
else
    TARGET="$WEBSERVER_DIR"
fi

log_message "Webserver type : $WEBSERVER_TYPE"
log_message "Target         : $TARGET"
log_message "Mode           : $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "APPLY")"
log_message "Force          : $FORCE"

# Preflight checks: verify target is reachable and (softly) that the running webserver matches the backup type.
# Aborts only on FATAL (e.g. Docker container not running). Mismatch / no-process on host → WARN only.
log_message "Running preflight checks..."
if [ "$FORCE" = true ]; then
    log_message "  - [SKIP] --force flag set; bypassing preflight checks"
    PREFLIGHT_RESULTS="  - [SKIP] Bypassed by --force"
else
    if ! preflight_check_restore "$WEBSERVER_TYPE" "$IS_DOCKER" "$WEBSERVER_CONTAINER" > "$TEMP_DIR/preflight.txt" 2>&1; then
        log_message "Preflight FAILED — aborting restore:"
        cat "$TEMP_DIR/preflight.txt" | sed 's/^/  /'
        log_message "Re-run with --force to override preflight checks."
        exit 1
    fi
    PREFLIGHT_RESULTS=$(cat "$TEMP_DIR/preflight.txt")
    log_message "Preflight results:"
    echo "$PREFLIGHT_RESULTS" | sed 's/^/  /'
fi

# Safety backup existing config (unless --force)
if [ "$FORCE" != true ]; then
    if [ "$IS_DOCKER" = true ]; then
        safety_backup_target "$WEBSERVER_DIR" "container" "$WEBSERVER_CONTAINER"
    else
        safety_backup_target "$WEBSERVER_DIR" "host"
    fi
else
    log_message "Skipping safety backup (--force)"
fi

# Restore files
if ! restore_files "files" "$TEMP_DIR/files" "$TARGET" \
        "$([ "$IS_DOCKER" = true ] && echo container || echo host)" \
        "webservver config ($WEBSERVER_TYPE)"; then
    log_message "ERROR: File restoration failed"
    exit 1
fi

# Post-restore verification
verify_post_restore \
    "$([ "$IS_DOCKER" = true ] && echo container || echo host)" "$TARGET"

# Attempt reload (best-effort)
attempt_reload

log_message "Webserver Restore process completed"
log_message "Target: $TARGET"
exit 0