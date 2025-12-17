#!/bin/bash

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions and set helper script paths
if [ -f "${SCRIPT_DIR}/beamup-common.sh" ]; then
    source "${SCRIPT_DIR}/beamup-common.sh"
    BACKUP_SCRIPT="${SCRIPT_DIR}/beamup-backup.sh"
    RESTORE_SCRIPT="${SCRIPT_DIR}/beamup-restore.sh"
elif [ -f "/usr/local/lib/beamup/beamup-common" ]; then
    source "/usr/local/lib/beamup/beamup-common"
    BACKUP_SCRIPT="/usr/local/lib/beamup/beamup-backup"
    RESTORE_SCRIPT="/usr/local/lib/beamup/beamup-restore"
else
    echo "Error: Helper scripts not found" >&2
    exit 1
fi

# Parse command and arguments
COMMAND="${1:-}"
shift || true

USE_FTP=false
USE_S3=false
USE_RSYNC=false
AUTO_RESTORE=false
FORCE_BACKUP=false
BACKUP_NAME=""

show_usage() {
    cat << EOF
Usage: beamup-sync [COMMAND] [OPTIONS]

Sync backups to/from remote storage.

COMMANDS:
    backup              Create a new local backup only (no remote push)
    push                Push local backups to remote storage
    pull BACKUP_NAME    Pull backup from remote storage
    restore             Restore latest local backup
    list                List backups on remote storage
    config              Configure remote storage settings
    verify              Verify configuration and connectivity

OPTIONS:
    --ftp               Use FTP storage
    --s3                Use S3 storage
    --rsync             Use rsync storage
    -f, --force         Force creation of new backup before push
    -r, --restore       Automatically restore after pull
    -v, --verbose       Enable verbose output
    -h, --help          Show this help message

EXAMPLES:
    beamup-sync backup                  # Create local backup only
    beamup-sync backup --verbose        # Create backup with verbose output
    beamup-sync push                    # Push to all enabled remotes
    beamup-sync push --force            # Create new backup and push
    beamup-sync push --ftp --s3         # Push only to FTP and S3
    beamup-sync push -f --verbose       # Force backup with verbose output
    beamup-sync pull backup-20231028    # Pull specific backup
    beamup-sync pull --latest --s3      # Pull latest backup from S3
    beamup-sync pull --latest -r        # Pull latest and restore
    beamup-sync restore                 # Restore latest local backup
    beamup-sync list --ftp              # List backups on FTP
    beamup-sync config                  # Interactive configuration
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
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
        -f|--force)
            FORCE_BACKUP=true
            shift
            ;;
        -r|--restore)
            AUTO_RESTORE=true
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
        --latest)
            BACKUP_NAME="latest"
            shift
            ;;
        *)
            if [ -z "$BACKUP_NAME" ]; then
                BACKUP_NAME="$1"
            fi
            shift
            ;;
    esac
done

# Check root
check_root

