#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${SCRIPT_DIR}/beamup-common.sh" ]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/beamup-common.sh"
    BACKUP_SCRIPT="${SCRIPT_DIR}/beamup-backup.sh"
    RESTORE_SCRIPT="${SCRIPT_DIR}/beamup-restore.sh"
elif [ -f "/usr/local/lib/beamup/beamup-common" ]; then
    # shellcheck disable=SC1091
    source "/usr/local/lib/beamup/beamup-common"
    BACKUP_SCRIPT="/usr/local/lib/beamup/beamup-backup"
    RESTORE_SCRIPT="/usr/local/lib/beamup/beamup-restore"
else
    echo "beamup-common not found" >&2
    exit 1
fi

COMMAND="${1:-}"
[ -n "$COMMAND" ] && shift || true

USE_FTP=false
USE_S3=false
USE_RSYNC=false
FORCE=false
AUTO_RESTORE=false
PUSH_ALL=false
USE_LATEST=false
ARG_VALUE=""

declare -a SELECTED_REMOTES=()

usage() {
    cat <<USAGE
Usage: beamup-sync <command> [options]

Commands:
  config                Create/update /etc/beamup/sync.conf
  verify                Validate config + dependencies
  backup                Create local backup archive
  push                  Push local archive(s) to remote(s)
  pull <name|--latest>  Pull archive from remote(s)
  list                  List remote archives
  restore [archive]     Restore local archive (latest if omitted)

Common options:
  -v, --verbose         Verbose output
  -h, --help            Show this help

Remote selection options (push/pull/list):
  --ftp --s3 --rsync

Other options:
  -f, --force           push: run backup first; restore: skip confirm
  -a, --all             push all local archives (default latest only)
  -r, --restore         pull then auto-restore
  --latest              pull latest backup name from remote
USAGE
}

require_command() {
    case "$COMMAND" in
        config|verify|backup|push|pull|list|restore)
            ;;
        -h|--help|"")
            usage
            exit 0
            ;;
        *)
            usage
            die "Unknown command: $COMMAND"
            ;;
    esac
}

parse_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ftp)
                USE_FTP=true
                shift
                ;;
            --s3)
                USE_S3=true
                shift
                ;;
            --rsync)
                USE_RSYNC=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -f|--force)
                FORCE=true
                shift
                ;;
            -a|--all)
                PUSH_ALL=true
                shift
                ;;
            -r|--restore)
                AUTO_RESTORE=true
                shift
                ;;
            --latest)
                USE_LATEST=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                if [ -z "$ARG_VALUE" ]; then
                    ARG_VALUE="$1"
                    shift
                else
                    die "Unexpected argument: $1"
                fi
                ;;
        esac
    done
}

normalize_archive_name() {
    local name="${1:-}"
    name="${name%$'\r'}"
    name="${name##*/}"
    echo "$name"
}

is_archive_name() {
    case "$1" in
        *.tar.xz|*.tar.xz.age) return 0 ;;
        *) return 1 ;;
    esac
}

list_archive_names_from_stdin() {
    local raw name
    while IFS= read -r raw; do
        name="$(normalize_archive_name "$raw")"
        if is_archive_name "$name"; then
            echo "$name"
        fi
    done | sort -u
}

