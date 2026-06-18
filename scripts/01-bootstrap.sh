#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 01-bootstrap.sh
# Prepares local keys, SSH alias, and Terraform variables. 
# Safe to re-run (idempotent).
# ==============================================================================

echo "=== 1. Installing Local Dependencies ==="
sudo pacman -Syu --needed wireguard-tools aws-cli qrencode terraform

echo "=== 2. Generating Dedicated SSH Key ==="
SSH_KEY_PATH="$HOME/.ssh/wg_ec2_ed25519"

if [ ! -f "${SSH_KEY_PATH}.pub" ]; then
    echo "Generating dedicated ED25519 SSH key for the bastion."
    echo "CRITICAL: Enter a strong passphrase when prompted."
    ssh-keygen -t ed25519 -f "${SSH_KEY_PATH}" -C "wg-ec2-operator"
else
    echo "Dedicated SSH key already exists at ${SSH_KEY_PATH}. Skipping."
fi

echo "=== 3. Configuring Local SSH Alias ==="
mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/config && chmod 600 ~/.ssh/config
if ! grep -q "Host wg-bastion" ~/.ssh/config; then
cat <<EOF >> ~/.ssh/config

Host wg-bastion
    HostName 10.10.0.1
    User operator
    Port 50022
    IdentityFile ${SSH_KEY_PATH}
EOF
    echo "Added 'wg-bastion' alias to ~/.ssh/config."
fi

echo "=== 4. Generating WireGuard Cryptography ==="
mkdir -p ~/wireguard-keys && chmod 700 ~/wireguard-keys && cd ~/wireguard-keys

if [ ! -f "server.key" ]; then
    wg genkey > server.key  && wg pubkey < server.key  > server.pub
    wg genkey > desktop.key && wg pubkey < desktop.key > desktop.pub
    wg genkey > tablet.key  && wg pubkey < tablet.key  > tablet.pub
    # Preshared keys add a post-quantum symmetric layer on top of Curve25519
    wg genpsk > desktop.psk
    wg genpsk > tablet.psk
    chmod 600 server.key desktop.key tablet.key desktop.psk tablet.psk
    echo "WireGuard keys and preshared keys generated."
else
    echo "WireGuard keys already exist in ~/wireguard-keys. Skipping generation."
fi

echo "=== 5. Writing Terraform Variables ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"
mkdir -p "${TF_DIR}"

TFVARS="${TF_DIR}/terraform.tfvars"
if [ -f "$TFVARS" ]; then
    echo "terraform.tfvars already exists. Skipping to avoid overwriting existing deployment."
    echo "Delete ${TFVARS} manually and re-run if you want to regenerate it."
else
    cat <<EOF > "$TFVARS"
ssh_public_key        = "$(cat ${SSH_KEY_PATH}.pub)"
wg_server_private_key = "$(cat server.key)"
wg_desktop_public_key = "$(cat desktop.pub)"
wg_tablet_public_key  = "$(cat tablet.pub)"
wg_desktop_psk        = "$(cat desktop.psk)"
wg_tablet_psk         = "$(cat tablet.psk)"
EOF
    chmod 600 "$TFVARS"
    echo "terraform.tfvars written."
fi

echo "Bootstrap complete. Proceed to run: cd terraform && terraform init && terraform apply"