# Initialize logging
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/sync-${TIMESTAMP}.log"
init_logging

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    parse_config "$CONFIG_FILE"
else
    if [ "$COMMAND" != "config" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_info "Run 'beamup-sync config' to create configuration"
        exit 1
    fi
fi

# Determine which remotes to use
determine_remotes() {
    local remotes=()
    
    # If flags specified, use only those
    if [ "$USE_FTP" = true ] || [ "$USE_S3" = true ] || [ "$USE_RSYNC" = true ]; then
        [ "$USE_FTP" = true ] && remotes+=("ftp")
        [ "$USE_S3" = true ] && remotes+=("s3")
        [ "$USE_RSYNC" = true ] && remotes+=("rsync")
    else
        # Use enabled remotes from config
        if [ -n "${general_enabled_remotes:-}" ]; then
            IFS=',' read -ra remotes <<< "$general_enabled_remotes"
        fi
    fi
    
    echo "${remotes[@]}"
}

# FTP functions
ftp_push() {
    local backup_file="$1"
    local backup_name=$(basename "$backup_file")
    local checksum_file="${backup_file}.sha256"
    
    log_info "[FTP] Uploading $backup_name..."
    
    if [ "${ftp_enabled:-false}" != "true" ]; then
        log_warn "[FTP] FTP is not enabled in configuration"
        return 1
    fi
    
    # Upload using lftp for better reliability
    if command -v lftp &> /dev/null; then
        lftp -e "set ftp:ssl-allow no; put -O ${ftp_remote_path} ${backup_file}; put -O ${ftp_remote_path} ${checksum_file}; bye" \
            -u "${ftp_username},${ftp_password}" "${ftp_host}" >> "$LOG_FILE" 2>&1 && {
            log_success "[FTP] Upload completed"
            return 0
        } || {
            log_error "[FTP] Upload failed"
            return 1
        }
    else
        log_error "[FTP] lftp not installed"
        return 1
    fi
}

ftp_list() {
    log_info "[FTP] Listing backups..."
    
    if command -v lftp &> /dev/null; then
        lftp -e "set ftp:ssl-allow no; cd ${ftp_remote_path}; cls -1 *.tar.xz; bye" \
            -u "${ftp_username},${ftp_password}" "${ftp_host}" 2>> "$LOG_FILE"
    fi
}

ftp_pull() {
    local backup_name="$1"
    local dest_dir="$2"

    # If backup_name is 'latest', determine the latest backup file
    if [ "$backup_name" = "latest" ]; then
        log_info "[FTP] Determining latest backup..."
        if command -v lftp &> /dev/null; then
            latest_file=$(lftp -e "set ftp:ssl-allow no; cd ${ftp_remote_path}; cls -1 *.tar.xz; bye" \
                -u "${ftp_username},${ftp_password}" "${ftp_host}" 2>> "$LOG_FILE" | sort | tail -n 1)
            if [ -z "$latest_file" ]; then
                log_error "[FTP] No backups found on remote."
                return 1
            fi
            backup_name="$latest_file"
            log_info "[FTP] Latest backup is: $backup_name"
        else
            log_error "[FTP] lftp not installed"
            return 1
        fi
    fi

    log_info "[FTP] Downloading $backup_name..."

    if command -v lftp &> /dev/null; then
        mkdir -p "$dest_dir"
        lftp -e "set ftp:ssl-allow no; get -O ${dest_dir} ${ftp_remote_path}/${backup_name}; get -O ${dest_dir} ${ftp_remote_path}/${backup_name}.sha256; bye" \
            -u "${ftp_username},${ftp_password}" "${ftp_host}" >> "$LOG_FILE" 2>&1 && {
            log_success "[FTP] Download completed"
            ACTUAL_BACKUP_NAME="$backup_name"
            return 0
        } || {
            log_error "[FTP] Download failed"
            return 1
        }
    fi
}

# S3 functions
s3_push() {
    local backup_file="$1"
    local backup_name=$(basename "$backup_file")
    local checksum_file="${backup_file}.sha256"
    
    log_info "[S3] Uploading $backup_name..."
    
    if [ "${s3_enabled:-false}" != "true" ]; then
        log_warn "[S3] S3 is not enabled in configuration"
        return 1
    fi
    
    if command -v aws &> /dev/null; then
        local aws_cmd="AWS_ACCESS_KEY_ID=\"${s3_access_key}\" AWS_SECRET_ACCESS_KEY=\"${s3_secret_key}\" aws s3 cp"
        local aws_opts="--region \"${s3_region}\""
        
        # Add endpoint-url if configured
        if [ -n "${s3_endpoint_url:-}" ]; then
            aws_opts="$aws_opts --endpoint-url \"${s3_endpoint_url}\" --no-verify-ssl"
        fi
        
        eval "$aws_cmd \"$backup_file\" \"s3://${s3_bucket}/${s3_prefix}${backup_name}\" $aws_opts >> \"$LOG_FILE\" 2>&1" && \
        eval "$aws_cmd \"$checksum_file\" \"s3://${s3_bucket}/${s3_prefix}${backup_name}.sha256\" $aws_opts >> \"$LOG_FILE\" 2>&1" && {
            log_success "[S3] Upload completed"
            return 0
        } || {
            log_error "[S3] Upload failed"
            return 1
        }
    else
        log_error "[S3] aws-cli not installed"
        return 1
    fi
}

s3_list() {
    log_info "[S3] Listing backups..."
    
    if command -v aws &> /dev/null; then
        local aws_cmd="AWS_ACCESS_KEY_ID=\"${s3_access_key}\" AWS_SECRET_ACCESS_KEY=\"${s3_secret_key}\" aws s3 ls"
        local aws_opts="--region \"${s3_region}\""
        
        # Add endpoint-url if configured
        if [ -n "${s3_endpoint_url:-}" ]; then
            aws_opts="$aws_opts --endpoint-url \"${s3_endpoint_url}\" --no-verify-ssl"
        fi
        
        eval "$aws_cmd \"s3://${s3_bucket}/${s3_prefix}\" $aws_opts 2>> \"$LOG_FILE\" | grep \".tar.xz$\""
    fi
}

s3_pull() {
    local backup_name="$1"
    local dest_dir="$2"
    
    log_info "[S3] Downloading $backup_name..."
    
    if command -v aws &> /dev/null; then
        mkdir -p "$dest_dir"
        
        local aws_cmd="AWS_ACCESS_KEY_ID=\"${s3_access_key}\" AWS_SECRET_ACCESS_KEY=\"${s3_secret_key}\" aws s3 cp"
        local aws_opts="--region \"${s3_region}\""
        
        # Add endpoint-url if configured
        if [ -n "${s3_endpoint_url:-}" ]; then
            aws_opts="$aws_opts --endpoint-url \"${s3_endpoint_url}\" --no-verify-ssl"
        fi
        
        eval "$aws_cmd \"s3://${s3_bucket}/${s3_prefix}${backup_name}\" \"${dest_dir}/${backup_name}\" $aws_opts >> \"$LOG_FILE\" 2>&1" && \
        eval "$aws_cmd \"s3://${s3_bucket}/${s3_prefix}${backup_name}.sha256\" \"${dest_dir}/${backup_name}.sha256\" $aws_opts >> \"$LOG_FILE\" 2>&1" && {
            log_success "[S3] Download completed"
            return 0
        } || {
            log_error "[S3] Download failed"
            return 1
        }
    fi
}

# Rsync functions
rsync_push() {
    local backup_file="$1"
    local backup_name=$(basename "$backup_file")
    local checksum_file="${backup_file}.sha256"
    
    log_info "[RSYNC] Uploading $backup_name..."
    
    if [ "${rsync_enabled:-false}" != "true" ]; then
        log_warn "[RSYNC] Rsync is not enabled in configuration"
        return 1
    fi
    
    local rsync_opts="-avz"
    [ "$VERBOSE" = true ] && rsync_opts="-avzP"
    
    if [ -n "${rsync_ssh_key:-}" ]; then
        rsync $rsync_opts -e "ssh -i ${rsync_ssh_key}" \
            "$backup_file" "$checksum_file" \
            "${rsync_user}@${rsync_host}:${rsync_remote_path}/" >> "$LOG_FILE" 2>&1 && {
            log_success "[RSYNC] Upload completed"
            return 0
        } || {
            log_error "[RSYNC] Upload failed"
            return 1
        }
    else
        rsync $rsync_opts "$backup_file" "$checksum_file" \
            "${rsync_user}@${rsync_host}:${rsync_remote_path}/" >> "$LOG_FILE" 2>&1 && {
            log_success "[RSYNC] Upload completed"
            return 0
        } || {
            log_error "[RSYNC] Upload failed"
            return 1
        }
    fi
}

rsync_list() {
    log_info "[RSYNC] Listing backups..."
    
    if [ -n "${rsync_ssh_key:-}" ]; then
        ssh -i "${rsync_ssh_key}" "${rsync_user}@${rsync_host}" \
            "ls -lh ${rsync_remote_path}/*.tar.xz" 2>> "$LOG_FILE"
    else
        ssh "${rsync_user}@${rsync_host}" \
            "ls -lh ${rsync_remote_path}/*.tar.xz" 2>> "$LOG_FILE"
    fi
}

rsync_pull() {
    local backup_name="$1"
    local dest_dir="$2"
    
    log_info "[RSYNC] Downloading $backup_name..."
    
    mkdir -p "$dest_dir"
    
    local rsync_opts="-avz"
    [ "$VERBOSE" = true ] && rsync_opts="-avzP"
    
    if [ -n "${rsync_ssh_key:-}" ]; then
        rsync $rsync_opts -e "ssh -i ${rsync_ssh_key}" \
            "${rsync_user}@${rsync_host}:${rsync_remote_path}/${backup_name}" \
            "${rsync_user}@${rsync_host}:${rsync_remote_path}/${backup_name}.sha256" \
            "$dest_dir/" >> "$LOG_FILE" 2>&1 && {
            log_success "[RSYNC] Download completed"
            return 0
        } || {
            log_error "[RSYNC] Download failed"
            return 1
        }
    else
        rsync $rsync_opts \
            "${rsync_user}@${rsync_host}:${rsync_remote_path}/${backup_name}" \
            "${rsync_user}@${rsync_host}:${rsync_remote_path}/${backup_name}.sha256" \
            "$dest_dir/" >> "$LOG_FILE" 2>&1 && {
            log_success "[RSYNC] Download completed"
            return 0
        } || {
            log_error "[RSYNC] Download failed"
            return 1
        }
    fi
}

# Command: backup
cmd_backup() {
    log_info "Starting local backup operation (no remote push)"
    
    acquire_lock
    trap release_lock EXIT
    
    # Check if backup script exists
    if [ ! -f "$BACKUP_SCRIPT" ]; then
        log_error "beamup-backup.sh not found at $BACKUP_SCRIPT"
        exit 1
    fi
    
    log_info "Running beamup-backup.sh..."
    if [ "$VERBOSE" = true ]; then
        "$BACKUP_SCRIPT" --verbose
    else
        "$BACKUP_SCRIPT"
    fi
    
    # Verify backup was created
    local latest_backup=$(get_latest_backup)
    if [ -z "$latest_backup" ]; then
        log_error "Backup creation failed"
        exit 1
    fi
    
    log_success "Local backup created successfully"
    log_info "Backup location: $latest_backup"
    log_info "To push this backup to remote storage, run: beamup-sync push"
}

# Command: push
cmd_push() {
    log_info "Starting backup push operation"
    
    acquire_lock
    trap release_lock EXIT
    
    # Determine remotes to use
    local remotes=($(determine_remotes))
    
    # If no remotes configured, just run backup
    if [ ${#remotes[@]} -eq 0 ]; then
        log_warn "No remotes configured, running backup only..."
        
        # Check if backup script exists
        if [ -f "$BACKUP_SCRIPT" ]; then
            log_info "Running beamup-backup.sh..."
            if [ "$VERBOSE" = true ]; then
                "$BACKUP_SCRIPT" --verbose
            else
                "$BACKUP_SCRIPT"
            fi
            log_success "Backup completed (no remotes to push to)"
            exit 0
        else
            log_error "beamup-backup.sh not found at $BACKUP_SCRIPT"
            exit 1
        fi
    fi
    
    # Find backups to push
    local backups=""
    
    # If --force flag is set, create a new backup first
    if [ "$FORCE_BACKUP" = true ]; then
        log_info "Force flag detected, creating new backup..."
        
        if [ -f "$BACKUP_SCRIPT" ]; then
            log_info "Running beamup-backup.sh..."
            if [ "$VERBOSE" = true ]; then
                "$BACKUP_SCRIPT" --verbose
            else
                "$BACKUP_SCRIPT"
            fi
            
            # Get the newly created backup (should be the latest)
            backups=$(get_latest_backup)
            if [ -z "$backups" ]; then
                log_error "Backup creation failed"
                exit 1
            fi
            log_success "New backup created successfully"
        else
            log_error "beamup-backup.sh not found at $BACKUP_SCRIPT"
            exit 1
        fi
    else
        # Normal operation: find existing backups to push
        backups=$(list_local_backups)
        if [ -z "$backups" ]; then
            log_warn "No backups found to push"
            
            # Offer to create backup
            log_info "Would you like to create a backup now? This will happen automatically."
            if [ -f "$BACKUP_SCRIPT" ]; then
                log_info "Running beamup-backup.sh..."
                if [ "$VERBOSE" = true ]; then
                    "$BACKUP_SCRIPT" --verbose
                else
                    "$BACKUP_SCRIPT"
                fi
                
                # Get the newly created backup
                backups=$(list_local_backups)
                if [ -z "$backups" ]; then
                    log_error "Backup creation failed"
                    exit 1
                fi
            else
                log_error "beamup-backup.sh not found"
                exit 1
            fi
        fi
    fi
    
    log_info "Pushing to remotes: ${remotes[*]}"
    
    local success_count=0
    local fail_count=0
    
    while IFS= read -r backup_file; do
        log_info "Processing: $(basename "$backup_file")"
        
        local remote_success=0
        local remote_fail=0
        
        for remote in "${remotes[@]}"; do
            case "$remote" in
                ftp)
                    ftp_push "$backup_file" && ((remote_success++)) || ((remote_fail++))
                    ;;
                s3)
                    s3_push "$backup_file" && ((remote_success++)) || ((remote_fail++))
                    ;;
                rsync)
                    rsync_push "$backup_file" && ((remote_success++)) || ((remote_fail++))
                    ;;
            esac
        done
        
        if [ $remote_success -gt 0 ]; then
            ((success_count++))
            if [ $remote_fail -gt 0 ]; then
                log_warn "Backup pushed to $remote_success remote(s), but failed on $remote_fail"
            fi
        else
            ((fail_count++))
            log_error "Failed to push backup to any remote"
        fi
    done <<< "$backups"
    
    log_info "=========================================="
    log_success "Push operation completed"
    log_info "Successful: $success_count, Failed: $fail_count"
    log_info "=========================================="
    
    [ $success_count -gt 0 ] && exit 0 || exit 1
}

