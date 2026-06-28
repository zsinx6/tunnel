#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# vpn-down.sh
# Closes local tunnel and cleanly halts AWS compute.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "Shutting down local WireGuard tunnel..."
sudo systemctl stop wg-quick@wg0

echo "Locating running instance to halt..."
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=wg-bastion" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
    echo "Stopping EC2 instance ($INSTANCE_ID) to halt billing..."
    aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
    aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
    echo "Infrastructure successfully halted."
else
    echo "No running bastion found."
fi
