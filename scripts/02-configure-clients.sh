#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"

echo "Fetching Elastic IP from Terraform..."
EIP=$(terraform -chdir="${TF_DIR}" output -raw wg_elastic_ip)

if [ -z "$EIP" ] || [[ "$EIP" == *"No outputs found"* ]]; then
    echo "Error: Could not retrieve Elastic IP. Did 'terraform apply' succeed?"
    exit 1
fi

HEADSCALE_URL="https://${EIP}:443"

echo "=== Ensuring EC2 is running ==="
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=wg-bastion" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "None" ]; then
    echo "EC2 is not running. Starting it..."
    INSTANCE_ID=$(aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=tag:Name,Values=wg-bastion" "Name=instance-state-name,Values=stopped" \
        --query "Reservations[0].Instances[0].InstanceId" \
        --output text)
    if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "None" ]; then
        echo "Error: Could not find a stopped bastion instance."
        exit 1
    fi
    aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
    aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --region "$REGION"
    echo "EC2 is running. Waiting for Headscale..."
    MAX_WAIT=120; ELAPSED=0
    until curl -fsSL -k --max-time 5 "${HEADSCALE_URL}" > /dev/null 2>&1; do
        echo -n "."
        sleep 2
        ELAPSED=$((ELAPSED + 2))
        if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
            echo ""
            echo "Error: Headscale did not become ready within ${MAX_WAIT}s."
            exit 1
        fi
    done
    echo ""
fi

echo "=== Downloading CA certificate ==="
CA_CERT="/tmp/headscale-ca.crt"
scp -i ~/.ssh/wg_ec2_ed25519 -P 50022 -o StrictHostKeyChecking=accept-new \
    wgadmin@"${EIP}":/etc/headscale/ca.crt "${CA_CERT}" 2>/dev/null

if [ ! -f "${CA_CERT}" ]; then
    echo "Error: Could not download CA certificate from EC2."
    exit 1
fi

echo "=== Installing CA certificate into system trust store ==="
sudo cp "${CA_CERT}" /etc/ca-certificates/trust-source/anchors/headscale-ca.crt 2>/dev/null \
    || sudo cp "${CA_CERT}" /usr/local/share/ca-certificates/headscale-ca.crt
sudo update-ca-certificates 2>/dev/null || sudo update-ca-trust 2>/dev/null || true
rm -f "${CA_CERT}"
echo "CA certificate installed."

echo "=== Generating auth key ==="
AUTH_KEY=$(ssh -i ~/.ssh/wg_ec2_ed25519 -p 50022 -o StrictHostKeyChecking=accept-new wgadmin@"${EIP}" \
    "sudo headscale preauthkeys create --user default --reusable" 2>/dev/null || echo "")

if [ -z "$AUTH_KEY" ]; then
    echo "Error: Failed to generate auth key."
    exit 1
fi

echo "Auth key generated."

echo "=== Registering desktop with Headscale ==="
if command -v tailscale &>/dev/null; then
    if tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' > /dev/null 2>&1; then
        echo "Desktop is already registered and online."
    else
        sudo tailscale up --login-server "${HEADSCALE_URL}" --authkey "${AUTH_KEY}" --accept-routes
        echo ""
        echo "Desktop registered successfully."
        echo "Your Tailscale IP: $(tailscale ip -4 2>/dev/null || echo 'unknown')"
    fi
else
    echo "Tailscale client not installed. Install it and run:"
    echo "  sudo tailscale up --login-server ${HEADSCALE_URL} --authkey ${AUTH_KEY} --accept-routes"
fi

echo ""
echo "=== Mobile Devices ==="
echo ""
echo "The official Tailscale mobile app does not support custom coordination servers."
echo "Options for mobile:"
echo ""
echo "1. Use WireGuard directly with Headscale's generated WireGuard config:"
echo "   - See: https://headscale.net/ref/running-headscale-community/#android"
echo ""
echo "2. Build a custom Tailscale Android app from source with your Headscale URL"
echo "   - Clone: https://github.com/tailscale/tailscale-android"
echo "   - Modify the default coordination server URL"
echo "   - Build and install the APK"
echo ""
echo "3. Use a different mobile VPN client that supports WireGuard directly"
echo "   (requires manual configuration with Headscale's WireGuard config)"