# Command: pull
cmd_pull() {
    if [ -z "$BACKUP_NAME" ]; then
        log_error "Backup name required. Use: beamup-sync pull BACKUP_NAME"
        exit 1
    fi
    
    log_info "Starting backup pull operation"
    
    acquire_lock
    trap release_lock EXIT
    
    local remotes=($(determine_remotes))
    if [ ${#remotes[@]} -eq 0 ]; then
        log_error "No remotes configured or specified"
        exit 1
    fi
    
    # Create download directory
    local download_ts=$(date +%Y%m%d_%H%M%S)
    local download_dir="${BEAMUP_BASE}/downloaded-${download_ts}"
    mkdir -p "$download_dir"
    
    log_info "Pulling from remotes: ${remotes[*]}"
    
    local downloaded=false
    ACTUAL_BACKUP_NAME=""
    for remote in "${remotes[@]}"; do
        case "$remote" in
            ftp)
                ftp_pull "$BACKUP_NAME" "$download_dir" && downloaded=true && break
                ;;
            s3)
                s3_pull "$BACKUP_NAME" "$download_dir" && downloaded=true && break
                ;;
            rsync)
                rsync_pull "$BACKUP_NAME" "$download_dir" && downloaded=true && break
                ;;
        esac
    done
    if [ -n "$ACTUAL_BACKUP_NAME" ]; then
        BACKUP_NAME="$ACTUAL_BACKUP_NAME"
    fi

    if [ "$downloaded" = false ]; then
        log_error "Failed to download backup from any remote"
        rm -rf "$download_dir"
        exit 1
    fi
    
    local downloaded_file="${download_dir}/${BACKUP_NAME}"
    
    # Verify downloaded backup
    verify_backup "$downloaded_file" || {
        log_error "Downloaded backup failed integrity check"
        exit 1
    }
    
    log_success "Backup downloaded successfully to: $downloaded_file"
    
    # Auto-restore if requested
    if [ "$AUTO_RESTORE" = true ]; then
        log_info "Auto-restore enabled, starting restore..."
        "$RESTORE_SCRIPT" --force "$downloaded_file"
    fi
}

