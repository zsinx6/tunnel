#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 02-configure-clients.sh
# Retrieves live Terraform output and builds final client configurations.
# Run this from the repository root after 'terraform apply'.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "Checking prerequisites..."
for f in ~/wireguard-keys/desktop.key ~/wireguard-keys/desktop.psk \
          ~/wireguard-keys/tablet.key  ~/wireguard-keys/tablet.psk \
          ~/wireguard-keys/server.pub; do
    [ -f "$f" ] || { echo "Error: Missing key file: $f. Did 01-bootstrap.sh complete successfully?"; exit 1; }
done

echo "Fetching Elastic IP from Terraform..."
EIP=$(terraform -chdir="${TF_DIR}" output -raw wg_elastic_ip)

if [ -z "$EIP" ] || [[ "$EIP" == *"No outputs found"* ]]; then
    echo "Error: Could not retrieve Elastic IP. Did 'terraform apply' succeed?"
    exit 1
fi

# Detect the default physical egress interface at config-generation time.
# The value is hardcoded into wg0.conf — regenerate this config if you later
# change your primary interface (e.g. switch from eth to wlan permanently).
PHYS_IF=$(ip route list default | awk '{print $5}' | head -n 1)
if [ -z "$PHYS_IF" ]; then
    echo "Error: Could not detect default network interface."
    exit 1
fi
echo "Detected physical interface: ${PHYS_IF}"

echo "=== Configuring Desktop WireGuard (/etc/wireguard/wg0.conf) ==="

if [ -f /etc/wireguard/wg0.conf ]; then
    echo "WARNING: /etc/wireguard/wg0.conf already exists."
    read -r -p "Overwrite it? [y/N] " REPLY
    REPLY="${REPLY:-n}"
else
    REPLY="y"
fi

if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    if systemctl is-active --quiet wg-quick@wg0; then
        echo "WireGuard interface is active. Bringing it down to apply new configuration..."
        sudo systemctl stop wg-quick@wg0
    fi

    sudo mkdir -p /etc/wireguard
    sudo bash -c "cat <<WGEOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $(cat ~/wireguard-keys/desktop.key)
Address = 10.10.0.2/24
DNS = 1.1.1.1

# LAN isolation: block VPN traffic from being forwarded to the physical LAN.
# This prevents any VPN peer (e.g. tablet) from pivoting into the home network
# and reaching devices like the Raspberry Pi running Immich/Jellyfin.
# PHYS_IF is hardcoded at config-generation time — see comment above.
PostUp   = iptables -I FORWARD -i wg0 -o ${PHYS_IF} -j DROP
PostDown = iptables -D FORWARD -i wg0 -o ${PHYS_IF} -j DROP

[Peer]
PublicKey    = $(cat ~/wireguard-keys/server.pub)
PresharedKey = $(cat ~/wireguard-keys/desktop.psk)
Endpoint     = ${EIP}:51920
AllowedIPs   = 10.10.0.0/24
PersistentKeepalive = 25
WGEOF"
    sudo chmod 600 /etc/wireguard/wg0.conf
    echo "Desktop configured securely. LAN isolation rules embedded for interface: ${PHYS_IF}"
fi

echo "=== Generating Tablet Configuration ==="
echo "Scan this QR code with your Tablet's WireGuard app:"
echo ""
qrencode -t ansiutf8 <<QREOF
[Interface]
PrivateKey = $(cat ~/wireguard-keys/tablet.key)
Address = 10.10.0.3/24
DNS = 1.1.1.1

[Peer]
PublicKey    = $(cat ~/wireguard-keys/server.pub)
PresharedKey = $(cat ~/wireguard-keys/tablet.psk)
Endpoint     = ${EIP}:51920
AllowedIPs   = 10.10.0.0/24
PersistentKeepalive = 25
QREOF
