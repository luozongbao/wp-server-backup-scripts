#!/bin/bash

# Webserver Backup Script
# Creates a backup of webserver configuration files (Apache, OpenLiteSpeed, Nginx)
# Auto-detects Docker or native installation
# Usage: ./webserver_backup.sh [-f /path/to/config] [-o /path/to/backup/output] [-e EMAIL] [-h]

# Default values
WEBSERVER_DIR=""
OUTPUT_DIR="$(pwd)"
SHOW_HELP=false
WEBSERVER_TYPE=""
WEBSERVER_CONTAINER=""
IS_DOCKER=false
EMAIL_TO=""
EMAIL_FROM="admin@companydomain.com"
DOCKER_COMPOSE_DIR=""

# Function to display help
show_help() {
    echo "Webserver Backup Script"
    echo "=========================="
    echo ""
    echo "Usage: $0 [-o OUTPUT_DIR] [-e EMAIL] [-f WEBSERVER_DIR] [-h]"
    echo ""
    echo "Options:"
    echo "  -o OUTPUT_DIR        Path to the backup output directory (optional, default: current directory)"
    echo "  -e EMAIL             Send backup report to this email address (optional)"
    echo "  -f WEBSERVER_DIR     (Advanced) Override the auto-detected source path."
    echo "                       Use only when the default path doesn't match your install"
    echo "                       (e.g. custom build paths or subset-only backups)."
    echo "                       Most users do not need this option."
    echo "  -h                   Show this help message"
    echo ""
    echo "Environment variables (Docker mode, optional):"
    echo "  WEBSERVER_SERVICE    Force the webserver service name instead of auto-detecting."
    echo "                       Useful when the webserver service is not the first one"
    echo "                       whose image matches the webserver type."
    echo "                       Example: export WEBSERVER_SERVICE=webserver"
    echo ""
    echo "  You can also mark the webserver service explicitly in docker-compose.yml:"
    echo "       services:"
    echo "         webserver:"
    echo "           image: litespeedtech/openlitespeed:latest"
    echo "           labels:"
    echo "             - \"wp-backup=webserver\"   # <-- explicit marker"
    echo ""
    echo "  Port matching in compose files honours \${VAR:-default} interpolation,"
    echo "  so .env values (e.g. WEB_PORT=8080) are considered when auto-detecting."
    echo ""
    echo "Examples:"
    echo "  $0                                  (auto-detect everything — recommended)"
    echo "  $0 -o /backups"
    echo "  $0 -o /backups -e admin@example.com"
    echo "  $0 -f /etc/apache2                   (override source path)"
    echo "  $0 -f /etc/nginx/sites-enabled      (backup only a subset)"
    echo "  WEBSERVER_SERVICE=litespeed $0 -o /backups    (force service name)"
    echo ""
    echo "Output format: [timestamp]_[type]_config_backup.zip"
    echo "Example: 20250530_143022_nginx_config_backup.zip"
    echo "         20250530_143022_apache_config_backup.zip"
    echo "         20250530_143022_openlitespeed_config_backup.zip"
    echo ""
    echo "Auto-detection covers:"
    echo "  - Native installs (apache/openlitespeed/nginx from packages or processes)"
    echo "  - Docker installs (compose files and well-known container images)"
    echo "  - Standard config paths for each webserver type"
    echo ""
    echo "Docker service resolution priority (highest first):"
    echo "  1. Label 'wp-backup: webserver' on the service          (explicit)"
    echo "  2. \$WEBSERVER_SERVICE env var                            (explicit override)"
    echo "  3. Image matches webserver type + ports expose 80/443/   (heuristic)"
    echo "     8080/8443 (resolves \${VAR} from compose .env)"
    echo "  4. First service whose image matches webserver type     (legacy fallback)"
    echo ""
    echo "Features:"
    echo "  - Supports Apache, OpenLiteSpeed, LiteSpeed Enterprise, Nginx"
    echo "  - Auto-detects Docker containers (uses docker exec tar for in-container configs)"
    echo "  - Auto-detects native installation from system packages and known paths"
    echo "  - Verifies backup integrity"
    echo "  - Optional email notification via msmtp"
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
    LOG_FILE=$(mktemp /tmp/webserver_backup_XXXXXX.log)
    : > "$LOG_FILE"
    export LOG_FILE
}

# ---- Shared helpers ----
# Centralize patterns that were duplicated across backup_config_docker() /
# backup_config_native() / detect_docker_*() so the size probe, container-
# running probe, image-regex mapping, and compose-file type detection are
# written once.

# _dir_size: human-readable size of $1 (path or file). Used by the backup
# functions to log "Config size:" / "Backup size:" lines.
_dir_size() {
    du -sh "$1" | cut -f1
}