# Command: restore
cmd_restore() {
    log_info "Starting restore from latest local backup"
    "$RESTORE_SCRIPT"
}

# Command: list
cmd_list() {
    local remotes=($(determine_remotes))
    if [ ${#remotes[@]} -eq 0 ]; then
        log_error "No remotes configured or specified"
        exit 1
    fi
    
    for remote in "${remotes[@]}"; do
        echo ""
        echo "=== $remote backups ==="
        case "$remote" in
            ftp) ftp_list ;;
            s3) s3_list ;;
            rsync) rsync_list ;;
        esac
    done
}

# Command: config
cmd_config() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║          Beamup Sync - Interactive Configuration              ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    mkdir -p "$CONFIG_DIR"
    
    # Check if updating existing config or creating new
    local updating_config=false
    if [ -f "$CONFIG_FILE" ]; then
        updating_config=true
    fi
    
    # Backup existing config if it exists
    if [ -f "$CONFIG_FILE" ]; then
        local backup_config="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$backup_config"
        log_info "Existing configuration backed up to: $backup_config"
        echo ""
    fi
    
    # Start building config
    local config_content="# Beamup Sync Configuration
# Generated on $(date +%Y-%m-%d\ %H:%M:%S)

[general]
"
    
    # General settings
    echo -e "${GREEN}=== General Settings ===${NC}"
    echo ""
    
    read -p "Retention days for backups [30]: " retention_days
    retention_days=${retention_days:-30}
    config_content+="retention_days=${retention_days}
