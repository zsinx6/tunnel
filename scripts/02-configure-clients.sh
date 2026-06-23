#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 02-configure-clients.sh
# Retrieves live Terraform output and builds final client configurations.
# Run this from the repository root after 'terraform apply'.
# ==============================================================================

# Define mobile devices that need QR codes
MOBILE_CLIENTS=("tablet" "smartphone")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "Checking prerequisites..."
[ -f ~/wireguard-keys/server.pub ] || { echo "Error: Missing server pubkey."; exit 1; }

echo "Fetching Elastic IP from Terraform..."
EIP=$(terraform -chdir="${TF_DIR}" output -raw wg_elastic_ip)

if [ -z "$EIP" ] || [[ "$EIP" == *"No outputs found"* ]]; then
    echo "Error: Could not retrieve Elastic IP. Did 'terraform apply' succeed?"
    exit 1
fi

PHYS_IF=$(ip route list default | awk '{print $5}' | head -n 1)
if [ -z "$PHYS_IF" ]; then
    echo "Error: Could not detect default network interface."
    exit 1
fi
echo "Detected physical interface: ${PHYS_IF}"

echo "=== Configuring Desktop WireGuard (/etc/wireguard/wg0.conf) ==="
# Desktop remains hardcoded here due to the specific iptables routing requirements
if [ -f /etc/wireguard/wg0.conf ]; then
    read -r -p "WARNING: /etc/wireguard/wg0.conf already exists. Overwrite it? [y/N] " REPLY
    REPLY="${REPLY:-n}"
else
    REPLY="y"
fi

if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    if systemctl is-active --quiet wg-quick@wg0; then
        echo "Bringing WireGuard interface down..."
        sudo systemctl stop wg-quick@wg0
    fi

    sudo mkdir -p /etc/wireguard
    sudo bash -c "cat <<WGEOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $(cat ~/wireguard-keys/desktop.key)
Address = 10.10.0.2/24

PostUp   = iptables -I FORWARD -i wg0 -o ${PHYS_IF} -j DROP
PostDown = iptables -D FORWARD -i wg0 -o ${PHYS_IF} -j DROP

[Peer]
PublicKey    = $(cat ~/wireguard-keys/server.pub)
PresharedKey = $(cat ~/wireguard-keys/desktop.psk)
Endpoint     = ${EIP}:51920
AllowedIPs   = 10.10.0.0/24
PersistentKeepalive = 30
WGEOF"
    sudo chmod 600 /etc/wireguard/wg0.conf
    echo "Desktop configured securely."
fi

echo "=== Generating Mobile Configurations ==="
# Base IP offset starts at 3 (so tablet=10.10.0.3, smartphone=10.10.0.4)
IP_OFFSET=3

for client in "${MOBILE_CLIENTS[@]}"; do
    echo ""
    echo "--------------------------------------------------------"
    echo " Scan this QR code with your ${client^}'s WireGuard app:"
    echo "--------------------------------------------------------"
    echo ""
    
    qrencode -t ansiutf8 <<QREOF
[Interface]
PrivateKey = $(cat ~/wireguard-keys/${client}.key)
Address = 10.10.0.${IP_OFFSET}/24

[Peer]
PublicKey    = $(cat ~/wireguard-keys/server.pub)
PresharedKey = $(cat ~/wireguard-keys/${client}.psk)
Endpoint     = ${EIP}:51920
AllowedIPs   = 10.10.0.0/24
PersistentKeepalive = 25
QREOF
    
    ((IP_OFFSET++))
    
    # Pause to allow you to scan before clearing the screen
    read -r -p "Press [Enter] to continue to the next device..."
done