# container_is_running: probe whether a docker container with exact name $1
# is currently running. Returns 0 if running, 1 otherwise.
container_is_running() {
    docker ps --format "table {{.Names}}" 2>/dev/null | grep -qx "$1"
}

# _webservver_image_regex: case-based regex (grep -E flavour) that matches
# the canonical image-name fragments for a given webserver type. Empty
# string when the type is unknown.
_webservver_image_regex() {
    case "$1" in
        apache)         echo "apache|httpd" ;;
        openlitespeed)  echo "openlitespeed|ols|lsws|litespeed" ;;
        nginx)          echo "nginx" ;;
        *)              echo "" ;;
    esac
}

# _detect_webservver_type_from_compose_file: scan a docker-compose.yml for
# image references and pick the most specific webserver type using the
# priority order openlitespeed > nginx > apache. Echoes the detected type
# (apache | openlitespeed | nginx) or empty string when no match.
_detect_webservver_type_from_compose_file() {
    local compose_file="$1"
    if grep -qiE "openlitespeed|litespeed|ols|lsws" "$compose_file"; then
        echo "openlitespeed"
    elif grep -qiE "nginx" "$compose_file"; then
        echo "nginx"
    elif grep -qiE "apache|httpd" "$compose_file"; then
        echo "apache"
    else
        echo ""
    fi
}

# Single canonical regex matching ANY webserver image we recognise. Used to
# decide whether a compose file or running container list "looks like a
# webserver". Centralised so compose-scan and container-scan stay in sync.
readonly _WEBSERVER_IMAGE_REGEX='apache|httpd|nginx|openlitespeed|ols|lsws|litespeed'

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

    local subject_prefix="[Webserver Backup]"
    if [ "$status" = "SUCCESS" ]; then
        local subject="${subject_prefix} ✅ SUCCESS - ${WEBSERVER_TYPE:-auto} (${TIMESTAMP})"
    else
        local subject="${subject_prefix} ❌ FAILED - ${WEBSERVER_TYPE:-auto} (${TIMESTAMP})"
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
        echo "Webserver Backup Report"
        echo "==========================="
        echo ""
        echo "Status          : ${status}"
        echo "Exit code       : ${exit_code}"
        echo "Webserver type  : ${WEBSERVER_TYPE:-N/A}"
        echo "Source dir      : ${WEBSERVER_DIR:-N/A}"
        echo "Environment     : $([ "$IS_DOCKER" = true ] && echo "Docker ($WEBSERVER_CONTAINER)" || echo "Native")"
        echo "Backup file     : ${BACKUP_PATH:-N/A}"
        echo "Backup size     : ${backup_size_line}"
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
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_message "ERROR: Missing required tools: ${missing_tools[*]}"
        log_message "Please install the missing tools and try again."
        exit 1
    fi
}

# Function to detect webserver type from a config directory
detect_webservver_type_from_dir() {
    local dir="$1"

    if [ -f "$dir/httpd.conf" ] || [ -d "$dir/apache2" ] || [ -d "$dir/conf-available" ]; then
        echo "apache"
        return 0
    fi

    if [ -d "$dir/lsws" ] || [ -f "$dir/httpd_config.conf" ]; then
        echo "openlitespeed"
        return 0
    fi

    if [ -f "$dir/nginx.conf" ]; then
        echo "nginx"
        return 0
    fi

    return 1
}

# Function to detect webserver type natively from known install locations and packages
detect_native_webservver_type() {
    log_message "Attempting to auto-detect native webserver..."

    # 1. Apache (Debian/Ubuntu layout)
    if [ -d "/etc/apache2" ] || [ -f "/etc/httpd/conf/httpd.conf" ]; then
        echo "apache"
        return 0
    fi

    # 2. OpenLiteSpeed / LiteSpeed Enterprise
    if [ -d "/usr/local/lsws" ] || [ -d "/usr/local/litespeed" ]; then
        echo "openlitespeed"
        return 0
    fi

    # 3. Nginx
    if [ -d "/etc/nginx" ]; then
        echo "nginx"
        return 0
    fi

    # Fallback: check installed packages
    if command -v dpkg &> /dev/null; then
        if dpkg -l | grep -qE "apache2|httpd"; then
            echo "apache"
            return 0
        fi
        if dpkg -l | grep -qE "openlitespeed|litespeed"; then
            echo "openlitespeed"
            return 0
        fi
        if dpkg -l | grep -qE "nginx"; then
            echo "nginx"
            return 0
        fi
    fi

    if command -v rpm &> /dev/null; then
        if rpm -qa 2>/dev/null | grep -qiE "^httpd|^apache2"; then
            echo "apache"
            return 0
        fi
        if rpm -qa 2>/dev/null | grep -qiE "openlitespeed|litespeed"; then
            echo "openlitespeed"
            return 0
        fi
        if rpm -qa 2>/dev/null | grep -qiE "^nginx"; then
            echo "nginx"
            return 0
        fi
    fi

    # Fallback: check running processes
    if pgrep -f "apache2|httpd" > /dev/null; then
        echo "apache"
        return 0
    fi
    if pgrep -f "openlitespeed|lshttpd" > /dev/null; then
        echo "openlitespeed"
        return 0
    fi
    if pgrep -f "nginx" > /dev/null; then
        echo "nginx"
        return 0
    fi

    return 1
}