build_selected_remotes() {
    SELECTED_REMOTES=()

    if [ "$USE_FTP" = true ] || [ "$USE_S3" = true ] || [ "$USE_RSYNC" = true ]; then
        [ "$USE_FTP" = true ] && SELECTED_REMOTES+=("ftp")
        [ "$USE_S3" = true ] && SELECTED_REMOTES+=("s3")
        [ "$USE_RSYNC" = true ] && SELECTED_REMOTES+=("rsync")
    else
        local remotes_csv
        remotes_csv="$(enabled_remotes_csv)"
        while IFS= read -r r; do
            [ -n "$r" ] && SELECTED_REMOTES+=("$r")
        done < <(split_csv "$remotes_csv")
    fi

    [ ${#SELECTED_REMOTES[@]} -gt 0 ] || die "No remotes selected"
}

run_backup_script() {
    [ -x "$BACKUP_SCRIPT" ] || die "Backup script not found: $BACKUP_SCRIPT"
    if [ "$VERBOSE" = true ]; then
        BEAMUP_SKIP_LOCK=true "$BACKUP_SCRIPT" --verbose
    else
        BEAMUP_SKIP_LOCK=true "$BACKUP_SCRIPT"
    fi
}

run_restore_script() {
    [ -x "$RESTORE_SCRIPT" ] || die "Restore script not found: $RESTORE_SCRIPT"

    local -a cmd=("$RESTORE_SCRIPT")
    [ "$FORCE" = true ] && cmd+=("--force")
    [ "$VERBOSE" = true ] && cmd+=("--verbose")
    [ -n "${1:-}" ] && cmd+=("$1")

    BEAMUP_SKIP_LOCK=true "${cmd[@]}"
}

ftp_ssl_cfg() {
    if [ "$(as_bool "$FTP_VERIFY_TLS")" = true ]; then
        echo "set ftp:ssl-allow yes; set ssl:verify-certificate yes;"
    else
        echo "set ftp:ssl-allow yes; set ssl:verify-certificate no;"
    fi
}

ftp_push() {
    local archive="$1"
    local checksum="$2"
    [ "$(as_bool "$FTP_ENABLED")" = true ] || return 1

    command -v lftp >/dev/null 2>&1 || die "lftp not installed"
    local host="${FTP_HOST}:${FTP_PORT}"
    local ssl
    ssl="$(ftp_ssl_cfg)"

    if [ "$VERBOSE" = true ]; then
        lftp -u "${FTP_USER},${FTP_PASSWORD}" "$host" -e "${ssl} mkdir -p ${FTP_REMOTE_PATH}; put -O ${FTP_REMOTE_PATH} ${archive}; put -O ${FTP_REMOTE_PATH} ${checksum}; bye"
    else
        lftp -u "${FTP_USER},${FTP_PASSWORD}" "$host" -e "${ssl} mkdir -p ${FTP_REMOTE_PATH}; put -O ${FTP_REMOTE_PATH} ${archive}; put -O ${FTP_REMOTE_PATH} ${checksum}; bye" >> "$LOG_FILE" 2>&1
    fi
}

ftp_list() {
    [ "$(as_bool "$FTP_ENABLED")" = true ] || return 1
    command -v lftp >/dev/null 2>&1 || die "lftp not installed"

    local host="${FTP_HOST}:${FTP_PORT}"
    local ssl
    ssl="$(ftp_ssl_cfg)"

    lftp -u "${FTP_USER},${FTP_PASSWORD}" "$host" -e "${ssl} cd ${FTP_REMOTE_PATH}; cls -1; bye" 2>> "$LOG_FILE" \
        | list_archive_names_from_stdin
}

ftp_pull() {
    local wanted="$1"
    local dest="$2"

    [ "$(as_bool "$FTP_ENABLED")" = true ] || return 1
    command -v lftp >/dev/null 2>&1 || die "lftp not installed"

    local picked="$wanted"
    if [ "$picked" = "latest" ]; then
        picked="$(ftp_list | tail -n 1)"
        [ -n "$picked" ] || return 1
    fi
    picked="$(normalize_archive_name "$picked")"
    is_archive_name "$picked" || return 1

    ensure_dir "$dest"

    local host="${FTP_HOST}:${FTP_PORT}"
    local ssl
    ssl="$(ftp_ssl_cfg)"

    if [ "$VERBOSE" = true ]; then
        lftp -u "${FTP_USER},${FTP_PASSWORD}" "$host" -e "${ssl} get -O ${dest} ${FTP_REMOTE_PATH}/${picked}; get -O ${dest} ${FTP_REMOTE_PATH}/${picked}.sha256; bye"
    else
        lftp -u "${FTP_USER},${FTP_PASSWORD}" "$host" -e "${ssl} get -O ${dest} ${FTP_REMOTE_PATH}/${picked}; get -O ${dest} ${FTP_REMOTE_PATH}/${picked}.sha256; bye" >> "$LOG_FILE" 2>&1
    fi

    echo "$picked"
}

s3_cmd() {
    local -a base=(aws --region "$S3_REGION")
    if [ -n "$S3_ENDPOINT_URL" ]; then
        base+=(--endpoint-url "$S3_ENDPOINT_URL")
        if [ "$(as_bool "$S3_VERIFY_SSL")" = false ]; then
            base+=(--no-verify-ssl)
        fi
    fi

    AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" "${base[@]}" s3 "$@"
}

s3api_cmd() {
    local -a base=(aws --region "$S3_REGION")
    if [ -n "$S3_ENDPOINT_URL" ]; then
        base+=(--endpoint-url "$S3_ENDPOINT_URL")
        if [ "$(as_bool "$S3_VERIFY_SSL")" = false ]; then
            base+=(--no-verify-ssl)
        fi
    fi

    AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY" "${base[@]}" s3api "$@"
}

s3_bucket_exists() {
    s3api_cmd head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1
}

s3_create_bucket() {
    if [ "$S3_REGION" = "us-east-1" ]; then
        s3api_cmd create-bucket --bucket "$S3_BUCKET"
    else
        s3api_cmd create-bucket --bucket "$S3_BUCKET" \
            --create-bucket-configuration "LocationConstraint=${S3_REGION}"
    fi
}

s3_ensure_bucket() {
    [ -n "$S3_BUCKET" ] || die "S3_BUCKET is empty"

    if s3_bucket_exists; then
        return 0
    fi

    if [ "$(as_bool "$S3_AUTO_CREATE_BUCKET")" != true ]; then
        die "S3 bucket does not exist: $S3_BUCKET (set S3_AUTO_CREATE_BUCKET=true to auto-create)"
    fi

    log_warn "S3 bucket does not exist: $S3_BUCKET. Creating it..."
    if [ "$VERBOSE" = true ]; then
        s3_create_bucket 2>&1 | tee -a "$LOG_FILE"
    else
        s3_create_bucket >> "$LOG_FILE" 2>&1
    fi

    s3_bucket_exists || die "Failed to create S3 bucket: $S3_BUCKET"
}

s3_key() {
    local name="$1"
    local pfx="$S3_PREFIX"
    if [ -n "$pfx" ] && [[ "$pfx" != */ ]]; then
        pfx="${pfx}/"
    fi
    echo "${pfx}${name}"
}

s3_push() {
    local archive="$1"
    local checksum="$2"
    [ "$(as_bool "$S3_ENABLED")" = true ] || return 1

    command -v aws >/dev/null 2>&1 || die "aws CLI not installed"
    s3_ensure_bucket

    run_cmd s3_cmd cp "$archive" "s3://${S3_BUCKET}/$(s3_key "$(basename "$archive")")"
    run_cmd s3_cmd cp "$checksum" "s3://${S3_BUCKET}/$(s3_key "$(basename "$checksum")")"
}

s3_list() {
    [ "$(as_bool "$S3_ENABLED")" = true ] || return 1
    command -v aws >/dev/null 2>&1 || die "aws CLI not installed"

    s3_cmd ls "s3://${S3_BUCKET}/$(s3_key "")" 2>> "$LOG_FILE" | awk '{print $4}' | list_archive_names_from_stdin
}

s3_pull() {
    local wanted="$1"
    local dest="$2"

    [ "$(as_bool "$S3_ENABLED")" = true ] || return 1
    command -v aws >/dev/null 2>&1 || die "aws CLI not installed"

    local picked="$wanted"
    if [ "$picked" = "latest" ]; then
        picked="$(s3_list | tail -n 1)"
        [ -n "$picked" ] || return 1
    fi
    picked="$(normalize_archive_name "$picked")"
    is_archive_name "$picked" || return 1

    ensure_dir "$dest"

    run_cmd s3_cmd cp "s3://${S3_BUCKET}/$(s3_key "$picked")" "${dest}/${picked}"
    run_cmd s3_cmd cp "s3://${S3_BUCKET}/$(s3_key "${picked}.sha256")" "${dest}/${picked}.sha256"

    echo "$picked"
}

quote_shell() {
    printf "%s" "$1" | sed "s/'/'\\''/g; 1s/^/'/; \$s/\$/'/"
}

rsync_mode() {
    local mode
    mode="$(echo "${RSYNC_MODE:-ssh}" | tr '[:upper:]' '[:lower:]')"
    case "$mode" in
        ssh|daemon) echo "$mode" ;;
        *) die "Invalid RSYNC_MODE: $RSYNC_MODE (expected ssh or daemon)" ;;
    esac
}

