#!/usr/bin/env bash
set -euo pipefail
# Backups hold the Headscale server private keys: every file this script
# creates is readable by its owner only.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
SSH_OPTS=(-i "${SSH_KEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
BACKUP_DIR="$(cd "${SCRIPT_DIR}/.." &> /dev/null && pwd)/backups"
# The files that tunnel-backup on the instance puts in each archive.
BACKUP_FILES=(db.sqlite noise_private.key derp_server_private.key)

show_usage() {
    cat <<EOF
Usage: $(basename "$0") --backup | --restore <file> | --list

Back up or restore the Headscale state: the database (devices, users, routes)
and the server private keys.

Options:
  --backup               Save a backup in backups/
  --restore <file>       Restore a backup: a path, or a file name in backups/
  --list                 List the backups in backups/
  -h, --help             Show this help message

Examples:
  $(basename "$0") --backup
  $(basename "$0") --list
  $(basename "$0") --restore headscale-2026-01-15_120000.tar.gz
EOF
}

# Parse arguments
ACTION=""
RESTORE_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --backup)
            ACTION="backup"
            shift
            ;;
        --restore)
            if [[ $# -lt 2 ]]; then
                echo "Error: --restore requires a backup file"
                show_usage
                exit 1
            fi
            ACTION="restore"
            RESTORE_FILE="$2"
            shift 2
            ;;
        --list)
            ACTION="list"
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            echo "Error: Unknown option $1"
            show_usage
            exit 1
            ;;
        *)
            echo "Error: Unexpected argument: $1"
            show_usage
            exit 1
            ;;
    esac
done

if [ -z "${ACTION}" ]; then
    echo "Error: action required"
    show_usage
    exit 1
fi

# Returns success if the file is a tar.gz that holds exactly BACKUP_FILES, all
# regular files. tunnel-restore on the instance makes the same check.
is_backup_archive() {
    local names listing
    names=$(tar -tzf "$1" 2>/dev/null | sort) || return 1
    listing=$(tar -tvzf "$1" 2>/dev/null) || return 1
    [ "${names}" = "$(printf '%s\n' "${BACKUP_FILES[@]}" | sort)" ] && ! grep -qv '^-' <<<"${listing}"
}

# --list reads only local files, so it does not need the instance.
if [ "${ACTION}" = "list" ]; then
    echo "=== Available Backups ==="
    echo ""
    shopt -s nullglob
    BACKUPS=("${BACKUP_DIR}"/headscale-*.tar.gz)
    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        echo "No backups found in: ${BACKUP_DIR}"
        echo ""
        echo "Create a backup with:"
        echo "  bash scripts/backup-headscale.sh --backup"
        exit 0
    fi
    echo "Backups directory: ${BACKUP_DIR}"
    echo ""
    for f in "${BACKUPS[@]}"; do
        echo "  $(basename "${f}")  ($(du -h "${f}" | cut -f1), $(date -r "${f}" '+%Y-%m-%d %H:%M'))"
    done
    echo ""
    echo "Total backups: ${#BACKUPS[@]}"
    echo "Space used: $(du -sh "${BACKUP_DIR}" | cut -f1)"
    exit 0
fi

