#!/usr/bin/env bash

set -euo pipefail

# Defaults (can be overridden in config)
BEAMUP_BASE_DEFAULT="/var/backups/beamup"
LOCAL_ARCHIVE_DIR_DEFAULT="/var/backups/beamup/archives"
DOWNLOAD_DIR_DEFAULT="/var/backups/beamup/downloads"
LOG_DIR_DEFAULT="/var/log/beamup-sync"
CONFIG_FILE_DEFAULT="/etc/beamup/sync.conf"
LOCK_FILE_DEFAULT="/var/lock/beamup-sync.lock"
RETENTION_DAYS_DEFAULT="30"
BACKUP_ENCRYPTION_ENABLED_DEFAULT="false"
BACKUP_ENCRYPT_SSH_KEY_DEFAULT="/etc/beamup/keys/sync"
RSYNC_SSH_KEY_DEFAULT="/etc/beamup/keys/sync"

VERBOSE=false
LOG_FILE=""
LOCK_FD=""

log_ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
    local line="[INFO] $(log_ts) - $1"
    echo "$line"
    [ -n "$LOG_FILE" ] && echo "$line" >> "$LOG_FILE"
}

log_warn() {
    local line="[WARN] $(log_ts) - $1"
    echo "$line"
    [ -n "$LOG_FILE" ] && echo "$line" >> "$LOG_FILE"
}

log_error() {
    local line="[ERROR] $(log_ts) - $1"
    echo "$line" >&2
    [ -n "$LOG_FILE" ] && echo "$line" >> "$LOG_FILE"
}

log_debug() {
    local line="[DEBUG] $(log_ts) - $1"
    if [ "$VERBOSE" = true ]; then
        echo "$line"
    fi
    [ -n "$LOG_FILE" ] && echo "$line" >> "$LOG_FILE"
}

die() {
    log_error "$1"
    exit 1
}

require_root() {
    [ "$EUID" -eq 0 ] || die "This command must run as root"
}

as_bool() {
    case "${1:-}" in
        1|true|TRUE|True|yes|YES|Yes|y|Y|on|ON|On) echo "true" ;;
        *) echo "false" ;;
    esac
}