rsync_effective_port() {
    local mode
    mode="$(rsync_mode)"
    if [ -n "${RSYNC_PORT:-}" ]; then
        echo "$RSYNC_PORT"
    elif [ "$mode" = "daemon" ]; then
        echo "873"
    else
        echo "22"
    fi
}

rsync_daemon_base() {
    local path="${RSYNC_REMOTE_PATH#/}"
    [ -n "$path" ] || die "RSYNC_REMOTE_PATH must be set for daemon mode (module[/path])"

    local port
    port="$(rsync_effective_port)"
    local user_part=""
    [ -n "${RSYNC_USER:-}" ] && user_part="${RSYNC_USER}@"

    echo "rsync://${user_part}${RSYNC_HOST}:${port}/${path}"
}

rsync_daemon_push() {
    local archive="$1"
    local checksum="$2"
    local opts="$3"
    local base
    base="$(rsync_daemon_base)"

    if [ -n "$RSYNC_PASSWORD" ]; then
        RSYNC_PASSWORD="$RSYNC_PASSWORD" rsync $opts "$archive" "$checksum" "${base}/" >> "$LOG_FILE" 2>&1
    else
        rsync $opts "$archive" "$checksum" "${base}/" >> "$LOG_FILE" 2>&1
    fi
}

rsync_daemon_list() {
    local base
    base="$(rsync_daemon_base)"
    local output=""

    if [ -n "$RSYNC_PASSWORD" ]; then
        output="$(RSYNC_PASSWORD="$RSYNC_PASSWORD" rsync --list-only "${base}/" 2>> "$LOG_FILE")" || return 1
    else
        output="$(rsync --list-only "${base}/" 2>> "$LOG_FILE")" || return 1
    fi

    echo "$output" | awk '{print $NF}' | sed 's#/$##' | list_archive_names_from_stdin
}

