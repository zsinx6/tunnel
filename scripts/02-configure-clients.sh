#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
PEERS_JSON="${TF_DIR}/peers.auto.tfvars.json"

command -v jq &>/dev/null || { echo "Error: 'jq' is required. Run: sudo pacman -S jq"; exit 1; }

if [ ! -f "${PEERS_JSON}" ]; then
    echo "Error: ${PEERS_JSON} not found. Run 01-bootstrap.sh first."
    exit 1
fi

if ! jq empty "${PEERS_JSON}" 2>/dev/null; then
    echo "Error: ${PEERS_JSON} is not valid JSON."
    exit 1
fi

if ! jq -e '.wg_peers.desktop' "${PEERS_JSON}" &>/dev/null; then
    echo "Error: No 'desktop' entry found in ${PEERS_JSON}."
    exit 1
fi

PEER_COUNT=$(jq -r '.wg_peers | keys | length' "${PEERS_JSON}")
if [ "$PEER_COUNT" -eq 0 ]; then
    echo "Error: No peers defined in ${PEERS_JSON}."
    exit 1
fi

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
    
    DESKTOP_IP=$(jq -r '.wg_peers.desktop.ip' "${PEERS_JSON}")
    if [ -z "$DESKTOP_IP" ] || [ "$DESKTOP_IP" = "null" ]; then
        echo "Error: Desktop IP not found in ${PEERS_JSON}."
        exit 1
    fi
    
    if [ ! -f ~/wireguard-keys/desktop.key ]; then
        echo "Error: ~/wireguard-keys/desktop.key not found."
        exit 1
    fi
    
    DESKTOP_KEY=$(cat ~/wireguard-keys/desktop.key)
    SERVER_PUB=$(cat ~/wireguard-keys/server.pub)
    DESKTOP_PSK=$(cat ~/wireguard-keys/desktop.psk)
    
    sudo bash -c "cat <<WGEOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = ${DESKTOP_KEY}
Address = ${DESKTOP_IP}/24

PostUp   = iptables -I FORWARD -i wg0 -o ${PHYS_IF} -j DROP
PostDown = iptables -D FORWARD -i wg0 -o ${PHYS_IF} -j DROP

[Peer]
PublicKey    = ${SERVER_PUB}
PresharedKey = ${DESKTOP_PSK}
Endpoint     = ${EIP}:51920
AllowedIPs   = 10.10.0.0/24
PersistentKeepalive = 30
WGEOF"
    sudo chmod 600 /etc/wireguard/wg0.conf
    echo "Desktop configured securely."
fi

echo "=== Generating Mobile Configurations ==="

MOBILE_CLIENTS=$(jq -r '.wg_peers | to_entries[] | select(.key != "desktop") | .key' "${PEERS_JSON}")

if [ -z "$MOBILE_CLIENTS" ]; then
    echo "No mobile clients found in ${PEERS_JSON}."
    exit 0
fi

for client in $MOBILE_CLIENTS; do
    CLIENT_IP=$(jq -r ".wg_peers.${client}.ip" "${PEERS_JSON}")
    
    if [ -z "$CLIENT_IP" ] || [ "$CLIENT_IP" = "null" ]; then
        echo "Warning: No IP found for ${client} in ${PEERS_JSON}, skipping."
        continue
    fi
    
    if [ ! -f ~/wireguard-keys/${client}.key ]; then
        echo "Warning: Key file for ${client} not found, skipping."
        continue
    fi
    
    echo ""
    echo "--------------------------------------------------------"
    echo " Scan this QR code with your ${client^}'s WireGuard app:"
    echo "--------------------------------------------------------"
    echo ""
    
    CLIENT_KEY=$(cat ~/wireguard-keys/${client}.key)
    SERVER_PUB=$(cat ~/wireguard-keys/server.pub)
    CLIENT_PSK=$(cat ~/wireguard-keys/${client}.psk)
    
    qrencode -t ansiutf8 <<QREOF
[Interface]
PrivateKey = ${CLIENT_KEY}
Address = ${CLIENT_IP}/24

[Peer]
PublicKey    = ${SERVER_PUB}
PresharedKey = ${CLIENT_PSK}
Endpoint     = ${EIP}:51920
AllowedIPs   = 10.10.0.0/24
PersistentKeepalive = 25
QREOF
    
    read -r -p "Press [Enter] to continue to the next device..."
done
