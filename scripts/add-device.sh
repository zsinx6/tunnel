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

echo "=== Adding a New Device ==="
echo ""
echo "Headscale must be running (EC2 must be up) to generate auth keys."
echo ""

read -r -p "Is the tunnel currently running? [y/N] " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Start the tunnel first:"
    echo "  bash scripts/vpn-up.sh"
    echo ""
    echo "Then re-run this script."
    exit 0
fi

echo ""
echo "Generating auth key via SSH..."
AUTH_KEY=$(ssh -i ~/.ssh/wg_ec2_ed25519 -p 50022 -o StrictHostKeyChecking=accept-new wgadmin@"${EIP}" \
    "sudo headscale preauthkeys create --user default --reusable" 2>/dev/null || echo "")

if [ -z "$AUTH_KEY" ]; then
    echo "Error: Failed to generate auth key. Check SSH connectivity and Headscale status."
    exit 1
fi

echo ""
echo "Auth key generated successfully!"
echo ""
echo "=== New Device Setup ==="
echo ""
echo "On the new device:"
echo ""
echo "1. Download the CA certificate from the EC2 instance:"
echo "   scp -i ~/.ssh/wg_ec2_ed25519 -P 50022 wgadmin@${EIP}:/etc/headscale/ca.crt /tmp/headscale-ca.crt"
echo ""
echo "2. Install the CA certificate into the system trust store:"
echo "   sudo cp /tmp/headscale-ca.crt /usr/local/share/ca-certificates/headscale-ca.crt"
echo "   sudo update-ca-certificates"
echo ""
echo "3. Register with Headscale:"
echo "   sudo tailscale up --login-server ${HEADSCALE_URL} --authkey ${AUTH_KEY} --accept-routes"
echo ""
echo "The device will get an IP in the 100.64.0.0/10 range."
echo "You can then access it from other Tailscale devices."