rsync_daemon_pull() {
    local wanted="$1"
    local dest="$2"
    local opts="$3"
    local picked="$wanted"

    if [ "$picked" = "latest" ]; then
        picked="$(rsync_daemon_list | tail -n 1)"
        [ -n "$picked" ] || return 1
    fi
    picked="$(normalize_archive_name "$picked")"
    is_archive_name "$picked" || return 1

    ensure_dir "$dest"

    local base
    base="$(rsync_daemon_base)"
    if [ -n "$RSYNC_PASSWORD" ]; then
        RSYNC_PASSWORD="$RSYNC_PASSWORD" rsync $opts \
            "${base}/${picked}" \
            "${base}/${picked}.sha256" \
            "$dest/" >> "$LOG_FILE" 2>&1
    else
        rsync $opts \
            "${base}/${picked}" \
            "${base}/${picked}.sha256" \
            "$dest/" >> "$LOG_FILE" 2>&1
    fi

    echo "$picked"
}

rsync_ssh() {
    local remote_cmd="$1"
    local -a ssh_port_opts=()
    local port
    port="$(rsync_effective_port)"
    [ -n "$port" ] && ssh_port_opts=(-p "$port")

    if [ -n "$RSYNC_SSH_KEY" ] && [ -f "$RSYNC_SSH_KEY" ]; then
        if ssh -o BatchMode=yes "${ssh_port_opts[@]}" -i "$RSYNC_SSH_KEY" "${RSYNC_USER}@${RSYNC_HOST}" "$remote_cmd" 2>> "$LOG_FILE"; then
            return 0
        fi
        [ -n "$RSYNC_PASSWORD" ] || return 1
    fi

    if [ -n "$RSYNC_PASSWORD" ]; then
        command -v sshpass >/dev/null 2>&1 || die "sshpass not installed for rsync password fallback"
        SSHPASS="$RSYNC_PASSWORD" sshpass -e ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "${ssh_port_opts[@]}" "${RSYNC_USER}@${RSYNC_HOST}" "$remote_cmd" 2>> "$LOG_FILE"
        return $?
    fi

    ssh -o BatchMode=yes "${ssh_port_opts[@]}" "${RSYNC_USER}@${RSYNC_HOST}" "$remote_cmd" 2>> "$LOG_FILE"
}

rsync_transfer_ssh() {
    local opts="$1"
    shift
    local port
    port="$(rsync_effective_port)"
    local ssh_cmd="ssh -o BatchMode=yes -p ${port}"

    if [ -n "$RSYNC_SSH_KEY" ] && [ -f "$RSYNC_SSH_KEY" ]; then
        if rsync $opts -e "${ssh_cmd} -i ${RSYNC_SSH_KEY}" "$@" >> "$LOG_FILE" 2>&1; then
            return 0
        fi
        [ -n "$RSYNC_PASSWORD" ] || return 1
    fi

    if [ -n "$RSYNC_PASSWORD" ]; then
        command -v sshpass >/dev/null 2>&1 || die "sshpass not installed for rsync password fallback"
        SSHPASS="$RSYNC_PASSWORD" sshpass -e rsync $opts -e "ssh -p ${port} -o PreferredAuthentications=password -o PubkeyAuthentication=no" "$@" >> "$LOG_FILE" 2>&1
        return $?
    fi

    rsync $opts -e "$ssh_cmd" "$@" >> "$LOG_FILE" 2>&1
}

rsync_push() {
    local archive="$1"
    local checksum="$2"
    [ "$(as_bool "$RSYNC_ENABLED")" = true ] || return 1

    command -v rsync >/dev/null 2>&1 || die "rsync not installed"

    local opts="-az"
    [ "$VERBOSE" = true ] && opts="-avzP"

    if [ "$(rsync_mode)" = "daemon" ]; then
        rsync_daemon_push "$archive" "$checksum" "$opts"
    else
        rsync_transfer_ssh "$opts" "$archive" "$checksum" "${RSYNC_USER}@${RSYNC_HOST}:${RSYNC_REMOTE_PATH}/"
    fi
}

