#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
SSH_OPTS=(-i "${SSH_KEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate a one-time auth key for adding a new device to the Tailscale network.

Options:
  --register <auth-id>    Register a mobile device using the auth-id from the browser flow
  -h, --help              Show this help message

Examples:
  $(basename "$0")                    # Generate auth key for manual setup
  $(basename "$0") --register hskey-authreq-abc123  # Auto-register mobile device
EOF
}

# Parse arguments
AUTH_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --register)
            if [[ $# -lt 2 ]]; then
                echo "Error: --register requires an auth-id"
                show_usage
                exit 1
            fi
            AUTH_ID="$2"
            # The auth-id goes into a remote shell command, so allow only safe characters.
            if [[ ! "${AUTH_ID}" =~ ^hskey-[a-zA-Z0-9_-]+$ ]]; then
                echo "Error: Invalid auth-id format."
                echo "Expected format: hskey-xxxxx (alphanumeric, hyphens, underscores)"
                exit 1
            fi
            shift 2
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

echo "Fetching Terraform outputs..."
EIP=$(terraform -chdir="${TF_DIR}" output -raw wg_elastic_ip 2>/dev/null) || {
    echo "Error: could not read wg_elastic_ip output. Did 'terraform apply' succeed?"
    exit 1
}
HEADSCALE_URL=$(terraform -chdir="${TF_DIR}" output -raw headscale_url 2>/dev/null) || {
    echo "Error: could not read headscale_url output. Did 'terraform apply' succeed?"
    exit 1
}

SSH_ERR=$(mktemp)
trap 'rm -f "${SSH_ERR}"' EXIT

echo "Checking Headscale connectivity..."
if ! curl -fsS --max-time 5 "${HEADSCALE_URL}/health" > /dev/null 2>&1; then
    echo "Headscale is not reachable at ${HEADSCALE_URL}."
    echo "Start the tunnel first:"
    echo "  bash scripts/vpn-up.sh"
    exit 1
fi

# Get user ID (create if needed, like in 02-configure-clients.sh)
USER_ID=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
    "sudo headscale users list --output json" 2>"${SSH_ERR}" \
    | jq -r '.[] | select(.name == "default") | .id // empty') || {
    echo "Error: SSH to the instance failed:"
    cat "${SSH_ERR}"
    echo "If the instance was re-provisioned, clear the old host key first:"
    echo "  ssh-keygen -R '[${EIP}]:${SSH_PORT}'"
    exit 1
}

# Create user if it doesn't exist
if [ -z "${USER_ID}" ]; then
    echo "Creating Headscale user 'default'..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" "sudo headscale users create default" 2>"${SSH_ERR}" || {
        echo "Error: could not create Headscale user 'default':"
        cat "${SSH_ERR}"
        exit 1
    }
    USER_ID=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
        "sudo headscale users list --output json" 2>"${SSH_ERR}" \
        | jq -r '.[] | select(.name == "default") | .id // empty') || {
        echo "Error: could not list Headscale users after creating 'default':"
        cat "${SSH_ERR}"
        exit 1
    }
    if [ -z "${USER_ID}" ]; then
        echo "Error: Headscale user 'default' still not found after creation."
        exit 1
    fi
fi

# Handle automated registration mode
if [ -n "${AUTH_ID}" ]; then
    echo ""
    echo "Registering device with auth-id: ${AUTH_ID}"
    # AUTH_ID was checked against a safe pattern during argument parsing.
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
        "sudo headscale auth register --auth-id '${AUTH_ID}' --user default" 2>"${SSH_ERR}" || {
        echo "Error: failed to register device:"
        cat "${SSH_ERR}"
        echo ""
        echo "The auth-id may have expired or already been used."
        echo "Generate a new auth key with: $(basename "$0")"
        exit 1
    }
    echo ""
    echo "Device registered successfully!"
    echo "It should appear in your Tailscale network within a few seconds."
    exit 0
fi

KEY_JSON=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
    "sudo headscale preauthkeys create --user ${USER_ID} --expiration 15m --output json" 2>"${SSH_ERR}") || {
    echo "Error: failed to generate auth key:"
    cat "${SSH_ERR}"
    exit 1
}
AUTH_KEY=$(echo "${KEY_JSON}" | jq -r '.key // empty')
if [ -z "${AUTH_KEY}" ]; then
    echo "Error: could not parse auth key from Headscale response."
    exit 1
fi

echo ""
echo "Auth key generated (single-use, expires in 15 minutes)."
echo ""
echo "=== Linux / desktop device ==="
echo ""
echo "On the new device, run (key is one-time and expires in 15 min, so it is"
echo "harmless in shell history afterwards):"
echo ""
echo "  sudo tailscale up --login-server ${HEADSCALE_URL} --auth-key ${AUTH_KEY} --accept-routes"
echo ""
echo "=== Mobile device (official Tailscale app) ==="
echo ""
echo "  Android: Settings -> Accounts menu -> 'Use an alternate server'"
echo "  iOS:     Settings -> Alternate Coordination Server URL"
echo ""
echo "  Option A (Android): sign-in screen -> menu -> 'Use auth key' -> paste"
echo "  the key printed above. Done — no server command needed."
echo ""
echo "  Option B (browser flow):"
echo "  1. Enter: ${HEADSCALE_URL}"
echo "  2. Tap Sign In — a browser page opens showing a registration command,"
echo "     e.g. on Headscale 0.29:"
echo "       headscale auth register --auth-id hskey-authreq-... --user USERNAME"
echo "  3. Copy the auth-id (hskey-authreq-...) and run on this machine:"
echo "       bash scripts/add-device.sh --register hskey-authreq-..."
echo ""
echo "The device will get an IP in the 100.64.0.0/10 range."