"
    
    read -p "Enable parallel uploads? (y/n) [n]: " parallel_uploads
    parallel_uploads=${parallel_uploads:-n}
    if [[ "$parallel_uploads" =~ ^[yY]$ ]]; then
        config_content+="parallel_uploads=true
"
    else
        config_content+="parallel_uploads=false
"
    fi
    
    read -p "Require all remotes to succeed? (y/n) [n]: " require_all
    require_all=${require_all:-n}
    if [[ "$require_all" =~ ^[yY]$ ]]; then
        config_content+="require_all_success=true
"
    else
        config_content+="require_all_success=false
"
    fi
    
    local enabled_remotes=()
    
    # FTP Configuration
    echo ""
    echo -e "${GREEN}=== FTP Configuration ===${NC}"
    echo ""
    read -p "Enable FTP backup? (y/n) [n]: " enable_ftp
    enable_ftp=${enable_ftp:-n}
    
    if [[ "$enable_ftp" =~ ^[yY]$ ]]; then
        enabled_remotes+=("ftp")
        config_content+="
[ftp]
enabled=true
"
        
        read -p "FTP Host: " ftp_host
        config_content+="host=${ftp_host}
"
        
        read -p "FTP Port [21]: " ftp_port
        ftp_port=${ftp_port:-21}
        config_content+="port=${ftp_port}