rsync_list() {
    [ "$(as_bool "$RSYNC_ENABLED")" = true ] || return 1
    command -v rsync >/dev/null 2>&1 || die "rsync not installed"

    if [ "$(rsync_mode)" = "daemon" ]; then
        rsync_daemon_list
    else
        local quoted
        quoted="$(quote_shell "$RSYNC_REMOTE_PATH")"
        rsync_ssh "find ${quoted} -maxdepth 1 -type f \\( -name '*.tar.xz' -o -name '*.tar.xz.age' \\) -exec basename {} \\;" \
            | list_archive_names_from_stdin
    fi
}

rsync_pull() {
    local wanted="$1"
    local dest="$2"

    [ "$(as_bool "$RSYNC_ENABLED")" = true ] || return 1
    command -v rsync >/dev/null 2>&1 || die "rsync not installed"

    local picked="$wanted"
    if [ "$picked" = "latest" ]; then
        picked="$(rsync_list | tail -n 1)"
        [ -n "$picked" ] || return 1
    fi
    picked="$(normalize_archive_name "$picked")"
    is_archive_name "$picked" || return 1

    ensure_dir "$dest"

    local opts="-az"
    [ "$VERBOSE" = true ] && opts="-avzP"

    if [ "$(rsync_mode)" = "daemon" ]; then
        rsync_daemon_pull "$picked" "$dest" "$opts" >/dev/null
    else
        rsync_transfer_ssh "$opts" \
            "${RSYNC_USER}@${RSYNC_HOST}:${RSYNC_REMOTE_PATH}/${picked}" \
            "${RSYNC_USER}@${RSYNC_HOST}:${RSYNC_REMOTE_PATH}/${picked}.sha256" \
            "$dest/"
    fi

    echo "$picked"
}

remote_push() {
    case "$1" in
        ftp) ftp_push "$2" "$3" ;;
        s3) s3_push "$2" "$3" ;;
        rsync) rsync_push "$2" "$3" ;;
        *) return 1 ;;
    esac
}

remote_list() {
    case "$1" in
        ftp) ftp_list ;;
        s3) s3_list ;;
        rsync) rsync_list ;;
        *) return 1 ;;
    esac
}

remote_pull() {
    case "$1" in
        ftp) ftp_pull "$2" "$3" ;;
        s3) s3_pull "$2" "$3" ;;
        rsync) rsync_pull "$2" "$3" ;;
        *) return 1 ;;
    esac
}

