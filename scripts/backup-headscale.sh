#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
SSH_OPTS=(-i "${SSH_KEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
BACKUP_DIR="${SCRIPT_DIR}/../backups"

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Backup or restore the Headscale SQLite database.

Options:
  --backup               Backup current database
  --restore <file>       Restore database from backup
  --list                 List available backups
  -h, --help             Show this help message

Examples:
  $(basename "$0") --backup
  $(basename "$0") --list
  $(basename "$0") --restore headscale-db-2024-01-15.sqlite
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

echo "Fetching Terraform outputs..."
EIP=$(terraform -chdir="${TF_DIR}" output -raw wg_elastic_ip 2>/dev/null) || {
    echo "Error: could not read wg_elastic_ip output. Did 'terraform apply' succeed?"
    exit 1
}

mkdir -p "${BACKUP_DIR}"

SSH_ERR=$(mktemp)
trap 'rm -f "${SSH_ERR}"' EXIT

check_headscale() {
    HEADSCALE_URL=$(terraform -chdir="${TF_DIR}" output -raw headscale_url 2>/dev/null) || {
        echo "Error: could not read headscale_url output."
        exit 1
    }
    
    if ! curl -fsS --max-time 5 "${HEADSCALE_URL}/health" > /dev/null 2>&1; then
        echo "Headscale is not reachable at ${HEADSCALE_URL}."
        echo "Start the tunnel first:"
        echo "  bash scripts/vpn-up.sh"
        exit 1
    fi
}

case "${ACTION}" in
    backup)
        echo "=== Backing up Headscale Database ==="
        check_headscale
        
        TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
        BACKUP_FILE="${BACKUP_DIR}/headscale-db-${TIMESTAMP}.sqlite"
        
        echo "Copying database from EC2..."
        # Note: SQLite databases are generally safe to copy while running due to WAL mode
        scp "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}:/var/lib/headscale/db.sqlite" "${BACKUP_FILE}" 2>"${SSH_ERR}" || {
            echo "Error: failed to copy database:"
            cat "${SSH_ERR}"
            exit 1
        }
        
        chmod 600 "${BACKUP_FILE}"
        
        # Get node count for info
        NODE_COUNT=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
            "sudo headscale nodes list --output json" 2>/dev/null | jq 'length' || echo "unknown")
        
        echo ""
        echo "✓ Backup saved to: ${BACKUP_FILE}"
        echo "  Size: $(du -h "${BACKUP_FILE}" | cut -f1)"
        echo "  Nodes: ${NODE_COUNT}"
        echo ""
        echo "This backup contains ALL Headscale data:"
        echo "  - Registered devices and their keys"
        echo "  - Users and auth keys"
        echo "  - Route approvals"
        echo "  - DERP configuration"
        echo ""
        echo "To restore after re-provisioning:"
        echo "  bash scripts/backup-headscale.sh --restore ${BACKUP_FILE}"
        ;;
        
    restore)
        if [ -z "${RESTORE_FILE}" ]; then
            echo "Error: --restore requires a file path"
            show_usage
            exit 1
        fi
        
        # Prevent path traversal attacks
        case "${RESTORE_FILE}" in
            ../*|*/../*|*/..)
                echo "Error: Invalid backup file path. Path traversal not allowed."
                exit 1
                ;;
        esac
        
        # If absolute path, must be within backups directory
        if [[ "${RESTORE_FILE}" == /* ]]; then
            case "${RESTORE_FILE}" in
                ${BACKUP_DIR}/*)
                    # OK - within backups directory
                    ;;
                *)
                    echo "Error: Absolute path must be within backups directory: ${BACKUP_DIR}"
                    exit 1
                    ;;
            esac
        fi
        
        if [ ! -f "${RESTORE_FILE}" ]; then
            echo "Error: backup file not found: ${RESTORE_FILE}"
            exit 1
        fi
        
        if [ ! -r "${RESTORE_FILE}" ]; then
            echo "Error: Cannot read backup file (permission denied): ${RESTORE_FILE}"
            exit 1
        fi
        
        if [[ "${RESTORE_FILE}" != *.sqlite ]]; then
            echo "Error: expected .sqlite file, got: ${RESTORE_FILE}"
            exit 1
        fi
        
        echo "=== Restoring Headscale Database ==="
        echo ""
        echo "WARNING: This will replace the current Headscale database."
        echo "All existing registrations will be lost."
        echo ""
        echo "Backup file: ${RESTORE_FILE}"
        echo "Size: $(du -h "${RESTORE_FILE}" | cut -f1)"
        echo ""
        
        read -p "Are you sure you want to continue? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            exit 0
        fi
        
        check_headscale
        
        # Upload backup to EC2
        echo "Uploading database to EC2..."
        scp "${SSH_OPTS[@]}" "${RESTORE_FILE}" "${SSH_USER}@${EIP}:/tmp/headscale-restore.sqlite" 2>"${SSH_ERR}" || {
            echo "Error: failed to upload database:"
            cat "${SSH_ERR}"
            exit 1
        }
        
        # Stop Headscale before replacing database
        echo "Stopping Headscale..."
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" "sudo systemctl stop headscale" 2>"${SSH_ERR}" || {
            echo "Warning: failed to stop Headscale (may already be stopped):"
            cat "${SSH_ERR}"
        }
        
        # Replace database
        echo "Replacing database..."
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" "
            sudo cp /tmp/headscale-restore.sqlite /var/lib/headscale/db.sqlite &&
            sudo chown headscale:headscale /var/lib/headscale/db.sqlite &&
            sudo chmod 640 /var/lib/headscale/db.sqlite &&
            rm -f /tmp/headscale-restore.sqlite
        " 2>"${SSH_ERR}" || {
            echo "Error: failed to replace database:"
            cat "${SSH_ERR}"
            exit 1
        }
        
        # Start Headscale
        echo "Starting Headscale..."
        ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" "sudo systemctl start headscale" 2>"${SSH_ERR}" || {
            echo "Error: failed to start Headscale:"
            cat "${SSH_ERR}"
            exit 1
        }
        
        # Wait for Headscale to be ready
        echo "Waiting for Headscale to become healthy..."
        HEADSCALE_URL=$(terraform -chdir="${TF_DIR}" output -raw headscale_url 2>/dev/null)
        MAX_WAIT=60
        ELAPSED=0
        until curl -fsS --max-time 5 "${HEADSCALE_URL}/health" > /dev/null 2>&1; do
            sleep 2
            ELAPSED=$((ELAPSED + 2))
            if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
                echo "Warning: Headscale health check timed out after ${MAX_WAIT}s"
                echo "Check logs: ssh -i ${SSH_KEY} -p ${SSH_PORT} ${SSH_USER}@${EIP} sudo tunnel-logs"
                break
            fi
        done
        
        # Verify restoration
        NODE_COUNT=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
            "sudo headscale nodes list --output json" 2>/dev/null | jq 'length' || echo "error")
        
        echo ""
        echo "✓ Database restored successfully!"
        echo "  Nodes in database: ${NODE_COUNT}"
        echo ""
        echo "All previously registered devices should now appear in the network."
        echo "Devices may need to reconnect to pick up the restored configuration."
        ;;
        
    list)
        echo "=== Available Database Backups ==="
        echo ""
        
        if [ ! -d "${BACKUP_DIR}" ] || [ -z "$(ls -A "${BACKUP_DIR}"/*.sqlite 2>/dev/null)" ]; then
            echo "No database backups found in: ${BACKUP_DIR}"
            echo ""
            echo "Create a backup with:"
            echo "  bash scripts/backup-headscale.sh --backup"
            exit 0
        fi
        
        echo "Backups directory: ${BACKUP_DIR}"
        echo ""
        ls -lh "${BACKUP_DIR}"/*.sqlite 2>/dev/null | while IFS= read -r line; do
            FILE=$(echo "${line}" | awk '{print $NF}')
            SIZE=$(echo "${line}" | awk '{print $5}')
            DATE=$(echo "${line}" | awk '{print $6, $7, $8}')
            
            # Try to get node count without downloading
            echo "  📦 $(basename "${FILE}")  (${SIZE}, ${DATE})"
        done
        
        echo ""
        TOTAL=$(ls "${BACKUP_DIR}"/*.sqlite 2>/dev/null | wc -l)
        echo "Total backups: ${TOTAL}"
        echo ""
        echo "Space used: $(du -sh "${BACKUP_DIR}" | cut -f1)"
        ;;
esac
