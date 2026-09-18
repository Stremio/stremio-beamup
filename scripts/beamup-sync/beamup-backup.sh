#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/beamup-common.sh" ]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/beamup-common.sh"
elif [ -f "/usr/local/lib/beamup/beamup-common" ]; then
    # shellcheck disable=SC1091
    source "/usr/local/lib/beamup/beamup-common"
else
    echo "beamup-common not found" >&2
    exit 1
fi

ARCHIVE_NAME=""

usage() {
    cat <<USAGE
Usage: beamup-backup [OPTIONS]

Options:
  -v, --verbose         Verbose output
  -n, --name NAME       Archive name (without extension)
  -h, --help            Show help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -n|--name)
            shift
            [ $# -gt 0 ] || die "Missing value for --name"
            ARCHIVE_NAME="$1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

require_root
load_config
init_log "backup"
acquire_lock
trap release_lock EXIT

ensure_dir "$LOCAL_ARCHIVE_DIR"

if [ -z "$ARCHIVE_NAME" ]; then
    ARCHIVE_NAME="beamup-backup-$(date +%Y%m%d_%H%M%S)"
fi
ARCHIVE_NAME="${ARCHIVE_NAME%.tar.xz.age}"
ARCHIVE_NAME="${ARCHIVE_NAME%.tar.xz}"
ARCHIVE_PLAIN_PATH="${LOCAL_ARCHIVE_DIR}/${ARCHIVE_NAME}.tar.xz"
ARCHIVE_PATH="$ARCHIVE_PLAIN_PATH"
if backup_encryption_enabled; then
    require_backup_encryption_prereqs
    ARCHIVE_PATH="${ARCHIVE_PLAIN_PATH}.age"
fi
CHECKSUM_PATH="$(checksum_path "$ARCHIVE_PATH")"

# Mandatory backup set:
# - Dokku authorized_keys
# - Dokku app directories
# - SSH host keys
# - Cron jobs
required_paths=(
    "/home/dokku/.ssh/authorized_keys"
    "/home/dokku"
    "/etc/cron.daily"
)

selected=()
declare -A seen=()

for p in "${required_paths[@]}"; do
    [ -e "$p" ] || die "Required backup path is missing: $p"
    rel="${p#/}"
    if [ -z "${seen[$rel]:-}" ]; then
        selected+=("$rel")
        seen[$rel]=1
    fi
done

# Include /etc/crontab when present.
if [ -f "/etc/crontab" ]; then
    rel="etc/crontab"
    if [ -z "${seen[$rel]:-}" ]; then
        selected+=("$rel")
        seen[$rel]=1
    fi
fi

# Require at least one SSH host key and include all present keys.
shopt -s nullglob
ssh_host_keys=(/etc/ssh/ssh_host_*)
shopt -u nullglob
[ ${#ssh_host_keys[@]} -gt 0 ] || die "Required SSH host keys are missing under /etc/ssh/ssh_host_*"

for key in "${ssh_host_keys[@]}"; do
    rel="${key#/}"
    if [ -z "${seen[$rel]:-}" ]; then
        selected+=("$rel")
        seen[$rel]=1
    fi
done

log_info "Creating archive: $(basename "$ARCHIVE_PLAIN_PATH")"
tar_excludes=(
    "--exclude=home/dokku/*/cache"
    "--exclude=home/dokku/*/cache/*"
)
if [ "$VERBOSE" = true ]; then
    for i in "${selected[@]}"; do
        log_debug "include: /$i"
    done
    tar -C / -cJvf "$ARCHIVE_PLAIN_PATH" "${tar_excludes[@]}" "${selected[@]}" 2>&1 | tee -a "$LOG_FILE"
else
    tar -C / -cJf "$ARCHIVE_PLAIN_PATH" "${tar_excludes[@]}" "${selected[@]}" >> "$LOG_FILE" 2>&1
fi

if backup_encryption_enabled; then
    recipient="$(backup_encrypt_recipient_from_key "$BACKUP_ENCRYPT_SSH_KEY")"
    log_info "Encrypting archive with SSH key: $BACKUP_ENCRYPT_SSH_KEY"
    encrypt_cmd=(age -r "$recipient" -o "$ARCHIVE_PATH" "$ARCHIVE_PLAIN_PATH")
    if [ "$VERBOSE" = true ]; then
        if ! "${encrypt_cmd[@]}" 2>&1 | tee -a "$LOG_FILE"; then
            rm -f "$ARCHIVE_PATH" "$ARCHIVE_PLAIN_PATH"
            die "Failed to encrypt archive"
        fi
    else
        if ! "${encrypt_cmd[@]}" >> "$LOG_FILE" 2>&1; then
            rm -f "$ARCHIVE_PATH" "$ARCHIVE_PLAIN_PATH"
            die "Failed to encrypt archive"
        fi
    fi
    rm -f "$ARCHIVE_PLAIN_PATH"
fi

(
    cd "$LOCAL_ARCHIVE_DIR"
    sha256sum "$(basename "$ARCHIVE_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

prune_old_archives

log_info "Archive: $ARCHIVE_PATH"
log_info "Checksum: $CHECKSUM_PATH"
log_info "Log: $LOG_FILE"