"
        
        read -p "FTP Username: " ftp_user
        config_content+="username=${ftp_user}
"
        
        read -sp "FTP Password: " ftp_pass
        echo ""
        config_content+="password=${ftp_pass}
"
        
        read -p "Remote path [/backups]: " ftp_path
        ftp_path=${ftp_path:-/backups}
        config_content+="remote_path=${ftp_path}
"
        
        read -p "Verify SSL? (y/n) [y]: " ftp_ssl
        ftp_ssl=${ftp_ssl:-y}
        if [[ "$ftp_ssl" =~ ^[yY]$ ]]; then
            config_content+="verify_ssl=true
"
        else
            config_content+="verify_ssl=false
"
        fi
    else
        config_content+="
[ftp]
enabled=false
host=ftp.example.com
port=21
username=backup_user
password=
remote_path=/backups
verify_ssl=true
"
    fi
    
    # S3 Configuration
    echo ""
    echo -e "${GREEN}=== S3 Configuration ===${NC}"
    echo ""
    read -p "Enable S3 backup? (y/n) [n]: " enable_s3
    enable_s3=${enable_s3:-n}
    
    if [[ "$enable_s3" =~ ^[yY]$ ]]; then
        enabled_remotes+=("s3")
        config_content+="
[s3]
enabled=true
"
        
        read -p "S3 Bucket name: " s3_bucket
        config_content+="bucket=${s3_bucket}
"
        
        read -p "S3 Region [us-east-1]: " s3_region
        s3_region=${s3_region:-us-east-1}
        config_content+="region=${s3_region}
"
        
        read -p "S3 Access Key: " s3_access
        config_content+="access_key=${s3_access}
"
        
        read -sp "S3 Secret Key: " s3_secret
        echo ""
        config_content+="secret_key=${s3_secret}
"
        
        read -p "S3 Prefix (path) []: " s3_prefix
        config_content+="prefix=${s3_prefix}
