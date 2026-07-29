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

FORCE=false
ARCHIVE_PATH=""

usage() {
    cat <<USAGE
Usage: beamup-restore [OPTIONS] [ARCHIVE_PATH]

Options:
  -f, --force             Skip confirmation
  -v, --verbose           Verbose output
  -h, --help              Show help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [ -z "$ARCHIVE_PATH" ]; then
                ARCHIVE_PATH="$1"
                shift
            else
                die "Unexpected argument: $1"
            fi
            ;;
    esac
done

require_root
load_config
init_log "restore"
acquire_lock
trap release_lock EXIT

if [ -z "$ARCHIVE_PATH" ]; then
    ARCHIVE_PATH="$(latest_local_archive)"
fi
[ -n "$ARCHIVE_PATH" ] || die "No local archive found"
[ -f "$ARCHIVE_PATH" ] || die "Archive not found: $ARCHIVE_PATH"

log_info "Restore source: $ARCHIVE_PATH"
verify_archive_checksum "$ARCHIVE_PATH" || die "Checksum verification failed"

if [ "$FORCE" != true ]; then
    echo ""
    echo "This will overwrite files from backup archive."
    if ! confirm_exact_yes "Continue restore?"; then
        log_info "Restore cancelled"
        exit 0
    fi
fi

tmp_dir="$(mktemp -d /tmp/beamup-restore.XXXXXX)"
cleanup_tmp() {
    rm -rf "$tmp_dir"
}
trap 'cleanup_tmp; release_lock' EXIT

extract_archive="$ARCHIVE_PATH"
if is_encrypted_archive "$ARCHIVE_PATH"; then
    require_backup_encryption_key
    extract_archive="${tmp_dir}/archive.tar.xz"
    log_info "Decrypting archive with SSH key: $BACKUP_ENCRYPT_SSH_KEY"
    if [ "$VERBOSE" = true ]; then
        age -d -i "$BACKUP_ENCRYPT_SSH_KEY" -o "$extract_archive" "$ARCHIVE_PATH" 2>&1 | tee -a "$LOG_FILE"
    else
        age -d -i "$BACKUP_ENCRYPT_SSH_KEY" -o "$extract_archive" "$ARCHIVE_PATH" >> "$LOG_FILE" 2>&1
    fi
fi

log_info "Extracting archive"
if [ "$VERBOSE" = true ]; then
    tar -xJvf "$extract_archive" -C "$tmp_dir" 2>&1 | tee -a "$LOG_FILE"
else
    tar -xJf "$extract_archive" -C "$tmp_dir" >> "$LOG_FILE" 2>&1
fi

# Validate that mandatory restore content exists in the archive.
[ -f "$tmp_dir/home/dokku/.ssh/authorized_keys" ] || die "Backup archive is missing /home/dokku/.ssh/authorized_keys"
[ -d "$tmp_dir/home/dokku" ] || die "Backup archive is missing /home/dokku"
[ -d "$tmp_dir/etc/cron.daily" ] || die "Backup archive is missing /etc/cron.daily"
shopt -s nullglob
restored_ssh_keys=("$tmp_dir"/etc/ssh/ssh_host_*)
shopt -u nullglob
[ ${#restored_ssh_keys[@]} -gt 0 ] || die "Backup archive is missing /etc/ssh/ssh_host_*"

declare -a restored_apps=()
while IFS= read -r restored_app_dir; do
    app_name="$(basename "$restored_app_dir")"
    # Skip hidden directories and known non-app folders.
    case "$app_name" in
        .*|ENV|HOSTNAME|VHOST) continue ;;
    esac
    restored_apps+=("$app_name")
done < <(find "$tmp_dir/home/dokku" -mindepth 1 -maxdepth 1 -type d | sort)

log_info "Applying files"

if command -v dokku >/dev/null 2>&1; then
    declare -A existing_apps=()
    mapfile -t dokku_apps_before < <(dokku apps:list --quiet 2>> "$LOG_FILE" || true)
    for app in "${dokku_apps_before[@]}"; do
        [ -n "$app" ] || continue
        existing_apps["$app"]=1
    done

    # Create each app before restoring /home/dokku app data.
    for app_name in "${restored_apps[@]}"; do
        if [ -z "${existing_apps[$app_name]:-}" ]; then
            log_info "Creating missing Dokku app: $app_name"
            dokku_create_output=""
            if dokku_create_output=$(run_cmd dokku apps:create "$app_name" 2>&1); then
                existing_apps["$app_name"]=1
            else
                log_warn "Failed to create Dokku app: $app_name. Reason: $dokku_create_output"
            fi
        fi
    done
fi

# Restore Dokku app directories first (do not copy .ssh).
if [ -d "$tmp_dir/home/dokku" ]; then
    log_info "Restoring /home/dokku (excluding .ssh)"
    mkdir -p /home/dokku
    rsync -a --exclude='.ssh' "$tmp_dir/home/dokku/" /home/dokku/
else
    log_warn "/home/dokku not found in backup"
fi

# Restore authorized_keys.
log_info "Restoring /home/dokku/.ssh/authorized_keys"
mkdir -p /home/dokku/.ssh
cp "$tmp_dir/home/dokku/.ssh/authorized_keys" /home/dokku/.ssh/authorized_keys

# Restore SSH host keys and restart sshd.
log_info "Restoring /etc/ssh/ssh_host_*"
for key in "${restored_ssh_keys[@]}"; do
    cp "$key" /etc/ssh/
done
for key in /etc/ssh/ssh_host_*; do
    [ -f "$key" ] || continue
    chown root:root "$key"
    case "$key" in
        *.pub) chmod 644 "$key" ;;
        *) chmod 600 "$key" ;;
    esac
done

if command -v systemctl >/dev/null 2>&1; then
    if run_cmd systemctl restart sshd; then
        log_info "Restarted sshd service"
    elif run_cmd systemctl restart ssh; then
        log_info "Restarted ssh service"
    else
        log_warn "Failed to restart sshd/ssh service after restoring host keys"
    fi
fi

# Restore cron jobs.
log_info "Restoring /etc/cron.daily"
rsync -a "$tmp_dir/etc/cron.daily/" /etc/cron.daily/

# Final ownership and permissions.
run_cmd chown -R dokku:dokku /home/dokku
if [ -d /home/dokku/.ssh ]; then
    run_cmd chmod 700 /home/dokku/.ssh
fi
if [ -f /home/dokku/.ssh/authorized_keys ]; then
    run_cmd chmod 640 /home/dokku/.ssh/authorized_keys
fi

log_info "Rebuilding dokku apps"
if ! run_cmd dokku ps:rebuild --all --parallel 3; then
    log_warn "dokku rebuild failed"
fi

log_info "Restore completed"
log_info "Log: $LOG_FILE"