cmd_config() {
    require_root
    load_config
    init_log "config"

    prompt() {
        local text="$1"
        local default="$2"
        local answer=""
        if [ -n "$default" ]; then
            read -r -p "$text [$default]: " answer
            echo "${answer:-$default}"
        else
            read -r -p "$text: " answer
            echo "$answer"
        fi
    }

    prompt_bool() {
        local text="$1"
        local default="$2"
        local answer=""
        read -r -p "$text [$default]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ ^([yY]|yes|YES|true|TRUE|1)$ ]]; then
            echo "true"
        else
            echo "false"
        fi
    }

    prompt_secret() {
        local text="$1"
        local answer=""
        read -r -s -p "$text: " answer
        echo ""
        echo "$answer"
    }

    BEAMUP_BASE="$(prompt "Beamup base directory" "$BEAMUP_BASE")"
    LOCAL_ARCHIVE_DIR="$(prompt "Archive directory" "$LOCAL_ARCHIVE_DIR")"
    DOWNLOAD_DIR="$(prompt "Download directory" "$DOWNLOAD_DIR")"
    LOG_DIR="$(prompt "Log directory" "$LOG_DIR")"
    RETENTION_DAYS="$(prompt "Retention days" "$RETENTION_DAYS")"
    BACKUP_ENCRYPTION_ENABLED="$(prompt_bool "Encrypt backups with SSH key?" "$BACKUP_ENCRYPTION_ENABLED")"
    if [ "$BACKUP_ENCRYPTION_ENABLED" = true ]; then
        BACKUP_ENCRYPT_SSH_KEY="$(prompt "Backup encryption SSH private key path" "$BACKUP_ENCRYPT_SSH_KEY")"
    fi

    FTP_ENABLED="$(prompt_bool "Enable FTP remote?" "n")"
    if [ "$FTP_ENABLED" = true ]; then
        FTP_HOST="$(prompt "FTP host" "$FTP_HOST")"
        FTP_PORT="$(prompt "FTP port" "$FTP_PORT")"
        FTP_USER="$(prompt "FTP user" "$FTP_USER")"
        FTP_PASSWORD="$(prompt_secret "FTP password")"
        FTP_REMOTE_PATH="$(prompt "FTP remote path" "$FTP_REMOTE_PATH")"
        FTP_VERIFY_TLS="$(prompt_bool "Verify FTP TLS certs?" "y")"
    else
        FTP_HOST=""; FTP_PORT="21"; FTP_USER=""; FTP_PASSWORD=""; FTP_REMOTE_PATH="/backups"; FTP_VERIFY_TLS="true"
    fi

    S3_ENABLED="$(prompt_bool "Enable S3 remote?" "n")"
    if [ "$S3_ENABLED" = true ]; then
        S3_BUCKET="$(prompt "S3 bucket" "$S3_BUCKET")"
        S3_REGION="$(prompt "S3 region" "$S3_REGION")"
        S3_ACCESS_KEY="$(prompt "S3 access key" "$S3_ACCESS_KEY")"
        S3_SECRET_KEY="$(prompt_secret "S3 secret key")"
        S3_PREFIX="$(prompt "S3 prefix" "$S3_PREFIX")"
        S3_ENDPOINT_URL="$(prompt "S3 endpoint URL (empty for AWS)" "$S3_ENDPOINT_URL")"
        S3_VERIFY_SSL="$(prompt_bool "Verify S3 TLS certs?" "y")"
        S3_AUTO_CREATE_BUCKET="$(prompt_bool "Auto-create bucket if missing on push?" "y")"
    else
        S3_BUCKET=""; S3_REGION="us-east-1"; S3_ACCESS_KEY=""; S3_SECRET_KEY=""; S3_PREFIX=""; S3_ENDPOINT_URL=""; S3_VERIFY_SSL="true"; S3_AUTO_CREATE_BUCKET="true"
    fi

    RSYNC_ENABLED="$(prompt_bool "Enable Rsync remote?" "n")"
    if [ "$RSYNC_ENABLED" = true ]; then
        RSYNC_MODE="$(prompt "Rsync mode (ssh|daemon)" "${RSYNC_MODE:-ssh}")"
        RSYNC_MODE="$(echo "$RSYNC_MODE" | tr '[:upper:]' '[:lower:]')"
        case "$RSYNC_MODE" in
            ssh|daemon) ;;
            *) die "Invalid rsync mode: $RSYNC_MODE (expected ssh or daemon)" ;;
        esac

        RSYNC_HOST="$(prompt "Rsync host" "$RSYNC_HOST")"
        if [ "$RSYNC_MODE" = "daemon" ]; then
            [ "${RSYNC_PORT:-}" = "22" ] && RSYNC_PORT="873"
            RSYNC_PORT="$(prompt "Rsync daemon port" "${RSYNC_PORT:-873}")"
            RSYNC_USER="$(prompt "Rsync user (optional)" "$RSYNC_USER")"
            RSYNC_REMOTE_PATH="$(prompt "Rsync daemon module/path" "${RSYNC_REMOTE_PATH#/}")"
            RSYNC_SSH_KEY=""
            RSYNC_PASSWORD="$(prompt_secret "Rsync daemon password (optional)")"
        else
            [ "${RSYNC_PORT:-}" = "873" ] && RSYNC_PORT="22"
            RSYNC_PORT="$(prompt "SSH port" "${RSYNC_PORT:-22}")"
            RSYNC_USER="$(prompt "Rsync SSH user" "$RSYNC_USER")"
            RSYNC_REMOTE_PATH="$(prompt "Rsync SSH remote path" "$RSYNC_REMOTE_PATH")"
            RSYNC_SSH_KEY="$(prompt "Rsync SSH key path" "$RSYNC_SSH_KEY")"
            RSYNC_PASSWORD="$(prompt_secret "Rsync SSH password (optional fallback)")"
        fi
    else
        RSYNC_MODE="ssh"; RSYNC_HOST=""; RSYNC_PORT="22"; RSYNC_USER=""; RSYNC_REMOTE_PATH="/backups"; RSYNC_SSH_KEY="$RSYNC_SSH_KEY_DEFAULT"; RSYNC_PASSWORD=""
    fi

    remotes=""
    [ "$FTP_ENABLED" = true ] && remotes="${remotes},ftp"
    [ "$S3_ENABLED" = true ] && remotes="${remotes},s3"
    [ "$RSYNC_ENABLED" = true ] && remotes="${remotes},rsync"
    ENABLED_REMOTES="${remotes#,}"

    ensure_dir "$(dirname "$CONFIG_FILE")"
    cat > "$CONFIG_FILE" <<CFG
# Beamup sync config generated on $(date '+%Y-%m-%d %H:%M:%S')
BEAMUP_BASE="$BEAMUP_BASE"
LOCAL_ARCHIVE_DIR="$LOCAL_ARCHIVE_DIR"
DOWNLOAD_DIR="$DOWNLOAD_DIR"
LOG_DIR="$LOG_DIR"
LOCK_FILE="$LOCK_FILE"
RETENTION_DAYS="$RETENTION_DAYS"
BACKUP_ENCRYPTION_ENABLED="$BACKUP_ENCRYPTION_ENABLED"
BACKUP_ENCRYPT_SSH_KEY="$BACKUP_ENCRYPT_SSH_KEY"
ENABLED_REMOTES="$ENABLED_REMOTES"

FTP_ENABLED="$FTP_ENABLED"
FTP_HOST="$FTP_HOST"
FTP_PORT="$FTP_PORT"
FTP_USER="$FTP_USER"
FTP_PASSWORD="$FTP_PASSWORD"
FTP_REMOTE_PATH="$FTP_REMOTE_PATH"
FTP_VERIFY_TLS="$FTP_VERIFY_TLS"

S3_ENABLED="$S3_ENABLED"
S3_BUCKET="$S3_BUCKET"
S3_REGION="$S3_REGION"
S3_ACCESS_KEY="$S3_ACCESS_KEY"
S3_SECRET_KEY="$S3_SECRET_KEY"
S3_PREFIX="$S3_PREFIX"
S3_ENDPOINT_URL="$S3_ENDPOINT_URL"
S3_VERIFY_SSL="$S3_VERIFY_SSL"
S3_AUTO_CREATE_BUCKET="$S3_AUTO_CREATE_BUCKET"

RSYNC_ENABLED="$RSYNC_ENABLED"
RSYNC_MODE="$RSYNC_MODE"
RSYNC_HOST="$RSYNC_HOST"
RSYNC_PORT="$RSYNC_PORT"
RSYNC_USER="$RSYNC_USER"
RSYNC_REMOTE_PATH="$RSYNC_REMOTE_PATH"
RSYNC_SSH_KEY="$RSYNC_SSH_KEY"
RSYNC_PASSWORD="$RSYNC_PASSWORD"
CFG
    chmod 600 "$CONFIG_FILE"

    log_info "Config saved: $CONFIG_FILE"
    log_info "Enabled remotes: ${ENABLED_REMOTES:-none}"
}

