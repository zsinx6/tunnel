#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# add-device.sh <device_name>
# Dynamically generates keys, assigns the next IP, and injects into Terraform.
# ==============================================================================

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <device_name>"
    echo "Example: $0 laptop"
    exit 1
fi

DEVICE="${1,,}" # Convert to lowercase
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PEERS_JSON="${SCRIPT_DIR}/../terraform/peers.auto.tfvars.json"
KEYS_DIR="$HOME/wireguard-keys"

command -v jq &>/dev/null || { echo "Error: 'jq' is required. Run: sudo pacman -S jq"; exit 1; }

mkdir -p "${KEYS_DIR}"
cd "${KEYS_DIR}"

if [ -f "${DEVICE}.key" ]; then
    echo "Error: Keys for '${DEVICE}' already exist in ${KEYS_DIR}."
    exit 1
fi

echo "=== Generating Keys for ${DEVICE} ==="
umask 077
wg genkey > "${DEVICE}.key" && wg pubkey < "${DEVICE}.key" > "${DEVICE}.pub"
wg genpsk > "${DEVICE}.psk"

PUB_KEY=$(cat "${DEVICE}.pub")
PSK_KEY=$(cat "${DEVICE}.psk")

echo "=== Updating Terraform Peers State ==="
if [ ! -f "${PEERS_JSON}" ]; then
    echo '{"wg_peers": {}}' > "${PEERS_JSON}"
fi

if jq -e ".wg_peers[\"${DEVICE}\"]" "${PEERS_JSON}" > /dev/null; then
    echo "Error: Device '${DEVICE}' already exists in ${PEERS_JSON}."
    exit 1
fi

# Calculate the next available IP address automatically
LAST_OCTET=$(jq -r 'if (.wg_peers | length) == 0 then 1 else [.wg_peers[].ip | split(".")[3] | tonumber] | max end' "${PEERS_JSON}")
NEXT_OCTET=$((LAST_OCTET + 1))
NEW_IP="10.10.0.${NEXT_OCTET}"

# Inject the new device into the JSON file
jq --arg dev "$DEVICE" \
   --arg pub "$PUB_KEY" \
   --arg psk "$PSK_KEY" \
   --arg ip "$NEW_IP" \
   '.wg_peers[$dev] = {"public_key": $pub, "psk": $psk, "ip": $ip}' "${PEERS_JSON}" > tmp.json && mv tmp.json "${PEERS_JSON}"

echo "Successfully added ${DEVICE} with IP ${NEW_IP} to ${PEERS_JSON}."
echo ""
echo "=== NEXT STEPS ==="
echo "1. cd terraform && terraform apply"
echo "2. Generate your QR code by running this exact command:"
echo ""

# We use cat << EOF here just to print the block below to the terminal cleanly
cat << EOF
echo "[Interface]
PrivateKey = \$(cat ~/wireguard-keys/${DEVICE}.key)
Address = ${NEW_IP}/24

[Peer]
PublicKey    = \$(cat ~/wireguard-keys/server.pub)
PresharedKey = \$(cat ~/wireguard-keys/${DEVICE}.psk)
Endpoint     = \$(terraform -chdir=${SCRIPT_DIR}/../terraform output -raw wg_elastic_ip):51920
AllowedIPs   = 10.10.0.0/24
PersistentKeepalive = 25" | qrencode -t ansiutf8
EOF
echo ""
