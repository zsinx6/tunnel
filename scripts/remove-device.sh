#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
SSH_OPTS=(-i "${SSH_KEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <identifier>

Remove a device from the Tailscale network.

Arguments:
  identifier         Node name, hostname, or Tailscale IP (100.x.x.x)

Options:
  --list             List all registered nodes
  --expire           Expire the node instead of deleting it (softer, can re-register)
  --force            Skip confirmation prompt
  -h, --help         Show this help message

Examples:
  $(basename "$0") my-phone              # Remove node by name
  $(basename "$0") 100.64.0.5            # Remove node by IP
  $(basename "$0") --expire my-tablet    # Expire instead of delete
  $(basename "$0") --list                # List all nodes
EOF
}

# Parse arguments
ACTION="delete"
IDENTIFIER=""
FORCE=false
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            LIST_ONLY=true
            shift
            ;;
        --expire)
            ACTION="expire"
            shift
            ;;
        --force)
            FORCE=true
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
            if [ -z "${IDENTIFIER}" ]; then
                IDENTIFIER="$1"
                # Validate identifier: only allow alphanumeric, dots, hyphens, underscores
                if [[ ! "${IDENTIFIER}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                    echo "Error: Invalid identifier format."
                    echo "Only alphanumeric characters, dots, hyphens, and underscores are allowed."
                    exit 1
                fi
            else
                echo "Error: Multiple identifiers provided"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

if ! ${LIST_ONLY} && [ -z "${IDENTIFIER}" ]; then
    echo "Error: identifier required"
    show_usage
    exit 1
fi

echo "Fetching Terraform outputs..."
EIP=$(terraform -chdir="${TF_DIR}" output -raw wg_elastic_ip 2>/dev/null) || {
    echo "Error: could not read wg_elastic_ip output. Did 'terraform apply' succeed?"
    exit 1
}

echo "Checking Headscale connectivity..."
HEADSCALE_URL=$(terraform -chdir="${TF_DIR}" output -raw headscale_url 2>/dev/null) || {
    echo "Error: could not read headscale_url output. Did 'terraform apply' succeed?"
    exit 1
}

if ! curl -fsS --max-time 5 "${HEADSCALE_URL}/health" > /dev/null 2>&1; then
    echo "Headscale is not reachable at ${HEADSCALE_URL}."
    echo "Start the tunnel first:"
    echo "  bash scripts/vpn-up.sh"
    exit 1
fi

SSH_ERR=$(mktemp)
trap 'rm -f "${SSH_ERR}"' EXIT

# List mode
if ${LIST_ONLY}; then
    echo ""
    echo "=== Registered Nodes ==="
    echo ""
    NODES_JSON=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
        "sudo headscale nodes list --output json" 2>"${SSH_ERR}") || {
        echo "Error: SSH to the instance failed:"
        cat "${SSH_ERR}"
        echo "If the instance was re-provisioned, clear the old host key first:"
        echo "  ssh-keygen -R '[${EIP}]:${SSH_PORT}'"
        exit 1
    }
    
    echo "${NODES_JSON}" | jq -r '
        .[] | 
        "ID: \(.id)\nName: \(.name)\nIP: \(.ipAddresses // [] | join(", "))\nUser: \(.user.name)\nOnline: \(.online)\nLast seen: \(.lastSeen)\n---"
    '
    exit 0
fi

# Find the node by name or IP
echo "Searching for node matching '${IDENTIFIER}'..."
NODES_JSON=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
    "sudo headscale nodes list --output json" 2>"${SSH_ERR}") || {
    echo "Error: SSH to the instance failed:"
    cat "${SSH_ERR}"
    echo "If the instance was re-provisioned, clear the old host key first:"
    echo "  ssh-keygen -R '[${EIP}]:${SSH_PORT}'"
    exit 1
}

# Search by name, hostname, or IP (IDENTIFIER is already validated above)
NODE_MATCH=$(echo "${NODES_JSON}" | jq -r --arg id "${IDENTIFIER}" '
    .[] | 
    select(
        (.name | test($id; "i")) or 
        (.hostName | test($id; "i")) or 
        (.ipAddresses // [] | any(. == $id))
    ) |
    "ID: \(.id) | Name: \(.name) | IPs: \(.ipAddresses // [] | join(", ")) | User: \(.user.name) | Online: \(.online)"
' | head -1)

if [ -z "${NODE_MATCH}" ]; then
    echo "Error: No node found matching '${IDENTIFIER}'"
    echo ""
    echo "Available nodes:"
    echo "${NODES_JSON}" | jq -r '.[] | "  \(.name) (\(.ipAddresses // [] | join(", ")))"'
    exit 1
fi

NODE_ID=$(echo "${NODE_MATCH}" | sed 's/.*ID: \([0-9]*\).*/\1/')
NODE_NAME=$(echo "${NODE_MATCH}" | sed 's/.*Name: \([^|]*\).*/\1/' | xargs)

echo ""
echo "Found node:"
echo "  ${NODE_MATCH}"
echo ""

# Confirmation
if ! ${FORCE}; then
    read -p "Are you sure you want to ${ACTION} this node? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

# Perform the action
echo ""
if [ "${ACTION}" = "delete" ]; then
    echo "Deleting node ${NODE_ID}..."
    # NODE_ID is extracted from JSON output, should be numeric only
    if [[ ! "${NODE_ID}" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid node ID extracted. This may indicate a parsing error."
        exit 1
    fi
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
        "sudo headscale nodes delete --id ${NODE_ID}" 2>"${SSH_ERR}" || {
        echo "Error: failed to delete node:"
        cat "${SSH_ERR}"
        exit 1
    }
    echo "Node deleted successfully."
else
    echo "Expiring node ${NODE_ID}..."
    # NODE_ID is extracted from JSON output, should be numeric only
    if [[ ! "${NODE_ID}" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid node ID extracted. This may indicate a parsing error."
        exit 1
    fi
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
        "sudo headscale nodes expire --id ${NODE_ID}" 2>"${SSH_ERR}" || {
        echo "Error: failed to expire node:"
        cat "${SSH_ERR}"
        exit 1
    }
    echo "Node expired successfully. It can be re-registered later."
fi

echo ""
echo "Note: If this device had a subnet route approved (via 03-lan-services.sh),"
echo "you may need to re-run that script if another device is now serving that route."