# Function to map detected webserver type to its native config directory
get_native_config_dir() {
    case "$1" in
        apache)
            if [ -d "/etc/apache2" ]; then
                echo "/etc/apache2"
            elif [ -d "/etc/httpd" ]; then
                echo "/etc/httpd"
            else
                echo ""
            fi
            ;;
        openlitespeed)
            if [ -d "/usr/local/lsws/conf" ]; then
                echo "/usr/local/lsws/conf"
            elif [ -d "/usr/local/litespeed/conf" ]; then
                echo "/usr/local/litespeed/conf"
            else
                echo ""
            fi
            ;;
        nginx)
            if [ -d "/etc/nginx" ]; then
                echo "/etc/nginx"
            else
                echo ""
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

# Function to detect if a webserver is running in Docker via docker-compose.yml
#
# Decision rules (in priority order):
#   1. If -f points at an existing host path AND no docker-compose.yml is found
#      in that path or its parents, force native mode. This avoids false positives
#      caused by unrelated webserver-named Docker containers running on the host
#      (e.g. sidecars) when the user clearly intends to back up host-side config.
#   2. If a docker-compose.yml containing a webserver service is found in the
#      current/parent dirs of the search path, use Docker mode.
#   3. If -f was NOT supplied, fall back to scanning known roots (/var/www, /opt,
#      /srv) and finally to running Docker containers.
detect_docker_environment() {
    log_message "Checking for Docker environment..."

    # If a config dir was supplied, look up the parent for docker-compose.yml
    local search_dir="${WEBSERVER_DIR:-$(pwd)}"

    local current_dir="$search_dir"
    local compose_file=""

    for i in {0..3}; do
        if [ -f "$current_dir/docker-compose.yml" ]; then
            compose_file="$current_dir/docker-compose.yml"
            break
        fi
        if [ -f "$current_dir/docker-compose.yaml" ]; then
            compose_file="$current_dir/docker-compose.yaml"
            break
        fi
        current_dir=$(dirname "$current_dir")
        if [ "$current_dir" = "/" ]; then
            break
        fi
    done

    if [ -n "$compose_file" ]; then
        log_message "Found docker-compose.yml at: $compose_file"
        if grep -qiE "$_WEBSERVER_IMAGE_REGEX" "$compose_file"; then
            IS_DOCKER=true
            DOCKER_COMPOSE_DIR=$(dirname "$compose_file")
            log_message "Detected Docker webserver environment"
            return 0
        fi
    fi

    # If -f was supplied and pointed at a real path with no compose file nearby,
    # the user clearly wants native mode — do not fall back to running containers.
    if [ -n "$WEBSERVER_DIR" ] && [ -e "$WEBSERVER_DIR" ]; then
        log_message "-f path is on the host and no webserver compose file found nearby; staying native"
        IS_DOCKER=false
        return 1
    fi

    # Auto-detect (no -f): scan well-known roots for compose files
    if [ -z "$WEBSERVER_DIR" ]; then
        for d in /var/www /opt /srv; do
            if [ -d "$d" ]; then
                if [ -f "$d/docker-compose.yml" ] || [ -f "$d/docker-compose.yaml" ]; then
                    local cf="$d/docker-compose.yml"
                    [ -f "$d/docker-compose.yaml" ] && cf="$d/docker-compose.yaml"
                    if grep -qiE "$_WEBSERVER_IMAGE_REGEX" "$cf"; then
                        IS_DOCKER=true
                        DOCKER_COMPOSE_DIR="$d"
                        log_message "Detected Docker webserver environment via $cf"
                        return 0
                    fi
                fi
            fi
        done

        # Last resort: scan running containers for known webserver images.
        # Only triggers when -f was NOT supplied (handled above otherwise).
        if command -v docker &> /dev/null; then
            local web_containers=$(docker ps --format "table {{.Image}} {{.Names}}" 2>/dev/null \
                | grep -iE "$_WEBSERVER_IMAGE_REGEX" || true)
            if [ -n "$web_containers" ]; then
                log_message "Found webserver-related Docker containers running"
                IS_DOCKER=true
                DOCKER_COMPOSE_DIR="$(pwd)"
                return 0
            fi
        fi
    fi

    log_message "No Docker environment detected, using native webserver"
    IS_DOCKER=false
    return 1
}