cmd_verify() {
    require_root
    load_config
    init_log "verify"
    require_config_file

    local failed=false
    local mode=""
    local port=""

    command -v tar >/dev/null 2>&1 || { log_error "tar missing"; failed=true; }
    command -v sha256sum >/dev/null 2>&1 || { log_error "sha256sum missing"; failed=true; }
    if [ "$(as_bool "$BACKUP_ENCRYPTION_ENABLED")" = true ]; then
        command -v age >/dev/null 2>&1 || { log_error "age missing but BACKUP_ENCRYPTION_ENABLED=true"; failed=true; }
        command -v ssh-keygen >/dev/null 2>&1 || { log_error "ssh-keygen missing but BACKUP_ENCRYPTION_ENABLED=true"; failed=true; }
        [ -n "$BACKUP_ENCRYPT_SSH_KEY" ] || { log_error "BACKUP_ENCRYPT_SSH_KEY missing"; failed=true; }
        [ -f "$BACKUP_ENCRYPT_SSH_KEY" ] || { log_error "BACKUP_ENCRYPT_SSH_KEY not found: $BACKUP_ENCRYPT_SSH_KEY"; failed=true; }
        if [ -f "$BACKUP_ENCRYPT_SSH_KEY" ] && ! ssh-keygen -y -f "$BACKUP_ENCRYPT_SSH_KEY" </dev/null >/dev/null 2>> "$LOG_FILE"; then
            log_error "BACKUP_ENCRYPT_SSH_KEY must be a readable SSH private key (without interactive passphrase prompt)"
            failed=true
        fi
    fi

    local remotes
    remotes="$(enabled_remotes_csv)"
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        case "$r" in
            ftp)
                command -v lftp >/dev/null 2>&1 || { log_error "lftp missing for FTP"; failed=true; }
                [ -n "$FTP_HOST" ] || { log_error "FTP_HOST missing"; failed=true; }
                ;;
            s3)
                command -v aws >/dev/null 2>&1 || { log_error "aws CLI missing for S3"; failed=true; }
                [ -n "$S3_BUCKET" ] || { log_error "S3_BUCKET missing"; failed=true; }
                [ -n "$S3_ACCESS_KEY" ] || { log_error "S3_ACCESS_KEY missing"; failed=true; }
                [ -n "$S3_SECRET_KEY" ] || { log_error "S3_SECRET_KEY missing"; failed=true; }
                ;;
            rsync)
                command -v rsync >/dev/null 2>&1 || { log_error "rsync missing"; failed=true; }
                [ -n "$RSYNC_HOST" ] || { log_error "RSYNC_HOST missing"; failed=true; }
                port="$(rsync_effective_port)"
                [[ "$port" =~ ^[0-9]+$ ]] || { log_error "RSYNC_PORT must be numeric"; failed=true; }

                mode="$(rsync_mode)"
                if [ "$mode" = "daemon" ]; then
                    [ -n "$RSYNC_REMOTE_PATH" ] || { log_error "RSYNC_REMOTE_PATH missing for daemon mode"; failed=true; }
                else
                    [ -n "$RSYNC_USER" ] || { log_error "RSYNC_USER missing for ssh mode"; failed=true; }
                    if [ -n "$RSYNC_PASSWORD" ] && ! command -v sshpass >/dev/null 2>&1; then
                        log_error "sshpass missing but RSYNC_PASSWORD is set for ssh mode"
                        failed=true
                    fi
                    if [ -z "$RSYNC_PASSWORD" ] && { [ -z "$RSYNC_SSH_KEY" ] || [ ! -f "$RSYNC_SSH_KEY" ]; }; then
                        log_error "Rsync ssh mode has no valid auth: set RSYNC_PASSWORD or a valid RSYNC_SSH_KEY"
                        failed=true
                    fi
                fi
                ;;
            *)
                log_error "Unknown remote in config: $r"
                failed=true
                ;;
        esac
    done < <(split_csv "$remotes")

    if [ "$failed" = true ]; then
        die "Verification failed"
    fi

    log_info "Verification passed"
}

