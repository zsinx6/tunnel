#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== 1. Installing Local Dependencies ==="
MISSING_PKGS=()
command -v aws         &>/dev/null || MISSING_PKGS+=(aws-cli-v2)
command -v terraform   &>/dev/null || MISSING_PKGS+=(terraform)
command -v jq          &>/dev/null || MISSING_PKGS+=(jq)
command -v openssl     &>/dev/null || MISSING_PKGS+=(openssl)

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing packages: ${MISSING_PKGS[*]}"
    sudo pacman -S --needed --noconfirm "${MISSING_PKGS[@]}"
else
    echo "All dependencies already installed. Skipping."
fi

if ! command -v tailscale &>/dev/null; then
    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi

AWS_VERSION=$(aws --version 2>&1 | grep -oP 'aws-cli/\K[0-9]+' || echo "0")
if [ "$AWS_VERSION" -lt 2 ]; then
    echo "Error: AWS CLI v2 is required. Current version: $(aws --version 2>&1)"
    exit 1
fi

echo "=== 2. Importing BYOK KMS Key for EBS ==="
bash "${SCRIPT_DIR}/00-import-kms-keys.sh"

echo "=== 3. Generating Dedicated SSH Key ==="
SSH_KEY_PATH="$HOME/.ssh/wg_ec2_ed25519"

if [ ! -f "${SSH_KEY_PATH}.pub" ]; then
    echo "Generating dedicated ED25519 SSH key for the bastion."
    ssh-keygen -t ed25519 -f "${SSH_KEY_PATH}" -C "wg-ec2-operator"
else
    echo "Dedicated SSH key already exists at ${SSH_KEY_PATH}. Skipping."
fi

echo "=== 4. Writing Terraform Variables ==="
KMS_KEYS_FILE="${TF_DIR}/kms_keys.auto.tfvars.json"
if [ ! -f "${KMS_KEYS_FILE}" ]; then
    echo "Error: ${KMS_KEYS_FILE} not found. Run 00-import-kms-keys.sh first."
    exit 1
fi

EBS_KEY_ID=$(jq -r '.kms_ebs_key_id' "${KMS_KEYS_FILE}")

TFVARS="${TF_DIR}/terraform.tfvars"
if [ ! -f "${TFVARS}" ]; then
    cat <<EOF > "$TFVARS"
ssh_public_key = "$(cat ${SSH_KEY_PATH}.pub)"
kms_ebs_key_id = "${EBS_KEY_ID}"
EOF
    chmod 600 "$TFVARS"
    echo "terraform.tfvars written."
else
    echo "terraform.tfvars already exists. Skipping."
fi

echo ""
echo "Bootstrap complete."
echo "Next steps:"
echo "  1. cd terraform && terraform init && terraform apply"
echo "  2. bash scripts/02-configure-clients.sh"