# Load .env variables from $DOCKER_COMPOSE_DIR/.env so we can resolve
# ${WEB_PORT:-80} style interpolations when matching port mappings.
# Outputs KEY=VALUE pairs (one per line) so callers can source them safely.
load_compose_env() {
    local env_file="$DOCKER_COMPOSE_DIR/.env"
    [ -f "$env_file" ] || return 0

    # Only accept lines matching NAME=VALUE (docker-compose convention).
    # Skip comments and blank lines. Values may be quoted.
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^[A-Za-z_][A-Za-z0-9_]*=/ {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            # Strip optional leading "export "
            sub(/^export[[:space:]]+/, "", line)
            print line
        }
    ' "$env_file" 2>/dev/null
}

# Resolve a docker-compose port-spec string with possible ${VAR:-default}
# interpolation. Echoes the host port (the part before ':').
# Examples:
#   "${WEB_PORT:-80}:80"            -> "80" (when WEB_PORT unset)
#   "${WEB_PORT:-8080}:80"          -> "8080"
#   "80:80"                         -> "80"
#   "127.0.0.1:8080:80"             -> "8080"
resolve_host_port() {
    local spec="$1"
    local env_line
    # Read env into shell vars (sourced in subshell to avoid leaking into parent).
    while IFS= read -r env_line; do
        [ -n "$env_line" ] || continue
        # shellcheck disable=SC2086
        case "$env_line" in
            *=*) eval "local ${env_line%%=*}=\"\${env_line#*=}\"" ;;
        esac
    done <<< "$(load_compose_env)"

    # Replace ${VAR:-default} and ${VAR} occurrences in the spec.
    # Use bash parameter expansion to evaluate the result.
    local expanded="$spec"
    # Repeat substitution to handle nested patterns (rare but cheap).
    local prev=""
    while [ "$expanded" != "$prev" ]; do
        prev="$expanded"
        # ${VAR:-default}
        if [[ "$expanded" =~ \$\{([A-Za-z_][A-Za-z0-9_]*):-([[:print:]]+)\} ]]; then
            local var="${BASH_REMATCH[1]}"
            local def="${BASH_REMATCH[2]}"
            local val="${!var:-$def}"
            expanded="${expanded//\$\{$var:-${BASH_REMATCH[2]}\}/$val}"
        fi
        # ${VAR}
        if [[ "$expanded" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; then
            local var="${BASH_REMATCH[1]}"
            local val="${!var:-}"
            expanded="${expanded//\$\{$var\}/$val}"
        fi
    done

    # Strip surrounding quotes.
    expanded="${expanded%\"}"; expanded="${expanded#\"}"
    expanded="${expanded%\'}"; expanded="${expanded#\'}"

    # Handle IP-prefixed form: "IP:HOST:CONTAINER" -> take middle part.
    # Also handle quoted list: "\"80:80\"" -> already stripped above.
    local IFS=':'
    local parts=( $expanded )
    case "${#parts[@]}" in
        2) echo "${parts[0]}";;
        3) echo "${parts[1]}";;
        *) echo "${parts[0]}";;
    esac
}

# Build a regex that matches common webserver port specs (resolved form).
# Used by the port-based heuristic in detect_docker_webservver_info().
_webservver_port_regex() {
    case "$1" in
        # Match 80, 443, 8080, 8443 (Apache/OLS/Nginx defaults).
        # Also match common alt-ports users expose webserver on.
        apache|nginx|openlitespeed)
            echo '^(80|443|8080|8443)$'
            ;;
        *)
            echo '^(80|443|8080|8443)$'
            ;;
    esac
}