"
        
        # New: Endpoint URL for testing/mockup servers
        echo ""
        echo -e "${YELLOW}Testing/Development Options:${NC}"
        read -p "S3 Endpoint URL (for testing with MinIO/LocalStack, leave empty for AWS) []: " s3_endpoint
        if [ -n "$s3_endpoint" ]; then
            config_content+="endpoint_url=${s3_endpoint}
"
            log_info "Custom endpoint configured - SSL verification will be disabled"
        else
            config_content+="endpoint_url=
"
        fi
    else
        config_content+="
[s3]
enabled=false
bucket=my-backups
region=us-east-1
access_key=
secret_key=
prefix=
endpoint_url=
"
    fi
    
    # Rsync Configuration
    echo ""
    echo -e "${GREEN}=== Rsync Configuration ===${NC}"
    echo ""
    read -p "Enable Rsync backup? (y/n) [n]: " enable_rsync
    enable_rsync=${enable_rsync:-n}
    
    if [[ "$enable_rsync" =~ ^[yY]$ ]]; then
        enabled_remotes+=("rsync")
        config_content+="
[rsync]
enabled=true
"
        
        read -p "Rsync Host: " rsync_host
        config_content+="host=${rsync_host}
"
        
        read -p "Rsync User: " rsync_user
        config_content+="user=${rsync_user}
"
        
        read -p "Remote path: " rsync_path
        config_content+="remote_path=${rsync_path}
"
        
        read -p "SSH Key path [/root/.ssh/id_rsa]: " rsync_key
        rsync_key=${rsync_key:-/root/.ssh/id_rsa}
        config_content+="ssh_key=${rsync_key}
"
    else
        config_content+="
