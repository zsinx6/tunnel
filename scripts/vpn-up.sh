#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"

HEADSCALE_URL=$(terraform -chdir="${TF_DIR}" output -raw headscale_url 2>/dev/null) || {
    echo "Error: could not read headscale_url output. Did 'terraform apply' succeed?"
    exit 1
}

# Any failure after the instance starts must not go unnoticed: a running
# instance bills until stopped.
INSTANCE_STARTED=false
INSTANCE_ID=""
on_exit() {
    local status=$?
    if [ "$status" -ne 0 ] && [ "$INSTANCE_STARTED" = true ]; then
        echo ""
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "!! vpn-up FAILED but instance ${INSTANCE_ID} IS STILL RUNNING !!"
        echo "!! It bills until stopped. Run: bash scripts/vpn-down.sh      !!"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    fi
}
trap on_exit EXIT

echo "=== 1. Locating Tailscale Bastion on AWS ==="
INSTANCE_IDS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_TAG}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)

COUNT=$(wc -w <<< "${INSTANCE_IDS}")
if [ "$COUNT" -eq 0 ]; then
    echo "Error: Could not find an instance tagged '${INSTANCE_TAG}'."
    exit 1
elif [ "$COUNT" -gt 1 ]; then
    echo "Error: found ${COUNT} instances tagged '${INSTANCE_TAG}': ${INSTANCE_IDS}"
    echo "Refusing to guess. Clean up the duplicates first."
    exit 1
fi
INSTANCE_ID="${INSTANCE_IDS}"

echo "=== 2. Waking Cloud Infrastructure ==="
INSTANCE_STATE=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text)

case "$INSTANCE_STATE" in
    running)
        echo "Instance is already running."
        INSTANCE_STARTED=true
        ;;
    pending)
        echo "Instance is already starting. Waiting for it to be ready..."
        INSTANCE_STARTED=true
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
        ;;
    stopping)
        echo "Instance is still stopping. Waiting for it to fully stop..."
        aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
        echo "Starting EC2 Bastion ($INSTANCE_ID)..."
        INSTANCE_STARTED=true
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
        ;;
    stopped)
        echo "Starting EC2 Bastion ($INSTANCE_ID)..."
        INSTANCE_STARTED=true
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
        ;;
    *)
        echo "Error: Instance is in unexpected state '$INSTANCE_STATE'. Aborting."
        exit 1
        ;;
esac

echo "=== 3. Waiting for Headscale to be ready ==="
# The HTTP health probe (with TLS verification against the Let's Encrypt cert)
# proves end-to-end readiness, so no slow instance-status-ok waiter is needed.
MAX_WAIT=300; ELAPSED=0
until curl -fsS --max-time 5 "${HEADSCALE_URL}/health" > /dev/null 2>&1; do
    echo -n "."
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo ""
        echo "Error: Headscale did not become ready within ${MAX_WAIT}s."
        EIP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
            --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
        echo "SSH to check logs: ssh -i ${SSH_KEY} -p ${SSH_PORT} ${SSH_USER}@${EIP}"
        echo "Then run: sudo tunnel-logs"
        exit 1
    fi
done

echo ""
echo "Headscale is ready at ${HEADSCALE_URL}"
echo ""
echo "=== 4. Starting Tailscale Client ==="
if ! command -v tailscale &>/dev/null; then
    echo "Error: Tailscale client not installed. Run 01-bootstrap.sh first."
    exit 1
fi

echo "Connecting to Tailscale network..."
# --timeout prevents an indefinite hang if the node key has expired (Headscale
# default: 180 days) and interactive re-auth would be required.
# When a LAN host is exposed (config.local.sh), --advertise-routes must repeat
# the route: 'tailscale up' rejects a call that omits a non-default
# preference. Harmless before the route is approved (03-lan-services.sh).
TS_UP_ARGS=(--login-server "${HEADSCALE_URL}" --accept-routes --timeout 30s)
if [ -n "${LAN_SERVICES_ROUTE}" ]; then
    TS_UP_ARGS+=(--advertise-routes "${LAN_SERVICES_ROUTE}")
else
    # No LAN route is configured now. If an earlier run stored one, 'tailscale
    # up' refuses to drop that preference unless the command repeats it. Clear
    # the leftover first, so this call does not fail after the instance started.
    STALE_ROUTES=$(tailscale debug prefs 2>/dev/null \
        | jq -r '.AdvertiseRoutes // [] | join(",")' 2>/dev/null || true)
    if [ -n "${STALE_ROUTES}" ]; then
        echo "Clearing a stale advertised route (${STALE_ROUTES})..."
        sudo tailscale set --advertise-routes= || true
    fi
fi
if ! sudo tailscale up "${TS_UP_ARGS[@]}"; then
    echo ""
    echo "Error: 'tailscale up' failed. If the node key expired, re-register:"
    echo "  bash scripts/02-configure-clients.sh"
    exit 1
fi

echo ""
echo "Verifying Tailscale connection..."
MAX_WAIT=30; ELAPSED=0
until tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' > /dev/null 2>&1; do
    echo -n "."
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo ""
        echo "Error: Tailscale did not come online within ${MAX_WAIT}s."
        echo "Check status with: tailscale status"
        exit 1
    fi
done

echo ""
echo "Connection verified! Tailscale network is active."
echo "Your Tailscale IP: $(tailscale ip -4 2>/dev/null || echo 'unknown')"

if [ -n "${LAN_SERVICES_HOST}" ]; then
    echo ""
    print_lan_services
    echo "(If not set up yet, enable remote access with: bash scripts/03-lan-services.sh)"
fi