# Function to detect webserver container + image type from docker-compose.yml
#
# Resolution priority (highest first):
#   A. Label `wp-backup: webserver` on the service  (explicit user intent)
#   B. $WEBSERVER_SERVICE env var                    (explicit override)
#   C. Port-based heuristic: image matches + ports expose webserver port
#      (resolved through $DOCKER_COMPOSE_DIR/.env if present)
#   D. Fallback: first service whose image matches the webserver type
#      (legacy behaviour — preserves backward compatibility)
detect_docker_webservver_info() {
    local compose_file="$DOCKER_COMPOSE_DIR/docker-compose.yml"

    if [ ! -f "$compose_file" ]; then
        compose_file="$DOCKER_COMPOSE_DIR/docker-compose.yaml"
    fi

    if [ ! -f "$compose_file" ]; then
        log_message "ERROR: docker-compose.yml not found in $DOCKER_COMPOSE_DIR"
        return 1
    fi

    log_message "Analyzing docker-compose.yml for webserver service..."

    # Detect image type
    local detected_type
    detected_type=$(_detect_webservver_type_from_compose_file "$compose_file")
    if [ -z "$detected_type" ]; then
        log_message "ERROR: Could not detect webserver type in docker-compose.yml"
        return 1
    fi
    WEBSERVER_TYPE="$detected_type"

    log_message "Detected webserver type: $WEBSERVER_TYPE"

    local service_name=""
    local pick_reason=""

    # -------------------------------------------------------------------
    # Walk the file once, tracking the current service header by indent
    # level. When we hit a 'wp-backup: webserver' (or shorthand
    # 'wp-backup=webserver') label, the owning service is whoever the most
    # recent service header was. Robust to tab/spaces and leading-tab test
    # fixtures because we use lead() to count leading whitespace.
    local label_svc
    label_svc=$(awk '
        function lead() {
            m = match($0, /[^[:space:]]/); return (m == 0 ? length($0) : m - 1)
        }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            ind = lead()
            raw = $0
            sub(/^[[:space:]]*/, "", raw)
        }
        raw ~ /^(services|version|networks|volumes|configs|secrets):[[:space:]]*$/ {
            if (raw == "services:") { in_svc=1; current_svc=""; svc_indent=-1; next }
            in_svc=0; next
        }
        in_svc && raw ~ /^[A-Za-z0-9_.-]+:[[:space:]]*$/ {
            key = raw; sub(/:[[:space:]]*$/, "", key)
            if (current_svc == "" || ind <= svc_indent) {
                current_svc = key; svc_indent = ind
            }
        }
        in_svc && raw ~ /wp-backup[[:space:]]*[:=][[:space:]]*.*webserver/ {
            print current_svc; exit
        }
    ' "$compose_file" 2>/dev/null)
    if [ -n "$label_svc" ]; then
        service_name="$label_svc"
        pick_reason="label wp-backup=webserver"
    fi

    
        # -------------------------------------------------------------------
    # Priority B: $WEBSERVER_SERVICE env var override
    # -------------------------------------------------------------------
    if [ -z "$service_name" ] && [ -n "${WEBSERVER_SERVICE:-}" ]; then
        # Verify the named service exists in the compose file.
        if grep -qE "^[[:space:]]*${WEBSERVER_SERVICE}:[[:space:]]*$" "$compose_file" 2>/dev/null; then
            service_name="$WEBSERVER_SERVICE"
            pick_reason="WEBSERVER_SERVICE env var"
        else
            log_message "WARNING: WEBSERVER_SERVICE='$WEBSERVER_SERVICE' not found in $compose_file — ignoring"
        fi
    fi

    # -------------------------------------------------------------------
    # Priority C: port-based heuristic (image match + webserver port exposed)
    # -------------------------------------------------------------------
    if [ -z "$service_name" ]; then
        local port_regex
        port_regex=$(_webservver_port_regex "$WEBSERVER_TYPE")

        # Iterate services. For each service block, collect image + ports.
        # If image matches webserver type AND any resolved host port matches
        # the webserver port regex -> pick this service.
        service_name=$(awk -v type="$WEBSERVER_TYPE" -v pregex="$port_regex" '
            BEGIN { IGNORECASE=1 }
            function reset(   i) {
                current=""; svc_image=""; in_svc=0
                for (i in ports) delete ports[i]
                np=0
            }
            function commit_if_match(   img) {
                if (!in_svc || current == "") return
                img=svc_image
                if (img == "") return
                if (img !~ type) return
                if (np == 0) return
                # Check any port against regex. Pregex is anchored with ^...$
                # so use match() not exact equality.
                for (i = 1; i <= np; i++) {
                    if (ports[i] ~ pregex) { print current; exit }
                }
            }
            /^[^[:space:]].*:$/ && !/^[[:space:]]/ {
                # Commit previous service before starting a new top-level key
                # that is NOT a service (e.g. "services:", "version:").
                # A service key is followed by a service block indented with 2 spaces.
                # We use a simple heuristic: if the previous line had an
                # indented child, treat the next top-level as a new section.
                # (Awk one-pass: commit when we see the next non-service top key.)
                if (in_svc && current != "") {
                    commit_if_match()
                    if (matched) exit
                }
                reset()
                current=$0; sub(/:$/, "", current)
                in_svc=1
            }
            /^[[:space:]]+image:/ {
                line=$0
                sub(/^[[:space:]]+image:[[:space:]]*/, "", line)
                svc_image=line
            }
            /^[[:space:]]+ports:/ { in_ports=1; next }
            in_ports && /^[[:space:]]+-[[:space:]]/ {
                line=$0
                sub(/^[[:space:]]+-[[:space:]]*/, "", line)
                np++
                ports[np]=line
                next
            }
            in_ports && !/^[[:space:]]+-[[:space:]]/ && !/^[[:space:]]*$/ {
                in_ports=0
            }
            END {
                commit_if_match()
            }
        ' "$compose_file" 2>/dev/null)

        # Port matching with .env interpolation: awk handles structure,
        # bash resolves ${VAR:-default} in each port spec.
        if [ -z "$service_name" ]; then
            # Re-scan with bash, resolving ${VAR:-default} interpolations
            # from .env. Skip top-level reserved keys so we never treat
            # `services:` as a service name.
            local _svc="" _img="" _in_ports=0 _cur_svc=""
            local _type_pat
            _type_pat=$(_webservver_image_regex "$WEBSERVER_TYPE")

            while IFS= read -r line; do
                # Skip blank lines and comments.
                [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

                # Top-level key (no leading whitespace).
                if ! [[ "$line" =~ ^[[:space:]] ]]                     && [[ "$line" =~ ^([A-Za-z0-9_.-]+):[[:space:]]*$ ]]; then
                    local key="${BASH_REMATCH[1]}"
                    case "$key" in
                        services|version|networks|volumes|configs|secrets|name)
                            # Reserved top-level key — NOT a service.
                            # Clear current service so we don't mis-attribute
                            # subsequent image: lines to it.
                            _cur_svc=""
                            _img=""
                            _in_ports=0
                            continue
                            ;;
                        *)
                            # Real service header.
                            _cur_svc="$key"
                            _img=""
                            _in_ports=0
                            ;;
                    esac
                    continue
                fi

                # Indented line under a service.
                if [[ "$line" =~ ^[[:space:]]+image:[[:space:]]*(.+)$ ]]; then
                    _img="${BASH_REMATCH[1]}"
                    _img="${_img%\"}"; _img="${_img#\"}"
                    _img="${_img%'}"; _img="${_img#'}"
                elif [[ "$line" =~ ^[[:space:]]+ports:[[:space:]]*$ ]]; then
                    _in_ports=1
                elif [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.+)$ ]] && [ "$_in_ports" = 1 ]; then
                    local spec="${BASH_REMATCH[1]}"
                    local host_port
                    host_port=$(resolve_host_port "$spec")
                    host_port="${host_port%,}"
                    if [ -z "$service_name" ] \
                        && [ -n "$_cur_svc" ] \
                        && [ -n "$_img" ] \
                        && [ -n "$_type_pat" ] \
                        && echo "$_img" | grep -qiE "$_type_pat"; then
                        case "$host_port" in
                            80|443|8080|8443)
                                service_name="$_cur_svc"
                                pick_reason="port-based heuristic (port=$host_port)"
                                ;;
                        esac
                    fi
                fi
            done < "$compose_file"
        else
            pick_reason="port-based heuristic (structure match)"
        fi
    fi

    # -------------------------------------------------------------------
    # Priority D: fallback — first service whose image matches (legacy).
    # -------------------------------------------------------------------
    if [ -z "$service_name" ]; then
        log_message "Port-based heuristic found no match; falling back to image match"

        # Two-pass approach (same pattern as Priority A):
        #   1. Find all "image: ..." lines whose value matches webserver type.
        #   2. For each, walk backwards to find the nearest non-indented
        #      top-level key that is NOT a reserved key (services:, version:, ...).
        #   3. First such key wins; this is the legacy "first matching service" rule.
        local type_pat
        type_pat=$(_webservver_image_regex "$WEBSERVER_TYPE")

        local image_lns
        if [ -n "$type_pat" ]; then
            image_lns=$(grep -nEi "^[[:space:]]+image:[[:space:]]*($type_pat)" "$compose_file" 2>/dev/null                 | cut -d: -f1)
        fi

        for img_ln in $image_lns; do
            local i found_svc=""
            for i in $(seq $((img_ln-1)) -1 1); do
                local prev_line
                prev_line=$(sed -n "${i}p" "$compose_file" 2>/dev/null)
                [[ "$prev_line" =~ ^[[:space:]] ]] && continue
                [[ -z "$prev_line" || "$prev_line" =~ ^[[:space:]]*# ]] && continue
                if [[ "$prev_line" =~ ^([A-Za-z0-9_.-]+):[[:space:]]*$ ]]; then
                    local key="${BASH_REMATCH[1]}"
                    case "$key" in
                        services|version|networks|volumes|configs|secrets|name)
                            # Reached `services:` without finding a service
                            # header above this image line. Treat the image
                            # as belonging to no named service (skip).
                            break
                            ;;
                        *)
                            found_svc="$key"
                            break 2
                            ;;
                    esac
                fi
            done
            if [ -n "$found_svc" ]; then
                service_name="$found_svc"
                break
            fi
        done

        # Last-resort fallback: scan for image line, take previous non-indented line.
        if [ -z "$service_name" ] && [ -n "$type_pat" ]; then
            service_name=$(grep -B1 -iE "^[[:space:]]+image:[[:space:]]*($type_pat)" "$compose_file"                 | grep -oE "^[[:space:]]+[A-Za-z0-9_.-]+:" | head -1 | sed 's/^[[:space:]]*//; s/:$//')
        fi

        if [ -n "$service_name" ]; then
            pick_reason="image-name fallback (legacy)"
        fi
    fi

    if [ -z "$service_name" ]; then
        log_message "ERROR: Could not determine webserver service name from compose file"
        log_message "Hint: set WEBSERVER_SERVICE=<service-name> or add label 'wp-backup: webserver' to the service."
        return 1
    fi

    log_message "Webserver service: $service_name (picked by: $pick_reason)"

    # Try to find a container_name, otherwise resolve via docker compose ps
    local container_line=$(grep -A 20 "^[[:space:]]*${service_name}:[[:space:]]*$" "$compose_file" \
        | grep -E "container_name:" | head -1)
    if [ -n "$container_line" ]; then
        WEBSERVER_CONTAINER=$(echo "$container_line" | sed 's/.*container_name:[[:space:]]*//' | tr -d '"' | tr -d "'" | xargs)
    fi

    if [ -z "$WEBSERVER_CONTAINER" ]; then
        if command -v docker &> /dev/null; then
            WEBSERVER_CONTAINER=$(docker compose -f "$compose_file" ps -q "$service_name" 2>/dev/null \
                | xargs -I {} docker ps --format "{{.Names}}" --filter "id={}" 2>/dev/null | head -1)
        fi
        if [ -z "$WEBSERVER_CONTAINER" ]; then
            WEBSERVER_CONTAINER="$service_name"
        fi
    fi

    log_message "Webserver container: $WEBSERVER_CONTAINER"
    return 0
}