cmd_backup() {
    require_root
    run_backup_script
}

cmd_push() {
    require_root
    load_config
    init_log "sync"
    require_config_file

    if [ "$FORCE" = true ]; then
        log_info "Creating fresh backup before push"
        run_backup_script
    fi

    build_selected_remotes

    local -a archives=()
    if [ "$PUSH_ALL" = true ]; then
        while IFS= read -r a; do
            [ -n "$a" ] && archives+=("$a")
        done < <(list_local_archives)
    else
        latest="$(latest_local_archive)"
        [ -n "$latest" ] && archives+=("$latest")
    fi

    [ ${#archives[@]} -gt 0 ] || die "No local archives to push"

    acquire_lock
    trap release_lock EXIT

    local success=0
    local failed=0
    for archive in "${archives[@]}"; do
        checksum="$(checksum_path "$archive")"
        [ -f "$checksum" ] || die "Missing checksum for $archive"

        log_info "Pushing $(basename "$archive")"
        local pushed_any=false
        for remote in "${SELECTED_REMOTES[@]}"; do
            if remote_push "$remote" "$archive" "$checksum"; then
                log_info "  [$remote] ok"
                pushed_any=true
            else
                log_warn "  [$remote] failed"
            fi
        done

        if [ "$pushed_any" = true ]; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done

    log_info "Push summary: success=$success failed=$failed"
    [ "$success" -gt 0 ] || exit 1
}

cmd_list() {
    require_root
    load_config
    init_log "sync"
    require_config_file

    build_selected_remotes

    for remote in "${SELECTED_REMOTES[@]}"; do
        echo ""
        echo "=== $remote ==="
        if ! remote_list "$remote"; then
            log_warn "List failed on remote: $remote"
        fi
    done
}

cmd_pull() {
    require_root
    load_config
    init_log "sync"
    require_config_file

    build_selected_remotes

    wanted="$ARG_VALUE"
    [ "$USE_LATEST" = true ] && wanted="latest"
    [ -n "$wanted" ] || die "Provide archive name or --latest"

    ensure_dir "$DOWNLOAD_DIR"

    acquire_lock
    trap release_lock EXIT

    pull_dir="${DOWNLOAD_DIR}/pull-$(date +%Y%m%d_%H%M%S)"
    ensure_dir "$pull_dir"

    resolved=""
    for remote in "${SELECTED_REMOTES[@]}"; do
        log_info "Trying remote: $remote"
        if resolved="$(remote_pull "$remote" "$wanted" "$pull_dir")"; then
            resolved="$(normalize_archive_name "$resolved")"
            [ -n "$resolved" ] || resolved="$wanted"
            break
        fi
    done

    [ -n "$resolved" ] || die "Pull failed on all selected remotes"

    archive_path="${pull_dir}/${resolved}"
    verify_archive_checksum "$archive_path" || die "Downloaded archive checksum verification failed"

    log_info "Downloaded: $archive_path"

    if [ "$AUTO_RESTORE" = true ]; then
        FORCE=true
        run_restore_script "$archive_path"
    fi
}

cmd_restore() {
    require_root
    run_restore_script "$ARG_VALUE"
}

main() {
    require_command
    parse_flags "$@"

    case "$COMMAND" in
        config) cmd_config ;;
        verify) cmd_verify ;;
        backup) cmd_backup ;;
        push) cmd_push ;;
        pull) cmd_pull ;;
        list) cmd_list ;;
        restore) cmd_restore ;;
    esac
}

main "$@"