trim() {
    echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

split_csv() {
    local input="${1:-}"
    local part
    IFS=',' read -r -a _parts <<< "$input"
    for part in "${_parts[@]}"; do
        part="$(trim "$part")"
        [ -n "$part" ] && echo "$part"
    done
}

ensure_dir() {
    mkdir -p "$1" || die "Failed to create directory: $1"
}

load_config() {
    BEAMUP_BASE="${BEAMUP_BASE:-$BEAMUP_BASE_DEFAULT}"
    LOCAL_ARCHIVE_DIR="${LOCAL_ARCHIVE_DIR:-$LOCAL_ARCHIVE_DIR_DEFAULT}"
    DOWNLOAD_DIR="${DOWNLOAD_DIR:-$DOWNLOAD_DIR_DEFAULT}"
    LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
    CONFIG_FILE="${CONFIG_FILE:-$CONFIG_FILE_DEFAULT}"
    LOCK_FILE="${LOCK_FILE:-$LOCK_FILE_DEFAULT}"
    RETENTION_DAYS="${RETENTION_DAYS:-$RETENTION_DAYS_DEFAULT}"
    BACKUP_ENCRYPTION_ENABLED="${BACKUP_ENCRYPTION_ENABLED:-$BACKUP_ENCRYPTION_ENABLED_DEFAULT}"
    BACKUP_ENCRYPT_SSH_KEY="${BACKUP_ENCRYPT_SSH_KEY:-$BACKUP_ENCRYPT_SSH_KEY_DEFAULT}"

    ENABLED_REMOTES="${ENABLED_REMOTES:-}"

    FTP_ENABLED="${FTP_ENABLED:-false}"
    FTP_HOST="${FTP_HOST:-}"
    FTP_PORT="${FTP_PORT:-21}"
    FTP_USER="${FTP_USER:-}"
    FTP_PASSWORD="${FTP_PASSWORD:-}"
    FTP_REMOTE_PATH="${FTP_REMOTE_PATH:-/backups}"
    FTP_VERIFY_TLS="${FTP_VERIFY_TLS:-true}"

    S3_ENABLED="${S3_ENABLED:-false}"
    S3_BUCKET="${S3_BUCKET:-}"
    S3_REGION="${S3_REGION:-us-east-1}"
    S3_ACCESS_KEY="${S3_ACCESS_KEY:-}"
    S3_SECRET_KEY="${S3_SECRET_KEY:-}"
    S3_PREFIX="${S3_PREFIX:-}"
    S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"
    S3_VERIFY_SSL="${S3_VERIFY_SSL:-true}"
    S3_AUTO_CREATE_BUCKET="${S3_AUTO_CREATE_BUCKET:-true}"

    RSYNC_ENABLED="${RSYNC_ENABLED:-false}"
    RSYNC_MODE="${RSYNC_MODE:-ssh}"
    RSYNC_HOST="${RSYNC_HOST:-}"
    RSYNC_PORT="${RSYNC_PORT:-22}"
    RSYNC_USER="${RSYNC_USER:-}"
    RSYNC_REMOTE_PATH="${RSYNC_REMOTE_PATH:-/backups}"
    RSYNC_SSH_KEY="${RSYNC_SSH_KEY:-$RSYNC_SSH_KEY_DEFAULT}"
    RSYNC_PASSWORD="${RSYNC_PASSWORD:-}"

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    # normalize after source
    BEAMUP_BASE="${BEAMUP_BASE:-$BEAMUP_BASE_DEFAULT}"
    LOCAL_ARCHIVE_DIR="${LOCAL_ARCHIVE_DIR:-$LOCAL_ARCHIVE_DIR_DEFAULT}"
    DOWNLOAD_DIR="${DOWNLOAD_DIR:-$DOWNLOAD_DIR_DEFAULT}"
    LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
    CONFIG_FILE="${CONFIG_FILE:-$CONFIG_FILE_DEFAULT}"
    LOCK_FILE="${LOCK_FILE:-$LOCK_FILE_DEFAULT}"
    RETENTION_DAYS="${RETENTION_DAYS:-$RETENTION_DAYS_DEFAULT}"
    BACKUP_ENCRYPTION_ENABLED="${BACKUP_ENCRYPTION_ENABLED:-$BACKUP_ENCRYPTION_ENABLED_DEFAULT}"
    BACKUP_ENCRYPT_SSH_KEY="${BACKUP_ENCRYPT_SSH_KEY:-$BACKUP_ENCRYPT_SSH_KEY_DEFAULT}"
    RSYNC_MODE="${RSYNC_MODE:-ssh}"
    RSYNC_PORT="${RSYNC_PORT:-22}"
    S3_AUTO_CREATE_BUCKET="${S3_AUTO_CREATE_BUCKET:-true}"
}

require_config_file() {
    [ -f "$CONFIG_FILE" ] || die "Config not found: $CONFIG_FILE (run: beamup-sync config)"
}

init_log() {
    local action="${1:-sync}"
    ensure_dir "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/${action}-$(date +%Y%m%d_%H%M%S).log"
    touch "$LOG_FILE" || die "Cannot create log file: $LOG_FILE"
}

run_cmd() {
    if [ "$VERBOSE" = true ]; then
        log_debug "RUN: $*"
        "$@" 2>&1 | tee -a "$LOG_FILE"
    else
        "$@" >> "$LOG_FILE" 2>&1
    fi
}

acquire_lock() {
    if [ "$(as_bool "${BEAMUP_SKIP_LOCK:-false}")" = true ]; then
        return 0
    fi

    ensure_dir "$(dirname "$LOCK_FILE")"
    exec {LOCK_FD}>"$LOCK_FILE" || die "Cannot open lock file: $LOCK_FILE"
    flock -n "$LOCK_FD" || die "Another beamup-sync process is already running"
    echo "$$" 1>&"$LOCK_FD" || true
}

release_lock() {
    if [ -n "${LOCK_FD:-}" ]; then
        flock -u "$LOCK_FD" || true
        LOCK_FD=""
    fi
}

latest_local_archive() {
    [ -d "$LOCAL_ARCHIVE_DIR" ] || return 0
    find "$LOCAL_ARCHIVE_DIR" -maxdepth 1 -type f \
        \( -name 'beamup-backup-*.tar.xz' -o -name 'beamup-backup-*.tar.xz.age' \) | sort -r | head -n 1
}

list_local_archives() {
    [ -d "$LOCAL_ARCHIVE_DIR" ] || return 0
    find "$LOCAL_ARCHIVE_DIR" -maxdepth 1 -type f \
        \( -name 'beamup-backup-*.tar.xz' -o -name 'beamup-backup-*.tar.xz.age' \) | sort -r
}

checksum_path() {
    echo "$1.sha256"
}

verify_archive_checksum() {
    local archive="$1"
    local checksum
    checksum="$(checksum_path "$archive")"

    [ -f "$archive" ] || die "Archive not found: $archive"
    [ -f "$checksum" ] || die "Checksum not found: $checksum"

    (
        cd "$(dirname "$archive")"
        sha256sum -c "$(basename "$checksum")"
    ) >> "$LOG_FILE" 2>&1
}

prune_old_archives() {
    [ -d "$LOCAL_ARCHIVE_DIR" ] || return 0
    [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || return 0
    [ "$RETENTION_DAYS" -gt 0 ] || return 0

    while IFS= read -r old; do
        [ -n "$old" ] || continue
        rm -f "$old" "$(checksum_path "$old")"
        log_info "Pruned old archive: $(basename "$old")"
    done < <(find "$LOCAL_ARCHIVE_DIR" -maxdepth 1 -type f \
        \( -name 'beamup-backup-*.tar.xz' -o -name 'beamup-backup-*.tar.xz.age' \) \
        -mtime +"$((RETENTION_DAYS - 1))" | sort)
}

confirm_exact_yes() {
    local prompt="${1:-Type yes to continue}"
    local answer=""
    read -r -p "$prompt [yes]: " answer
    [ "$answer" = "yes" ]
}

enabled_remotes_csv() {
    if [ -n "$ENABLED_REMOTES" ]; then
        echo "$ENABLED_REMOTES"
        return
    fi

    local out=""
    [ "$(as_bool "$FTP_ENABLED")" = true ] && out="${out},ftp"
    [ "$(as_bool "$S3_ENABLED")" = true ] && out="${out},s3"
    [ "$(as_bool "$RSYNC_ENABLED")" = true ] && out="${out},rsync"
    echo "${out#,}"
}

is_encrypted_archive() {
    case "$1" in
        *.tar.xz.age) return 0 ;;
        *) return 1 ;;
    esac
}

