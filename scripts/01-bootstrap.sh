#!/usr/bin/env bash
set -euo pipefail

echo "=== 1. Installing Local Dependencies ==="
MISSING_PKGS=()
command -v wg      &>/dev/null || MISSING_PKGS+=(wireguard-tools)
command -v aws     &>/dev/null || MISSING_PKGS+=(aws-cli-v2)
command -v qrencode &>/dev/null || MISSING_PKGS+=(qrencode)
command -v terraform &>/dev/null || MISSING_PKGS+=(terraform)
command -v jq      &>/dev/null || MISSING_PKGS+=(jq)

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing packages: ${MISSING_PKGS[*]}"
    sudo pacman -S --needed --noconfirm "${MISSING_PKGS[@]}"
else
    echo "All dependencies already installed. Skipping."
fi

AWS_VERSION=$(aws --version 2>&1 | grep -oP 'aws-cli/\K[0-9]+' || echo "0")
if [ "$AWS_VERSION" -lt 2 ]; then
    echo "Error: AWS CLI v2 is required. Current version: $(aws --version 2>&1)"
    exit 1
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
    User wgadmin
    Port 50022
    IdentityFile ${SSH_KEY_PATH}
EOF
    echo "Added 'wg-bastion' alias to ~/.ssh/config."
fi

echo "=== 4. Generating Server WireGuard Cryptography ==="
mkdir -p ~/wireguard-keys && chmod 700 ~/wireguard-keys && cd ~/wireguard-keys

umask 077
if [ ! -f "server.key" ]; then
    wg genkey > server.key  && wg pubkey < server.key  > server.pub
    echo "Server WireGuard keys generated."
else
    echo "Server WireGuard keys already exist. Skipping."
fi

echo "=== 5. Generating Default Peer Keys ==="
DEFAULT_PEERS=("desktop" "tablet" "smartphone")
for peer in "${DEFAULT_PEERS[@]}"; do
    if [ ! -f "${peer}.key" ]; then
        wg genkey > "${peer}.key" && wg pubkey < "${peer}.key" > "${peer}.pub"
        wg genpsk > "${peer}.psk"
        echo "Generated keys for ${peer}."
    else
        echo "Keys for ${peer} already exist. Skipping."
    fi
done

echo "=== 6. Creating Initial Peers Configuration ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"
PEERS_JSON="${TF_DIR}/peers.auto.tfvars.json"

if [ ! -f "${PEERS_JSON}" ]; then
    if ! jq -n \
      --arg desktop_pub "$(cat desktop.pub)" \
      --arg desktop_psk "$(cat desktop.psk)" \
      --arg tablet_pub "$(cat tablet.pub)" \
      --arg tablet_psk "$(cat tablet.psk)" \
      --arg smartphone_pub "$(cat smartphone.pub)" \
      --arg smartphone_psk "$(cat smartphone.psk)" \
      '{
        "wg_peers": {
          "desktop": {"public_key": $desktop_pub, "psk": $desktop_psk, "ip": "10.10.0.2"},
          "tablet": {"public_key": $tablet_pub, "psk": $tablet_psk, "ip": "10.10.0.3"},
          "smartphone": {"public_key": $smartphone_pub, "psk": $smartphone_psk, "ip": "10.10.0.4"}
        }
      }' > "${PEERS_JSON}.tmp"; then
        echo "Error: Failed to create ${PEERS_JSON}. Check that all key files are valid."
        rm -f "${PEERS_JSON}.tmp"
        exit 1
    fi
    mv "${PEERS_JSON}.tmp" "${PEERS_JSON}"
    chmod 600 "${PEERS_JSON}"
    echo "peers.auto.tfvars.json created with default peers."
else
    echo "peers.auto.tfvars.json already exists. Skipping."
fi

echo "=== 7. Writing Base Terraform Variables ==="
TFVARS="${TF_DIR}/terraform.tfvars"
if [ ! -f "${TFVARS}" ]; then
    cat <<EOF > "$TFVARS"
ssh_public_key        = "$(cat ${SSH_KEY_PATH}.pub)"
wg_server_private_key = "$(cat server.key)"
EOF
    chmod 600 "$TFVARS"
    echo "terraform.tfvars written with base server configurations."
else
    echo "terraform.tfvars already exists. Skipping."
fi