# Function to determine the in-container config path for each webserver type
get_docker_config_path() {
    case "$1" in
        apache)
            # Debian-based apache image: /etc/apache2; httpd-based: /etc/httpd
            echo "/etc/apache2"
            ;;
        openlitespeed)
            echo "/usr/local/lsws/conf"
            ;;
        nginx)
            echo "/etc/nginx"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Function to copy a directory's contents (or a single file) to a destination
copy_source_to_dest() {
    local src="$1"
    local dest="$2"

    if [ -d "$src" ]; then
        cp -r "$src"/. "$dest"/ 2>/dev/null && return 0
        return 1
    fi

    if [ -f "$src" ]; then
        cp "$src" "$dest"/ 2>/dev/null && return 0
        return 1
    fi

    return 1
}

# Function to create config backup (Docker)
backup_config_docker() {
    local container="$1"
    local container_path="$2"
    local temp_dir="$3"

    log_message "Creating webserver config backup from Docker container '$container'..."

    if ! container_is_running "$container"; then
        log_message "ERROR: Webserver container '$container' is not running"
        log_message "Please start your Docker containers first"
        return 1
    fi

    # Verify the path exists inside the container
    if ! docker exec "$container" test -e "$container_path"; then
        log_message "ERROR: Path '$container_path' does not exist inside container '$container'"
        return 1
    fi

    # Use docker cp; create a tarball inside the container, then extract on host.
    # This is more reliable than docker cp for directories.
    if docker exec "$container" sh -c "tar -cf - -C '$(dirname "$container_path")' '$(basename "$container_path")'" \
            > "$temp_dir/config.tar" 2>/dev/null; then
        if [ -s "$temp_dir/config.tar" ]; then
            if tar -xf "$temp_dir/config.tar" -C "$temp_dir/files/" 2>/dev/null; then
                rm -f "$temp_dir/config.tar"
                log_message "Config copied successfully from container"
                local size=$(_dir_size "$temp_dir/files")
                log_message "Config size: $size"
                return 0
            else
                log_message "ERROR: Failed to extract config tarball"
                return 1
            fi
        else
            log_message "ERROR: Config tarball from container is empty"
            return 1
        fi
    else
        log_message "ERROR: Failed to read config from container '$container'"
        return 1
    fi
}