backup_encryption_enabled() {
    [ "$(as_bool "$BACKUP_ENCRYPTION_ENABLED")" = true ]
}

require_backup_encryption_prereqs() {
    backup_encryption_enabled || return 0
    require_backup_encryption_key
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is required when BACKUP_ENCRYPTION_ENABLED=true"
}

require_backup_encryption_key() {
    command -v age >/dev/null 2>&1 || die "age is required for encrypted backups"
    [ -n "$BACKUP_ENCRYPT_SSH_KEY" ] || die "BACKUP_ENCRYPT_SSH_KEY is empty"
    [ -f "$BACKUP_ENCRYPT_SSH_KEY" ] || die "BACKUP_ENCRYPT_SSH_KEY not found: $BACKUP_ENCRYPT_SSH_KEY"
}

backup_encrypt_recipient_from_key() {
    local key_path="${1:-$BACKUP_ENCRYPT_SSH_KEY}"
    local recipient=""

    recipient="$(ssh-keygen -y -f "$key_path" </dev/null 2>> "$LOG_FILE" || true)"
    recipient="$(trim "$recipient")"
    [ -n "$recipient" ] || die "Failed to derive SSH public key from BACKUP_ENCRYPT_SSH_KEY: $key_path"

    case "$recipient" in
        ssh-*) ;;
        *) die "Derived key is not a valid SSH public key from: $key_path" ;;
    esac

    echo "$recipient"
}
