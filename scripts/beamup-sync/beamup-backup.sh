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

# Configuration
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${BEAMUP_BASE}/backup-${TIMESTAMP}"
FINAL_ARCHIVE="${BACKUP_DIR}/beamup-backup-${TIMESTAMP}.tar.xz"
CHECKSUM_FILE="checksums.sha256"

# Parse arguments
show_usage() {
    cat << EOF
Usage: beamup-backup [OPTIONS]

Create a backup of Dokku applications and system files.

OPTIONS:
    -v, --verbose       Enable verbose output
    -h, --help          Show this help message

EXAMPLES:
    beamup-backup
    beamup-backup --verbose
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_usage
            exit 1
            ;;
    esac
done

# Check root
check_root

# Initialize logging
LOG_FILE="${LOG_DIR}/backup-${TIMESTAMP}.log"
init_logging

log_info "Starting Beamup Backup Process"
if [ "$VERBOSE" = true ]; then
    log_info "Verbose mode enabled"
fi
log_verbose "Timestamp: ${TIMESTAMP}"
log_verbose "Log file: ${LOG_FILE}"

# Cleanup on error
cleanup_on_error() {
    if [ -d "$BACKUP_DIR" ]; then
        log_error "Backup failed, cleaning up temporary directory..."
        rm -rf "$BACKUP_DIR"
    fi
}

trap cleanup_on_error ERR

# Create backup directories
log_info "Creating backup directory..."
mkdir -p "$BEAMUP_BASE" || {
    log_error "Failed to create beamup base directory: ${BEAMUP_BASE}"
    exit 1
}

mkdir -p "$BACKUP_DIR" || {
    log_error "Failed to create backup directory: ${BACKUP_DIR}"
    exit 1
}

log_verbose "Backup directory created: ${BACKUP_DIR}"

# Create temporary working directory for files before archiving
TEMP_WORK_DIR="${BACKUP_DIR}/work"
mkdir -p "$TEMP_WORK_DIR"

# Backup Dokku authorized_keys
log_info "Backing up Dokku authorized_keys..."
if [ -f "/home/dokku/.ssh/authorized_keys" ]; then
    mkdir -p "${TEMP_WORK_DIR}/dokku-ssh"
    if [ "$VERBOSE" = true ]; then
        cp -v "/home/dokku/.ssh/authorized_keys" "${TEMP_WORK_DIR}/dokku-ssh/" 2>&1 | tee -a "$LOG_FILE" || {
            log_error "Failed to backup authorized_keys"
            exit 1
        }
    else
        cp "/home/dokku/.ssh/authorized_keys" "${TEMP_WORK_DIR}/dokku-ssh/" >> "$LOG_FILE" 2>&1 || {
            log_error "Failed to backup authorized_keys"
            exit 1
        }
    fi
    log_info "✓ Dokku authorized_keys backed up"
else
    log_warn "Dokku authorized_keys not found"
fi

# Backup Dokku app directories
log_info "Backing up Dokku app directories..."
if [ -d "/home/dokku" ]; then
    cd /home
    if [ "$VERBOSE" = true ]; then
        tar -cJv --exclude='**/cache/*' -f "${TEMP_WORK_DIR}/dokku-apps.tar.xz" dokku 2>&1 | tee -a "$LOG_FILE" || {
            log_error "Failed to backup Dokku app directories"
            exit 1
        }
    else
        tar -cJ --exclude='**/cache/*' -f "${TEMP_WORK_DIR}/dokku-apps.tar.xz" dokku >> "$LOG_FILE" 2>&1 || {
            log_error "Failed to backup Dokku app directories"
            exit 1
        }
    fi
    log_info "✓ Dokku app directories backed up"
else
    log_warn "Dokku directory not found"
fi

# Backup SSH host keys
log_info "Backing up SSH host keys..."
if [ -d "/etc/ssh" ]; then
    cd /etc/ssh
    if [ "$VERBOSE" = true ]; then
        tar -cJv -f "${TEMP_WORK_DIR}/ssh-host-keys.tar.xz" ssh_host_* 2>&1 | tee -a "$LOG_FILE" || {
            log_error "Failed to backup SSH host keys"
            exit 1
        }
    else
        tar -cJ -f "${TEMP_WORK_DIR}/ssh-host-keys.tar.xz" ssh_host_* >> "$LOG_FILE" 2>&1 || {
            log_error "Failed to backup SSH host keys"
            exit 1
        }
    fi
    log_info "✓ SSH host keys backed up"
else
    log_warn "SSH directory not found"
fi

# Backup cron jobs
log_info "Backing up cron jobs..."
CRON_FILES=()
[ -f "/etc/cron.daily/disk-usage-by-containers" ] && CRON_FILES+=("/etc/cron.daily/disk-usage-by-containers")
[ -f "/etc/cron.daily/df" ] && CRON_FILES+=("/etc/cron.daily/df")

if [ ${#CRON_FILES[@]} -gt 0 ]; then
    if [ "$VERBOSE" = true ]; then
        tar -cJv -f "${TEMP_WORK_DIR}/cron-jobs.tar.xz" "${CRON_FILES[@]}" 2>&1 | tee -a "$LOG_FILE" || {
            log_error "Failed to backup cron jobs"
            exit 1
        }
    else
        tar -cJ -f "${TEMP_WORK_DIR}/cron-jobs.tar.xz" "${CRON_FILES[@]}" >> "$LOG_FILE" 2>&1 || {
            log_error "Failed to backup cron jobs"
            exit 1
        }
    fi
    log_info "✓ Cron jobs backed up"
else
    log_warn "No cron job files found"
fi

# Generate checksums for all backed up files (excluding the checksum file itself)
log_info "Generating checksums..."
cd "$TEMP_WORK_DIR"
find . -type f ! -name "$CHECKSUM_FILE" -exec sha256sum {} \; > "$CHECKSUM_FILE" || {
    log_error "Failed to generate checksums"
    exit 1
}
log_info "✓ Checksums generated"
if [ "$VERBOSE" = true ]; then
    log_verbose "Checksum contents:"
    cat "$CHECKSUM_FILE" | tee -a "$LOG_FILE"
fi

# Create final archive
log_info "Creating final archive..."
cd "$TEMP_WORK_DIR"
if [ "$VERBOSE" = true ]; then
    tar -cJv -f "$FINAL_ARCHIVE" . 2>&1 | tee -a "$LOG_FILE" || {
        log_error "Failed to create final archive"
        exit 1
    }
else
    tar -cJ -f "$FINAL_ARCHIVE" . >> "$LOG_FILE" 2>&1 || {
        log_error "Failed to create final archive"
        exit 1
    }
fi
log_info "✓ Final archive created"

# Generate checksum for final archive
log_info "Generating archive checksum..."
FINAL_CHECKSUM="${FINAL_ARCHIVE}.sha256"
cd "$BACKUP_DIR"
sha256sum "$(basename "$FINAL_ARCHIVE")" > "$FINAL_CHECKSUM" || {
    log_error "Failed to generate final archive checksum"
    exit 1
}
log_info "✓ Archive checksum generated"
if [ "$VERBOSE" = true ]; then
    log_verbose "Final archive checksum:"
    cat "$FINAL_CHECKSUM" | tee -a "$LOG_FILE"
fi

# Clean up temporary work directory
log_verbose "Cleaning up temporary work directory..."
rm -rf "$TEMP_WORK_DIR"
log_verbose "Temporary files cleaned up"

# Summary
log_info "=========================================="
log_info "Backup completed successfully!"
log_info "=========================================="
log_info "Archive: ${FINAL_ARCHIVE}"
log_info "Size: $(du -h "$FINAL_ARCHIVE" | cut -f1)"
log_verbose "Checksum: ${FINAL_CHECKSUM}"
log_verbose "Log: ${LOG_FILE}"
log_info "=========================================="