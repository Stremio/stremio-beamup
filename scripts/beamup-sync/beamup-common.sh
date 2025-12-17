#!/bin/bash

# beamup-common.sh - Shared functions and variables for beamup scripts

# Configuration
BEAMUP_BASE="/tmp/beamup-backup"
LOG_DIR="/var/log/beamup-backup"
CONFIG_DIR="/etc/beamup"
CONFIG_FILE="${CONFIG_DIR}/sync.conf"
LOCK_FILE="/var/run/beamup-sync.lock"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global verbose flag
VERBOSE=false

# Logging functions
log_info() {
    local msg="[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo -e "${GREEN}${msg}${NC}"
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

log_verbose() {
    local msg="[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    if [ "$VERBOSE" = true ]; then
        echo -e "${NC}${msg}${NC}"
    fi
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

log_error() {
    local msg="[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo -e "${RED}${msg}${NC}" >&2
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

log_warn() {
    local msg="[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo -e "${YELLOW}${msg}${NC}"
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

log_success() {
    local msg="[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo -e "${GREEN}${msg}${NC}"
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Create lock file
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            log_error "Another beamup process is already running (PID: $pid)"
            exit 1
        else
            log_warn "Stale lock file found, removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

# Release lock file
release_lock() {
    rm -f "$LOCK_FILE"
}

# Parse INI config file
parse_config() {
    local config_file="$1"
    local section=""
    
    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi
    
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        
        # Detect section
        if [[ "$key" =~ ^\[(.*)\] ]]; then
            section="${BASH_REMATCH[1]}"
            continue
        fi
        
        # Parse key-value pairs
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        # Create variable name: SECTION_KEY
        if [ -n "$section" ]; then
            declare -g "${section}_${key}=${value}"
        fi
    done < "$config_file"
}

# Initialize logging
init_logging() {
    mkdir -p "$LOG_DIR" || {
        echo "Failed to create log directory: ${LOG_DIR}" >&2
        exit 1
    }
    
    # Set up log rotation config if it doesn't exist
    local logrotate_conf="/etc/logrotate.d/beamup-backup"
    if [ ! -f "$logrotate_conf" ]; then
        cat > "$logrotate_conf" << 'EOF'
/var/log/beamup-backup/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
}
EOF
        log_verbose "Created logrotate configuration at ${logrotate_conf}"
    fi
}

# List all backups in beamup directory
list_local_backups() {
    if [ ! -d "$BEAMUP_BASE" ]; then
        return 0
    fi
    
    find "$BEAMUP_BASE" -maxdepth 2 -name "*.tar.xz" -type f 2>/dev/null | sort -r
}

# Get latest local backup
get_latest_backup() {
    list_local_backups | head -n 1
}

# Extract timestamp from backup filename
extract_timestamp() {
    local filename="$1"
    echo "$filename" | grep -oP '\d{8}_\d{6}' || echo ""
}

# Verify backup integrity
verify_backup() {
    local backup_file="$1"
    local checksum_file="${backup_file}.sha256"
    
    if [ ! -f "$checksum_file" ]; then
        log_error "Checksum file not found: $checksum_file"
        return 1
    fi
    
    log_info "Verifying backup integrity..."
    cd "$(dirname "$backup_file")"
    if sha256sum -c "$(basename "$checksum_file")" > /dev/null 2>&1; then
        log_success "Backup integrity verified"
        return 0
    else
        log_error "Backup integrity check failed"
        return 1
    fi
}

# Confirm action with user
confirm_action() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -r -p "$prompt" response
    response=${response:-$default}
    
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$(( bytes / 1024 ))KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$(( bytes / 1048576 ))MB"
    else
        echo "$(( bytes / 1073741824 ))GB"
    fi
}