# Function to create config backup (Native)
backup_config_native() {
    local src_dir="$1"
    local temp_dir="$2"

    log_message "Creating webserver config backup from '$src_dir'..."

    if [ ! -d "$src_dir" ] && [ ! -f "$src_dir" ]; then
        log_message "ERROR: Config path '$src_dir' not found"
        return 1
    fi

    if copy_source_to_dest "$src_dir" "$temp_dir/files/"; then
        log_message "Config copied successfully"
        local size=$(_dir_size "$temp_dir/files")
        log_message "Config size: $size"
        return 0
    else
        log_message "ERROR: Failed to copy config from '$src_dir'"
        return 1
    fi
}

# Parse command line arguments
while getopts "f:o:e:h" opt; do
    case $opt in
        f)
            WEBSERVER_DIR="$OPTARG"
            ;;
        o)
            OUTPUT_DIR="$OPTARG"
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

# If -f is provided, validate and derive webserver type
if [ -n "$WEBSERVER_DIR" ]; then
    if [ ! -d "$WEBSERVER_DIR" ] && [ ! -f "$WEBSERVER_DIR" ]; then
        log_message "ERROR: Webserver directory does not exist: $WEBSERVER_DIR"
        exit 1
    fi

    WEBSERVER_DIR=$(cd "$(dirname "$WEBSERVER_DIR")" && pwd)/$(basename "$WEBSERVER_DIR")

    detected_type=$(detect_webservver_type_from_dir "$WEBSERVER_DIR")
    if [ -n "$detected_type" ]; then
        WEBSERVER_TYPE="$detected_type"
        log_message "Detected webserver type from -f path: $WEBSERVER_TYPE"
    fi
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

OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

# Detect environment (Docker or Native)
detect_docker_environment

# Resolve webserver type + source path
if [ "$IS_DOCKER" = true ]; then
    if ! detect_docker_webservver_info; then
        log_message "ERROR: Failed to detect Docker webserver configuration"
        exit 1
    fi
else
    if [ -z "$WEBSERVER_TYPE" ]; then
        detected_type=$(detect_native_webservver_type)
        if [ -z "$detected_type" ]; then
            log_message "ERROR: Could not auto-detect webserver type. Please use -f to specify the config path."
            exit 1
        fi
        WEBSERVER_TYPE="$detected_type"
        log_message "Detected webserver type: $WEBSERVER_TYPE"
    fi

    if [ -z "$WEBSERVER_DIR" ]; then
        WEBSERVER_DIR=$(get_native_config_dir "$WEBSERVER_TYPE")
        if [ -z "$WEBSERVER_DIR" ]; then
            log_message "ERROR: Could not resolve native config dir for $WEBSERVER_TYPE. Please use -f to specify the path."
            exit 1
        fi
        log_message "Using native config dir for $WEBSERVER_TYPE: $WEBSERVER_DIR"
    fi
fi

# Check dependencies
check_dependencies

# Generate timestamp and backup filename
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_FILENAME="${TIMESTAMP}_${WEBSERVER_TYPE}_config_backup.zip"
BACKUP_PATH="$OUTPUT_DIR/$BACKUP_FILENAME"

log_message "Starting Webserver Backup process"
log_message "Webserver type: $WEBSERVER_TYPE"
log_message "Source dir    : $WEBSERVER_DIR"
log_message "Output dir    : $OUTPUT_DIR"
log_message "Backup file   : $BACKUP_FILENAME"
log_message "Environment   : $([ "$IS_DOCKER" = true ] && echo "Docker ($WEBSERVER_CONTAINER)" || echo "Native")"
if [ -n "$EMAIL_TO" ]; then
    log_message "Email notification: $EMAIL_TO"
fi

# Initialize log file for email report
init_log_file
log_message "Log file initialized: $LOG_FILE"

# Create temporary directory
TEMP_DIR=$(mktemp -d)
mkdir -p "$TEMP_DIR/files"

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

# Create config backup
if [ "$IS_DOCKER" = true ]; then
    container_path=$(get_docker_config_path "$WEBSERVER_TYPE")
    if [ -z "$container_path" ]; then
        log_message "ERROR: No known config path for webserver type: $WEBSERVER_TYPE"
        exit 1
    fi
    log_message "Container config path: $container_path"
    if ! backup_config_docker "$WEBSERVER_CONTAINER" "$container_path" "$TEMP_DIR"; then
        log_message "ERROR: Docker config backup failed"
        exit 1
    fi
else
    if ! backup_config_native "$WEBSERVER_DIR" "$TEMP_DIR"; then
        log_message "ERROR: Native config backup failed"
        exit 1
    fi
fi

# Add a marker file describing the backup for restore/reference
cat > "$TEMP_DIR/files/.backup_info" <<EOF
webservver_type=${WEBSERVER_TYPE}
source_dir=${WEBSERVER_DIR}
container=${WEBSERVER_CONTAINER:-}
environment=$( [ "$IS_DOCKER" = true ] && echo "docker" || echo "native" )
timestamp=${TIMESTAMP}
host=$(hostname)
EOF

# Create final zip archive
log_message "Creating final backup archive..."
cd "$TEMP_DIR"

if [ ! -d "$(dirname "$BACKUP_PATH")" ]; then
    log_message "ERROR: Backup directory does not exist: $(dirname "$BACKUP_PATH")"
    exit 1
fi

# -X strips "extra attributes" (UID, GID, timestamps) so the archive is
# portable across hosts with different users — safe to restore on a fresh
# box without inheriting the source machine's owner.
zip_output=$(zip -rX "$BACKUP_PATH" . 2>&1)
if [ $? -eq 0 ]; then
    log_message "Backup completed successfully!"
    log_message "Backup file: $BACKUP_PATH"
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

log_message "Webserver Backup process completed"
log_message "Environment: $([ "$IS_DOCKER" = true ] && echo "Docker ($WEBSERVER_CONTAINER container)" || echo "Native ($WEBSERVER_TYPE)")"
exit 0