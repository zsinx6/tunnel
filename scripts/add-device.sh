#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
SSH_OPTS=(-i "${SSH_KEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

echo "Fetching Terraform outputs..."
EIP=$(terraform -chdir="${TF_DIR}" output -raw wg_elastic_ip 2>/dev/null) || {
    echo "Error: could not read wg_elastic_ip output. Did 'terraform apply' succeed?"
    exit 1
}
HEADSCALE_URL=$(terraform -chdir="${TF_DIR}" output -raw headscale_url 2>/dev/null) || {
    echo "Error: could not read headscale_url output. Did 'terraform apply' succeed?"
    exit 1
}

echo "=== Adding a New Device ==="
echo ""
if ! curl -fsS --max-time 5 "${HEADSCALE_URL}/health" > /dev/null 2>&1; then
    echo "Headscale is not reachable at ${HEADSCALE_URL}."
    echo "Start the tunnel first:"
    echo "  bash scripts/vpn-up.sh"
    exit 1
fi
echo "Headscale is up at ${HEADSCALE_URL}."

echo ""
echo "Generating one-time auth key via SSH..."
SSH_ERR=$(mktemp)
trap 'rm -f "${SSH_ERR}"' EXIT

USER_ID=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
    "sudo headscale users list --output json" 2>"${SSH_ERR}" \
    | jq -r '.[] | select(.name == "default") | .id // empty') || {
    echo "Error: SSH to the instance failed:"
    cat "${SSH_ERR}"
    echo "If the instance was re-provisioned, clear the old host key first:"
    echo "  ssh-keygen -R '[${EIP}]:${SSH_PORT}'"
    exit 1
}
if [ -z "${USER_ID}" ]; then
    echo "Error: Headscale user 'default' not found on the server."
    exit 1
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
echo "  1. Enter: ${HEADSCALE_URL}"
echo "  2. Tap Sign In — a browser page opens showing a"
echo "     'headscale nodes register ...' command."
echo "  3. Run that command on the server (prefix with sudo):"
echo "     ssh -i ${SSH_KEY} -p ${SSH_PORT} ${SSH_USER}@${EIP} \"sudo headscale nodes register ...\""
echo ""
echo "The device will get an IP in the 100.64.0.0/10 range."
