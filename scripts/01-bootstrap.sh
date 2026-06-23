#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 01-bootstrap.sh
# Prepares local keys, SSH alias, and Terraform variables. 
# Safe to re-run (idempotent).
# ==============================================================================

# Define your clients here! Just add to this list to provision new devices.
CLIENTS=("desktop" "tablet" "smartphone")

echo "=== 1. Installing Local Dependencies ==="
MISSING_PKGS=()
command -v wg      &>/dev/null || MISSING_PKGS+=(wireguard-tools)
command -v aws     &>/dev/null || MISSING_PKGS+=(aws-cli-v2)
command -v qrencode &>/dev/null || MISSING_PKGS+=(qrencode)
command -v terraform &>/dev/null || MISSING_PKGS+=(terraform)

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing packages: ${MISSING_PKGS[*]}"
    sudo pacman -S --needed --noconfirm "${MISSING_PKGS[@]}"
else
    echo "All dependencies already installed. Skipping."
fi

echo "=== 2. Generating Dedicated SSH Key ==="
SSH_KEY_PATH="$HOME/.ssh/wg_ec2_ed25519"

if [ ! -f "${SSH_KEY_PATH}.pub" ]; then
    echo "Generating dedicated ED25519 SSH key for the bastion."
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

# Ensure secure file creation
umask 077

# Server Keys
if [ ! -f "server.key" ]; then
    wg genkey > server.key && wg pubkey < server.key > server.pub
    echo "Server keys generated."
fi

# Client Keys
for client in "${CLIENTS[@]}"; do
    if [ ! -f "${client}.key" ]; then
        wg genkey > "${client}.key" && wg pubkey < "${client}.key" > "${client}.pub"
        wg genpsk > "${client}.psk"
        echo "Keys generated for new client: ${client}"
    fi
done

echo "=== 5. Writing Terraform Variables ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"
mkdir -p "${TF_DIR}"

TFVARS="${TF_DIR}/terraform.tfvars"

# Overwriting tfvars safely ensures new clients are injected
cat <<EOF > "$TFVARS"
ssh_public_key        = "$(cat ${SSH_KEY_PATH}.pub)"
wg_server_private_key = "$(cat server.key)"
EOF

for client in "${CLIENTS[@]}"; do
    echo "wg_${client}_public_key = \"$(cat ${client}.pub)\"" >> "$TFVARS"
    echo "wg_${client}_psk        = \"$(cat ${client}.psk)\"" >> "$TFVARS"
done

chmod 600 "$TFVARS"
echo "terraform.tfvars successfully updated with all current clients."

echo "Bootstrap complete. Next steps:"
echo "1. Update your Terraform .tf files to accept the new variables."
echo "2. cd terraform && terraform apply"
