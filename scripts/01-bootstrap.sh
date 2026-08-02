#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"
TF_DIR="${SCRIPT_DIR}/../terraform"

echo "=== 1. Installing Local Dependencies ==="
MISSING_PKGS=()
command -v aws         &>/dev/null || MISSING_PKGS+=(aws-cli-v2)
command -v terraform   &>/dev/null || MISSING_PKGS+=(terraform)
command -v jq          &>/dev/null || MISSING_PKGS+=(jq)
command -v openssl     &>/dev/null || MISSING_PKGS+=(openssl)
command -v tailscale   &>/dev/null || MISSING_PKGS+=(tailscale)
command -v ethtool     &>/dev/null || MISSING_PKGS+=(ethtool)

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing packages: ${MISSING_PKGS[*]}"
    sudo pacman -S --needed --noconfirm "${MISSING_PKGS[@]}" || {
        echo "Error: pacman install failed. If 'terraform' is unavailable in the"
        echo "official repos, install it from the AUR (or use OpenTofu) and re-run."
        exit 1
    }
else
    echo "All dependencies already installed. Skipping."
fi

sudo systemctl enable --now tailscaled

AWS_VERSION=$(aws --version 2>&1 | grep -oP 'aws-cli/\K[0-9]+' || echo "0")
if [ "$AWS_VERSION" -lt 2 ]; then
    echo "Error: AWS CLI v2 is required. Current version: $(aws --version 2>&1)"
    exit 1
fi

echo "=== 2. Importing BYOK KMS Key for EBS ==="
bash "${SCRIPT_DIR}/00-import-kms-keys.sh"

echo "=== 3. Generating Dedicated SSH Key ==="
if [ ! -f "${SSH_KEY}.pub" ]; then
    echo "Generating dedicated ED25519 SSH key for the bastion."
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -C "wg-ec2-operator"
else
    echo "Dedicated SSH key already exists at ${SSH_KEY}. Skipping."
fi

echo "=== 4. Writing Terraform Variables ==="
KMS_KEYS_FILE="${TF_DIR}/kms_keys.auto.tfvars.json"
if [ ! -f "${KMS_KEYS_FILE}" ]; then
    echo "Error: ${KMS_KEYS_FILE} not found. Run 00-import-kms-keys.sh first."
    exit 1
fi

EBS_KEY_ID=$(jq -r '.kms_ebs_key_id // empty' "${KMS_KEYS_FILE}")
if [ -z "${EBS_KEY_ID}" ]; then
    echo "Error: ${KMS_KEYS_FILE} does not contain kms_ebs_key_id."
    exit 1
fi

prompt_domain() {
    echo ""
    echo "The relay needs a DNS name: Caddy uses it to get a Let's Encrypt TLS"
    echo "certificate, and all Tailscale clients connect to it."
    echo ""
    echo "Pick a subdomain of a domain you own — e.g. for zsinx6.dev, use:"
    echo "  hs.zsinx6.dev"
    echo ""
    echo "You do NOT need to change nameservers or move DNS providers. After"
    echo "'terraform apply' you will create ONE A record at your registrar"
    echo "(the exact record is printed by: terraform output dns_setup)."
    echo ""
    read -r -p "Headscale domain: " HEADSCALE_DOMAIN
    # Normalize common paste mistakes, then mirror the Terraform validation
    # so bad input fails here instead of at 'terraform apply'.
    HEADSCALE_DOMAIN="${HEADSCALE_DOMAIN,,}"
    HEADSCALE_DOMAIN="${HEADSCALE_DOMAIN#https://}"
    HEADSCALE_DOMAIN="${HEADSCALE_DOMAIN%/}"
    HEADSCALE_DOMAIN="${HEADSCALE_DOMAIN%.}"
    if ! [[ "${HEADSCALE_DOMAIN}" =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]{2,}$ ]]; then
        echo "Error: '${HEADSCALE_DOMAIN}' is not a valid DNS name (expected e.g. hs.zsinx6.dev)."
        exit 1
    fi
}

TFVARS="${TF_DIR}/terraform.tfvars"
if [ ! -f "${TFVARS}" ]; then
    prompt_domain
    cat <<EOF > "$TFVARS"
ssh_public_key   = "$(cat "${SSH_KEY}.pub")"
kms_ebs_key_id   = "${EBS_KEY_ID}"
headscale_domain = "${HEADSCALE_DOMAIN}"
EOF
    chmod 600 "$TFVARS"
    echo "terraform.tfvars written."
else
    # Existing tfvars (possibly from an older deployment): ensure every
    # variable this branch requires is present, without clobbering the rest.
    UPDATED=false
    if ! grep -q '^kms_ebs_key_id' "${TFVARS}"; then
        printf 'kms_ebs_key_id   = "%s"\n' "${EBS_KEY_ID}" >> "${TFVARS}"
        echo "kms_ebs_key_id added to terraform.tfvars."
        UPDATED=true
    fi
    if ! grep -q '^headscale_domain' "${TFVARS}"; then
        prompt_domain
        printf 'headscale_domain = "%s"\n' "${HEADSCALE_DOMAIN}" >> "${TFVARS}"
        echo "headscale_domain added to terraform.tfvars."
        UPDATED=true
    fi
    chmod 600 "$TFVARS"
    if [ "$UPDATED" = false ]; then
        echo "terraform.tfvars already up to date. Skipping."
    fi
fi

echo ""
echo "Bootstrap complete."
echo "Next steps:"
echo "  1. cd terraform && terraform init && terraform apply"
echo "  2. Point the DNS A record for your domain at the Elastic IP"
echo "     (terraform output wg_elastic_ip) — skip if you set route53_zone_id."
echo "  3. bash scripts/02-configure-clients.sh"
