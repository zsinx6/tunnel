#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "=== 1. Locating WireGuard Bastion on AWS ==="
INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=wg-bastion" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "None" ]; then
    echo "Error: Could not find an instance tagged 'wg-bastion'."
    exit 1
fi

echo "=== 2. Waking Cloud Infrastructure ==="
INSTANCE_STATE=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text)

FRESHLY_STARTED=false
case "$INSTANCE_STATE" in
    running)
        echo "Instance is already running."
        ;;
    pending)
        echo "Instance is already starting. Waiting for it to be ready..."
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
        FRESHLY_STARTED=true
        ;;
    stopping)
        echo "Instance is still stopping. Waiting for it to fully stop..."
        aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
        echo "Starting EC2 Bastion ($INSTANCE_ID)..."
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
        FRESHLY_STARTED=true
        ;;
    stopped)
        echo "Starting EC2 Bastion ($INSTANCE_ID)..."
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
        FRESHLY_STARTED=true
        ;;
    *)
        echo "Error: Instance is in unexpected state '$INSTANCE_STATE'. Aborting."
        exit 1
        ;;
esac

if [ "$FRESHLY_STARTED" = true ]; then
    echo "Waiting for EC2 status checks to pass..."
    aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --region "$REGION"
fi

echo "=== 3. Establishing Encrypted Tunnel ==="
echo "Starting local WireGuard interface..."
sudo systemctl start wg-quick@wg0

if [ "$FRESHLY_STARTED" = true ]; then
    echo "Allowing 15s for remote EC2 startup-update service to run..."
    sleep 15
fi

echo "Polling remote interface..."
MAX_WAIT=180; ELAPSED=0
until sudo wg show wg0 > /dev/null 2>&1 && \
      sudo wg show wg0 | grep -qE "latest handshake:[[:space:]]+[0-9]"; do
    echo -n "."
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo ""
        EIP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
            --query "Reservations[0].Instances[0].PublicIpAddress" --output text 2>/dev/null || echo "<EIP>")
        echo "Error: Tunnel did not come up within ${MAX_WAIT}s."
        echo "SSH directly to check logs: ssh -i ~/.ssh/wg_ec2_ed25519 -p 50022 wgadmin@${EIP}"
        echo "Then run: journalctl -u wg-quick@wg0 -u startup-update"
        exit 1
    fi
done

echo ""
echo "Connection verified! Tunnel is active."