# Check the restore file before anything touches the instance.
if [ "${ACTION}" = "restore" ]; then
    # A bare file name that does not exist here refers to backups/.
    if [ ! -e "${RESTORE_FILE}" ] && [[ "${RESTORE_FILE}" != */* ]]; then
        RESTORE_FILE="${BACKUP_DIR}/${RESTORE_FILE}"
    fi
    if [ ! -f "${RESTORE_FILE}" ] || [ ! -r "${RESTORE_FILE}" ]; then
        echo "Error: cannot read backup file: ${RESTORE_FILE}"
        exit 1
    fi
    if ! is_backup_archive "${RESTORE_FILE}"; then
        echo "Error: ${RESTORE_FILE} is not a backup made by this script."
        echo "Expected a tar.gz archive that holds exactly: ${BACKUP_FILES[*]}"
        exit 1
    fi
fi

echo "Fetching Terraform outputs..."
EIP=$(terraform -chdir="${TF_DIR}" output -raw wg_elastic_ip 2>/dev/null) || {
    echo "Error: could not read wg_elastic_ip output. Did 'terraform apply' succeed?"
    exit 1
}
HEADSCALE_URL=$(terraform -chdir="${TF_DIR}" output -raw headscale_url 2>/dev/null) || {
    echo "Error: could not read headscale_url output. Did 'terraform apply' succeed?"
    exit 1
}

if ! curl -fsS --max-time 5 "${HEADSCALE_URL}/health" > /dev/null 2>&1; then
    echo "Headscale is not reachable at ${HEADSCALE_URL}."
    echo "If the instance was just re-provisioned, wait until its DNS record and"
    echo "TLS certificate are ready (a few minutes after boot). Otherwise start the"
    echo "tunnel first:"
    echo "  bash scripts/vpn-up.sh"
    exit 1
fi

SSH_ERR=$(mktemp)
PARTIAL_FILE=""
trap 'rm -f "${SSH_ERR}" ${PARTIAL_FILE:+"${PARTIAL_FILE}"}' EXIT

# Prints the SSH error, plus an explanation for the causes that have a known fix.
report_ssh_error() {
    cat "${SSH_ERR}"
    if grep -q -E 'password is required|command not found' "${SSH_ERR}"; then
        echo ""
        echo "The instance has no tunnel-backup / tunnel-restore helper. An instance"
        echo "gets these helpers when it is provisioned, so this instance was"
        echo "provisioned from an older version of this repo, and it cannot be backed"
        echo "up. See 'Backing Up Devices' in the README."
    elif grep -q -E 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED' "${SSH_ERR}"; then
        echo "The instance was re-provisioned. Clear the old host key first:"
        echo "  ssh-keygen -R '[${EIP}]:${SSH_PORT}'"
    fi
}

count_nodes() {
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
        "sudo headscale nodes list --output json" 2>/dev/null | jq 'length' || echo "unknown"
}

# Saves the current Headscale state from the instance to the given file.
save_backup() {
    local target="$1"
    mkdir -p "${BACKUP_DIR}"
    # Write to a temporary name, so an interrupted copy never looks like a backup.
    PARTIAL_FILE="${target}.partial"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" "sudo -n tunnel-backup" \
        > "${PARTIAL_FILE}" 2>"${SSH_ERR}" || {
        echo "Error: the backup failed:"
        report_ssh_error
        exit 1
    }
    if ! is_backup_archive "${PARTIAL_FILE}"; then
        echo "Error: the archive from the instance is incomplete or damaged."
        exit 1
    fi
    mv "${PARTIAL_FILE}" "${target}"
}

case "${ACTION}" in
    backup)
        echo "=== Backing up Headscale ==="
        BACKUP_FILE="${BACKUP_DIR}/headscale-$(date +%Y-%m-%d_%H%M%S).tar.gz"
        echo "Copying the Headscale state from the instance..."
        save_backup "${BACKUP_FILE}"

        echo ""
        echo "✓ Backup saved to: ${BACKUP_FILE}"
        echo "  Size: $(du -h "${BACKUP_FILE}" | cut -f1)"
        echo "  Nodes registered now: $(count_nodes)"
        echo ""
        echo "The backup holds the Headscale database (devices, users, approved routes,"
        echo "auth keys) and the server private keys. Keep it as safe as an SSH key."
        echo ""
        echo "To restore it after re-provisioning:"
        echo "  bash scripts/backup-headscale.sh --restore $(basename "${BACKUP_FILE}")"
        ;;

    restore)
        echo "=== Restoring Headscale ==="
        echo ""
        echo "WARNING: This replaces the Headscale state on the instance with the backup."
        echo "Devices registered after the backup was made must register again."
        echo "The current state is saved to backups/ first, so you can undo the restore."
        echo ""
        echo "Backup file: ${RESTORE_FILE}"
        echo "Size: $(du -h "${RESTORE_FILE}" | cut -f1)"
        echo ""

        read -p "Are you sure you want to continue? [y/N] " -n 1 -r || REPLY=""
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            exit 0
        fi

        UNDO_FILE="${BACKUP_DIR}/headscale-$(date +%Y-%m-%d_%H%M%S)-before-restore.tar.gz"
        echo "Saving the current state..."
        save_backup "${UNDO_FILE}"

        echo "Uploading and restoring..."
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" "sudo -n tunnel-restore" \
            < "${RESTORE_FILE}" 2>"${SSH_ERR}" || {
            echo "Error: the restore failed:"
            report_ssh_error
            echo ""
            echo "The state from before this restore is saved. If Headscale does not work"
            echo "now, restore it:"
            echo "  bash scripts/backup-headscale.sh --restore $(basename "${UNDO_FILE}")"
            exit 1
        }

        echo "Waiting for Headscale to become healthy..."
        MAX_WAIT=60
        ELAPSED=0
        until curl -fsS --max-time 5 "${HEADSCALE_URL}/health" > /dev/null 2>&1; do
            sleep 2
            ELAPSED=$((ELAPSED + 2))
            if [ "${ELAPSED}" -ge "${MAX_WAIT}" ]; then
                echo "Error: Headscale did not become healthy within ${MAX_WAIT}s."
                echo "Check the logs: ssh -i ${SSH_KEY} -p ${SSH_PORT} ${SSH_USER}@${EIP} sudo tunnel-logs"
                exit 1
            fi
        done

        echo ""
        echo "✓ Restore complete."
        echo "  Nodes in database: $(count_nodes)"
        echo ""
        echo "Devices should reconnect on their own within a minute or two."
        echo "If a device stays offline, restart Tailscale on that device."
        echo ""
        echo "To undo this restore:"
        echo "  bash scripts/backup-headscale.sh --restore $(basename "${UNDO_FILE}")"
        ;;
esac