[rsync]
enabled=false
host=backup.example.com
user=backup
remote_path=/backups
ssh_key=/root/.ssh/id_rsa
"
    fi
    
    # Add enabled_remotes to general section
    if [ ${#enabled_remotes[@]} -gt 0 ]; then
        local remotes_str=$(IFS=,; echo "${enabled_remotes[*]}")
        # Insert after [general] section
        config_content=$(echo "$config_content" | sed "s/\[general\]/[general]\nenabled_remotes=${remotes_str}/")
    else
        config_content=$(echo "$config_content" | sed "s/\[general\]/[general]\nenabled_remotes=/")
    fi
    
    # Write configuration file
    echo "$config_content" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Configuration saved successfully!                 ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_success "Configuration file created: $CONFIG_FILE"
    log_info "File permissions set to 600 (readable only by owner)"
    
    if [ ${#enabled_remotes[@]} -gt 0 ]; then
        log_info "Enabled remotes: ${enabled_remotes[*]}"
        echo ""
        log_info "Testing configuration..."
        cmd_verify
    else
        log_warn "No remotes enabled. You can edit $CONFIG_FILE to enable remotes later."
    fi
    
    # Cronjob configuration
    echo ""
    echo -e "${GREEN}=== Automatic Backup Schedule ===${NC}"
    echo ""
    read -p "Would you like to set up automatic backups? (y/n) [y]: " setup_cron
    setup_cron=${setup_cron:-y}
    
    if [[ "$setup_cron" =~ ^[yY]$ ]]; then
        configure_cronjob "$updating_config"
    else
        log_info "Skipping automatic backup setup"
        echo ""
        log_info "You can manually set up a cronjob later with:"
        log_info "  crontab -e"
        log_info "  # Add: 0 2 * * * /usr/local/bin/beamup-sync push >/dev/null 2>&1"
    fi
}

# Configure cronjob for automatic backups
configure_cronjob() {
    local updating="$1"
    
    echo ""
    echo "Select backup frequency:"
    echo "  1) Daily (recommended)"
    echo "  2) Weekly (every Sunday)"
    echo "  3) Custom schedule"
    echo ""
    read -p "Choose option [1]: " cron_option
    cron_option=${cron_option:-1}
    
    local cron_schedule=""
    local cron_description=""
    
    case $cron_option in
        1)
            read -p "What time (24-hour format, e.g., 02:00)? [02:00]: " backup_time
            backup_time=${backup_time:-02:00}
            
            # Parse hour and minute
            local hour=$(echo "$backup_time" | cut -d: -f1)
            local minute=$(echo "$backup_time" | cut -d: -f2)
            
            # Remove leading zeros for cron
            hour=$((10#$hour))
            minute=$((10#$minute))
            
            cron_schedule="$minute $hour * * *"
            cron_description="Daily at $backup_time"
            ;;
        2)
            read -p "What time on Sunday (24-hour format, e.g., 02:00)? [02:00]: " backup_time
            backup_time=${backup_time:-02:00}
            
            local hour=$(echo "$backup_time" | cut -d: -f1)
            local minute=$(echo "$backup_time" | cut -d: -f2)
            
            hour=$((10#$hour))
            minute=$((10#$minute))
            
            cron_schedule="$minute $hour * * 0"
            cron_description="Weekly on Sunday at $backup_time"
            ;;
        3)
            echo ""
            echo "Enter cron schedule (e.g., '0 2 * * *' for daily at 2 AM):"
            read -p "Schedule: " custom_schedule
            cron_schedule="$custom_schedule"
            cron_description="Custom: $custom_schedule"
            ;;
        *)
            log_error "Invalid option"
            return 1
            ;;
    esac
    
    # Verbose option
    read -p "Enable verbose logging in cronjob? (y/n) [n]: " cron_verbose
    cron_verbose=${cron_verbose:-n}
    
    local beamup_command="/usr/local/bin/beamup-sync push"
    if [[ "$cron_verbose" =~ ^[yY]$ ]]; then
        beamup_command="$beamup_command --verbose"
    fi
    
    # Build the cron entry
    local cron_entry="# Beamup automatic backup - $cron_description"
    cron_entry="$cron_entry
$cron_schedule $beamup_command"
    
    cron_entry="$cron_entry >/dev/null 2>&1"
    
    # Check for existing beamup cronjob
    if crontab -l 2>/dev/null | grep -q "beamup-sync push"; then
        echo ""
        log_warn "Existing beamup cronjob found"
        
        if [ "$updating" = true ]; then
            read -p "Replace existing cronjob? (y/n) [y]: " replace_cron
            replace_cron=${replace_cron:-y}
        else
            replace_cron="y"
        fi
        
        if [[ "$replace_cron" =~ ^[yY]$ ]]; then
            # Remove old beamup entries
            crontab -l 2>/dev/null | grep -v "beamup-sync push" | grep -v "Beamup automatic backup" | crontab -
            log_info "Removed old beamup cronjob"
        else
            log_info "Keeping existing cronjob"
            return 0
        fi
    fi
    
    # Add new cronjob
    (crontab -l 2>/dev/null; echo ""; echo "$cron_entry") | crontab -
    
    echo ""
    log_success "Cronjob installed successfully!"
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    Backup Schedule                             ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  Schedule: $cron_description"
    echo -e "${GREEN}║  Command: $beamup_command"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_info "View your crontab with: crontab -l"
    log_info "Edit your crontab with: crontab -e"
}

# Command: verify
cmd_verify() {
    log_info "Verifying configuration..."
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found"
        exit 1
    fi
    
    log_success "Configuration file found"
    
    # Test each enabled remote
    local remotes=($(determine_remotes))
    for remote in "${remotes[@]}"; do
        log_info "Testing $remote connection..."
        case "$remote" in
            ftp)
                command -v lftp &> /dev/null && log_success "[FTP] lftp installed" || log_error "[FTP] lftp not installed"
                ;;
            s3)
                command -v aws &> /dev/null && log_success "[S3] aws-cli installed" || log_error "[S3] aws-cli not installed"
                ;;
            rsync)
                command -v rsync &> /dev/null && log_success "[RSYNC] rsync installed" || log_error "[RSYNC] rsync not installed"
                ;;
        esac
    done
}

# Main command router
case "$COMMAND" in
    push)
        cmd_push
        ;;
    pull)
        cmd_pull
        ;;
    backup)
        cmd_backup
        ;;
    restore)
        cmd_restore
        ;;
    list)
        cmd_list
        ;;
    config)
        cmd_config
        ;;
    verify)
        cmd_verify
        ;;
    *)
        show_usage
        exit 1
        ;;
esac