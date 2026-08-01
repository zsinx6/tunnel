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
DOMAIN="${HEADSCALE_URL#https://}"

if ! command -v tailscale &>/dev/null; then
    echo "Error: Tailscale client not installed. Run 01-bootstrap.sh first."
    exit 1
fi

echo "=== Checking DNS ==="
RESOLVED=$(getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1; exit}' || true)
if [ -z "${RESOLVED}" ]; then
    echo "Error: ${DOMAIN} does not resolve yet."
    echo ""
    echo "One-time setup — in your registrar's DNS panel, create this record:"
    echo "  Type:  A"
    echo "  Name:  ${DOMAIN}   (some panels want only the subdomain part, e.g. '${DOMAIN%%.*}')"
    echo "  Value: ${EIP}"
    echo "  TTL:   300 (or the panel's default)"
    echo ""
    echo "Wait 1-5 minutes for propagation, verify with:"
    echo "  dig +short ${DOMAIN}    # must print ${EIP}"
    echo "then re-run this script."
    echo "(Alternatively: host DNS in Route53 and set route53_zone_id in terraform.tfvars.)"
    exit 1
elif [ "${RESOLVED}" != "${EIP}" ]; then
    echo "Warning: ${DOMAIN} resolves to ${RESOLVED}, expected ${EIP}."
    echo "If you just updated DNS this may be caching; TLS will fail until it matches."
fi

echo "=== Ensuring EC2 is running ==="
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

INSTANCE_STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].State.Name" --output text)
case "$INSTANCE_STATE" in
    running) ;;
    pending)
        echo "Instance is starting. Waiting..."
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
        ;;
    stopping)
        echo "Instance is stopping. Waiting for it to stop, then restarting..."
        aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
        ;;
    stopped)
        echo "Starting EC2 instance..."
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
        ;;
    *)
        echo "Error: instance in unexpected state '${INSTANCE_STATE}'."
        exit 1
        ;;
esac

echo "=== Waiting for Headscale (with valid TLS) ==="
MAX_WAIT=300; ELAPSED=0
until curl -fsS --max-time 5 "${HEADSCALE_URL}/health" > /dev/null 2>&1; do
    echo -n "."
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo ""
        echo "Error: ${HEADSCALE_URL}/health not ready within ${MAX_WAIT}s."
        echo "On first boot this can mean the Let's Encrypt certificate is not"
        echo "issued yet (DNS must point at ${EIP}). Diagnose with:"
        echo "  ssh -i ${SSH_KEY} -p ${SSH_PORT} ${SSH_USER}@${EIP} sudo tunnel-logs"
        exit 1
    fi
done
echo ""
echo "Headscale is ready at ${HEADSCALE_URL}"

echo "=== Checking existing registration ==="
if tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' > /dev/null 2>&1; then
    CONTROL_URL=$(tailscale debug prefs 2>/dev/null | jq -r '.ControlURL // empty' || true)
    if [ "${CONTROL_URL%/}" = "${HEADSCALE_URL%/}" ]; then
        echo "Desktop is already registered with ${HEADSCALE_URL} and online."
        exit 0
    fi
    echo "Warning: this machine is online against a DIFFERENT control server:"
    echo "  ${CONTROL_URL:-unknown}"
    echo "Refusing to switch it silently. To move it to ${HEADSCALE_URL}, run:"
    ADVERTISE_HINT=""
    if [ -n "${LAN_SERVICES_ROUTE}" ]; then
        ADVERTISE_HINT=" --advertise-routes ${LAN_SERVICES_ROUTE}"
    fi
    echo "  sudo tailscale up --login-server ${HEADSCALE_URL} --accept-routes${ADVERTISE_HINT} --force-reauth"
    exit 1
fi

echo "=== Generating one-time auth key ==="
SSH_ERR=$(mktemp)
trap 'rm -f "${SSH_ERR}"' EXIT

USERS_JSON=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
    "sudo headscale users list --output json" 2>"${SSH_ERR}") || {
    echo "Error: SSH to the instance failed:"
    cat "${SSH_ERR}"
    echo "If the instance was re-provisioned, clear the old host key first:"
    echo "  ssh-keygen -R '[${EIP}]:${SSH_PORT}'"
    exit 1
}
USER_ID=$(echo "${USERS_JSON}" | jq -r '.[] | select(.name == "default") | .id // empty')
if [ -z "${USER_ID}" ]; then
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

# One-time, short-lived key: harmless in shell history / process listings
# after its single use or 15-minute expiry.
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
echo "Auth key generated (single-use, expires in 15 minutes)."

echo "=== Registering desktop with Headscale ==="
KEY_FILE=$(mktemp)
trap 'rm -f "${SSH_ERR}" "${KEY_FILE}"' EXIT
chmod 600 "${KEY_FILE}"
printf '%s' "${AUTH_KEY}" > "${KEY_FILE}"

# When a LAN host is exposed (config.local.sh), --advertise-routes must repeat
# the route: 'tailscale up' rejects a call that omits a non-default
# preference. Harmless before the route is approved (03-lan-services.sh).
TS_UP_ARGS=(
    --login-server "${HEADSCALE_URL}"
    --auth-key "file:${KEY_FILE}"
    --accept-routes
    --timeout 60s
)
if [ -n "${LAN_SERVICES_ROUTE}" ]; then
    TS_UP_ARGS+=(--advertise-routes "${LAN_SERVICES_ROUTE}")
else
    # Clear any route an earlier run stored, so 'tailscale up' does not refuse
    # to drop an unmentioned preference (same guard as vpn-up.sh).
    STALE_ROUTES=$(tailscale debug prefs 2>/dev/null \
        | jq -r '.AdvertiseRoutes // [] | join(",")' 2>/dev/null || true)
    if [ -n "${STALE_ROUTES}" ]; then
        echo "Clearing a stale advertised route (${STALE_ROUTES})..."
        sudo tailscale set --advertise-routes= || true
    fi
fi
sudo tailscale up "${TS_UP_ARGS[@]}"
rm -f "${KEY_FILE}"

echo ""
echo "Desktop registered successfully."
echo "Your Tailscale IP: $(tailscale ip -4 2>/dev/null || echo 'unknown')"
if [ -n "${LAN_SERVICES_HOST}" ]; then
    echo ""
    echo "Registration created a new Headscale node, so the home-services route"
    echo "needs (re-)approval. If you use it, run:"
    echo "  bash scripts/03-lan-services.sh"
fi

echo ""
echo "=== Mobile Devices ==="
echo ""
echo "The official Tailscale app supports custom coordination servers:"
echo ""
echo "  Android: Settings -> Accounts menu -> 'Use an alternate server'"
echo "  iOS:     Settings -> Alternate Coordination Server URL"
echo ""
echo "  1. Enter: ${HEADSCALE_URL}"
echo "  2. Tap Sign In — a browser page opens showing a registration command,"
echo "     e.g. on Headscale 0.29:"
echo "       headscale auth register --auth-id hskey-authreq-... --user USERNAME"
echo "  3. Run it on the server via SSH, with sudo and USERNAME replaced by 'default':"
echo "     ssh -i ${SSH_KEY} -p ${SSH_PORT} ${SSH_USER}@${EIP} \\"
echo "       \"sudo headscale auth register --auth-id hskey-authreq-... --user default\""
echo ""
echo "Alternative (Android): skip the browser flow — generate a key with"
echo "scripts/add-device.sh and use the app's 'Use auth key' sign-in option."
echo ""
echo "No certificate installation is needed — the server uses a publicly"
echo "trusted Let's Encrypt certificate."
