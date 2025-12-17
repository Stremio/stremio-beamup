#!/bin/bash

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
if [ -f "${SCRIPT_DIR}/beamup-common.sh" ]; then
    source "${SCRIPT_DIR}/beamup-common.sh"
elif [ -f "/usr/local/lib/beamup/beamup-common" ]; then
    source "/usr/local/lib/beamup/beamup-common"
else
    echo "Error: beamup-common.sh not found" >&2
    exit 1
fi

# Parse arguments
BACKUP_FILE=""
FORCE=false

show_usage() {
    cat << EOF
Usage: beamup-restore [OPTIONS] [BACKUP_FILE]

Restore from a Dokku backup archive.

OPTIONS:
    -f, --force         Skip confirmation prompts
    -v, --verbose       Enable verbose output
    -h, --help          Show this help message

ARGUMENTS:
    BACKUP_FILE         Path to backup archive (optional, will use latest if not specified)

EXAMPLES:
    beamup-restore
    beamup-restore /tmp/beamup-backup/backup-20231028_143022/beamup-backup-20231028_143022.tar.xz
    beamup-restore --force --verbose
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--force)
            FORCE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            BACKUP_FILE="$1"
            shift
            ;;
    esac
done

# Check root
check_root

# Initialize logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/restore-${TIMESTAMP}.log"
init_logging

log_info "Starting Beamup Restore Process"

# Determine backup file to restore
if [ -z "$BACKUP_FILE" ]; then
    log_info "No backup file specified, searching for latest backup..."
    BACKUP_FILE=$(get_latest_backup)
    
    if [ -z "$BACKUP_FILE" ]; then
        log_error "No backups found in ${BEAMUP_BASE}"
        exit 1
    fi
    
    log_info "Found latest backup: $BACKUP_FILE"
fi

# Verify backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
    log_error "Backup file not found: $BACKUP_FILE"
    exit 1
fi

# Verify backup integrity
verify_backup "$BACKUP_FILE" || {
    log_error "Backup integrity verification failed"
    exit 1
}

# Show warning and get confirmation
if [ "$FORCE" != true ]; then
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                        ⚠️  WARNING ⚠️                          ║${NC}"
    echo -e "${RED}╠════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║  This operation will OVERWRITE existing system files:         ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║  • Dokku authorized_keys                                       ║${NC}"
    echo -e "${RED}║  • Dokku app directories                                       ║${NC}"
    echo -e "${RED}║  • SSH host keys                                               ║${NC}"
    echo -e "${RED}║  • Cron jobs                                                   ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║  This action is IRREVERSIBLE and may cause service downtime.  ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║  Backup file: $(basename "$BACKUP_FILE")${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    if ! confirm_action "Are you absolutely sure you want to proceed?"; then
        log_info "Restore cancelled by user"
        exit 0
    fi
    
    echo ""
    if ! confirm_action "Type 'yes' to confirm (not just 'y')"; then
        log_info "Restore cancelled by user"
        exit 0
    fi
fi

# Create temporary extraction directory
TEMP_EXTRACT_DIR=$(mktemp -d -p /tmp beamup-restore.XXXXXX)
cleanup_temp() {
    if [ -d "$TEMP_EXTRACT_DIR" ]; then
        log_verbose "Cleaning up temporary extraction directory..."
        rm -rf "$TEMP_EXTRACT_DIR"
    fi
}
trap cleanup_temp EXIT

# Extract backup archive
log_info "Extracting backup archive..."
if [ "$VERBOSE" = true ]; then
    tar -xJvf "$BACKUP_FILE" -C "$TEMP_EXTRACT_DIR" 2>&1 | tee -a "$LOG_FILE"
else
    tar -xJf "$BACKUP_FILE" -C "$TEMP_EXTRACT_DIR" >> "$LOG_FILE" 2>&1
fi
log_info "✓ Backup extracted"

# Verify checksums of extracted files
if [ -f "${TEMP_EXTRACT_DIR}/checksums.sha256" ]; then
    log_info "Verifying extracted files..."
    cd "$TEMP_EXTRACT_DIR"
    if sha256sum -c checksums.sha256 >> "$LOG_FILE" 2>&1; then
        log_info "✓ All files verified"
    else
        log_error "File verification failed"
        exit 1
    fi
fi

# Restore Dokku authorized_keys
if [ -f "${TEMP_EXTRACT_DIR}/dokku-ssh/authorized_keys" ]; then
    log_info "Restoring Dokku authorized_keys..."
    mkdir -p /home/dokku/.ssh
    cp "${TEMP_EXTRACT_DIR}/dokku-ssh/authorized_keys" /home/dokku/.ssh/authorized_keys
    chown dokku:dokku /home/dokku/.ssh/authorized_keys
    chmod 600 /home/dokku/.ssh/authorized_keys
    log_info "✓ Dokku authorized_keys restored"
