#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "=== 1. Locating Tailscale Bastion on AWS ==="
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

echo "=== 3. Waiting for Headscale to be ready ==="
EIP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

if [ -z "$EIP" ] || [ "$EIP" == "None" ]; then
    echo "Error: Could not retrieve Elastic IP."
    exit 1
fi

HEADSCALE_URL="https://${EIP}:443"
MAX_WAIT=120; ELAPSED=0
until curl -fsSL -k --max-time 5 "${HEADSCALE_URL}" > /dev/null 2>&1; do
    echo -n "."
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo ""
        echo "Error: Headscale did not become ready within ${MAX_WAIT}s."
        echo "SSH to check logs: ssh -i ~/.ssh/wg_ec2_ed25519 -p 50022 wgadmin@${EIP}"
        echo "Then run: journalctl -u headscale"
        exit 1
    fi
done

echo ""
echo "Headscale is ready at ${HEADSCALE_URL}"
echo ""
echo "=== 4. Starting Tailscale Client ==="
if command -v tailscale &>/dev/null; then
    echo "Connecting to Tailscale network..."
    sudo tailscale up --login-server "${HEADSCALE_URL}" --accept-routes
    
    echo ""
    echo "Verifying Tailscale connection..."
    MAX_WAIT=30; ELAPSED=0
    until tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' > /dev/null 2>&1; do
        echo -n "."
        sleep 2
        ELAPSED=$((ELAPSED + 2))
        if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
            echo ""
            echo "Warning: Tailscale did not come online within ${MAX_WAIT}s."
            echo "Check status with: tailscale status"
            break
        fi
    done
    
    if tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' > /dev/null 2>&1; then
        echo ""
        echo "Connection verified! Tailscale network is active."
        echo "Your Tailscale IP: $(tailscale ip -4 2>/dev/null || echo 'unknown')"
    fi
else
    echo "Tailscale client not installed. Install it and run 02-configure-clients.sh first."
fi
