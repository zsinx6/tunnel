#!/usr/bin/env bash
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <device_name>"
    echo "Example: $0 laptop"
    exit 1
fi

DEVICE="${1,,}"
if [[ ! "$DEVICE" =~ ^[a-z0-9-]+$ ]]; then
    echo "Error: Device name must contain only lowercase letters, numbers, and hyphens."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PEERS_JSON="${SCRIPT_DIR}/../terraform/peers.auto.tfvars.json"
KEYS_DIR="$HOME/wireguard-keys"

command -v jq &>/dev/null || { echo "Error: 'jq' is required. Run: sudo pacman -S jq"; exit 1; }
command -v qrencode &>/dev/null || { echo "Error: 'qrencode' is required. Run: sudo pacman -S qrencode"; exit 1; }

mkdir -p "${KEYS_DIR}"
cd "${KEYS_DIR}"

cleanup() {
    if [ -f "${KEYS_DIR}/tmp.json" ]; then
        rm -f "${KEYS_DIR}/tmp.json"
    fi
}
trap cleanup EXIT

if [ -f "${DEVICE}.key" ]; then
    echo "Error: Keys for '${DEVICE}' already exist in ${KEYS_DIR}."
    exit 1
fi

if [ -f "${PEERS_JSON}" ]; then
    if ! jq empty "${PEERS_JSON}" 2>/dev/null; then
        echo "Error: ${PEERS_JSON} is not valid JSON. Please fix it before adding a device."
        exit 1
    fi
    
    if jq -e ".wg_peers[\"${DEVICE}\"]" "${PEERS_JSON}" > /dev/null; then
        echo "Error: Device '${DEVICE}' already exists in ${PEERS_JSON}."
        exit 1
    fi
fi

echo "=== Generating Keys for ${DEVICE} ==="
umask 077
wg genkey > "${DEVICE}.key" && wg pubkey < "${DEVICE}.key" > "${DEVICE}.pub"
wg genpsk > "${DEVICE}.psk"

PUB_KEY=$(cat "${DEVICE}.pub")
PSK_KEY=$(cat "${DEVICE}.psk")

echo "=== Updating Terraform Peers State ==="
if [ ! -f "${PEERS_JSON}" ] || [ ! -s "${PEERS_JSON}" ]; then
    echo '{"wg_peers": {}}' > "${PEERS_JSON}"
fi

LAST_OCTET=$(jq -r 'if (.wg_peers | length) == 0 then 1 else [.wg_peers[].ip | split(".")[3] | tonumber] | max end' "${PEERS_JSON}")
NEXT_OCTET=$((LAST_OCTET + 1))

if [ "$NEXT_OCTET" -gt 254 ]; then
    echo "Error: No available IPs in 10.10.0.0/24 subnet (max 252 peers)."
    rm -f "${DEVICE}.key" "${DEVICE}.pub" "${DEVICE}.psk"
    exit 1
fi

if jq -e --arg ip "10.10.0.${NEXT_OCTET}" '.wg_peers[] | select(.ip == $ip)' "${PEERS_JSON}" > /dev/null 2>&1; then
    echo "Error: IP 10.10.0.${NEXT_OCTET} is already in use. Check ${PEERS_JSON} for conflicts."
    rm -f "${DEVICE}.key" "${DEVICE}.pub" "${DEVICE}.psk"
    exit 1
fi

NEW_IP="10.10.0.${NEXT_OCTET}"

umask 077
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

cat << EOF
bash -c 'echo "[Interface]
PrivateKey = \$(cat ~/wireguard-keys/${DEVICE}.key)
Address = ${NEW_IP}/24

[Peer]
PublicKey    = \$(cat ~/wireguard-keys/server.pub)
PresharedKey = \$(cat ~/wireguard-keys/${DEVICE}.psk)
Endpoint     = \$(terraform -chdir=${SCRIPT_DIR}/../terraform output -raw wg_elastic_ip):51920
AllowedIPs   = 10.10.0.0/24
PersistentKeepalive = 25" | qrencode -t ansiutf8'
EOF
echo ""