else
    log_warn "Dokku authorized_keys not found in backup"
fi

# Restore Dokku apps
if [ -f "${TEMP_EXTRACT_DIR}/dokku-apps.tar.xz" ]; then
    log_info "Restoring Dokku app directories..."
    # Extract once to a temporary location
    DOKKU_RESTORE_TEMP=$(mktemp -d -p ${TEMP_EXTRACT_DIR} dokku.XXXXXX)
    cd "$DOKKU_RESTORE_TEMP"
    if [ "$VERBOSE" = true ]; then
        tar -xJvf "${TEMP_EXTRACT_DIR}/dokku-apps.tar.xz" 2>&1 | tee -a "$LOG_FILE"
    else
        tar -xJf "${TEMP_EXTRACT_DIR}/dokku-apps.tar.xz" >> "$LOG_FILE" 2>&1
    fi

    # Create each Dokku app before restoring data
    log_info "Creating Dokku apps..."
    if [ -d "${DOKKU_RESTORE_TEMP}/dokku" ]; then
        for app_dir in "${DOKKU_RESTORE_TEMP}/dokku"/*; do
            if [ -d "$app_dir" ]; then
                app_name=$(basename "$app_dir")
                # Skip special directories
                if [[ "$app_name" != "VHOST" && "$app_name" != "ENV" && "$app_name" != "HOSTNAME" && "$app_name" != ".ssh" ]]; then
                    if dokku apps:list | grep -q "^${app_name}$"; then
                        log_verbose "App already exists: $app_name"
                    else
                        log_info "Creating app: $app_name"
                        dokku apps:create "$app_name" >> "$LOG_FILE" 2>&1 || {
                            log_warn "Failed to create app: $app_name"
                        }
                    fi
                fi
            fi
        done
        log_info "✓ Dokku apps created"
    fi

    # Now copy the app directories (excluding .ssh which is handled separately)
    log_info "Copying app data..."
    if [ -d "${DOKKU_RESTORE_TEMP}/dokku" ]; then
        rsync -a --exclude='.ssh' "${DOKKU_RESTORE_TEMP}/dokku/" /home/dokku/
    fi

    # Set correct ownership for all Dokku files
    log_info "Setting Dokku file permissions..."
    chown -R dokku:dokku /home/dokku
    log_info "✓ Dokku app directories restored"

    # Rebuild all Dokku apps in parallel (2 at a time)
    log_info "Rebuilding all Dokku apps in parallel..."
    dokku ps:rebuild --all --parallel 5 >> "$LOG_FILE" 2>&1
    log_info "✓ Dokku apps rebuild done"

    # Cleanup temporary directory
    rm -rf "$DOKKU_RESTORE_TEMP"
else
    log_warn "Dokku apps archive not found in backup"
fi

# Restore SSH host keys
if [ -f "${TEMP_EXTRACT_DIR}/ssh-host-keys.tar.xz" ]; then
    log_info "Restoring SSH host keys..."
    cd /etc/ssh
    if [ "$VERBOSE" = true ]; then
        tar -xJvf "${TEMP_EXTRACT_DIR}/ssh-host-keys.tar.xz" 2>&1 | tee -a "$LOG_FILE"
    else
        tar -xJf "${TEMP_EXTRACT_DIR}/ssh-host-keys.tar.xz" >> "$LOG_FILE" 2>&1
    fi
    log_info "✓ SSH host keys restored"
    log_warn "SSH service restart may be required"
else
    log_warn "SSH host keys archive not found in backup"
fi

# Restore cron jobs
if [ -f "${TEMP_EXTRACT_DIR}/cron-jobs.tar.xz" ]; then
    log_info "Restoring cron jobs..."
    cd /
    if [ "$VERBOSE" = true ]; then
        tar -xJvf "${TEMP_EXTRACT_DIR}/cron-jobs.tar.xz" 2>&1 | tee -a "$LOG_FILE"
    else
        tar -xJf "${TEMP_EXTRACT_DIR}/cron-jobs.tar.xz" >> "$LOG_FILE" 2>&1
    fi
    log_info "✓ Cron jobs restored"
else
    log_warn "Cron jobs archive not found in backup"
fi

# Summary
log_success "=========================================="
log_success "Restore completed successfully!"
log_success "=========================================="
log_info "Restored from: $BACKUP_FILE"
log_info "Log file: ${LOG_FILE}"
log_success "=========================================="