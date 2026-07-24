#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
KMS_KEYS_FILE="${TF_DIR}/kms_keys.auto.tfvars.json"
KMS_MATERIAL_DIR="$HOME/wireguard-keys/kms"

if [ -f "${KMS_KEYS_FILE}" ]; then
    echo "KMS keys already configured at ${KMS_KEYS_FILE}. Skipping."
    exit 0
fi

command -v openssl &>/dev/null || { echo "Error: 'openssl' is required."; exit 1; }

echo "=== 1. Generating local key material ==="
mkdir -p "${KMS_MATERIAL_DIR}"
umask 077

openssl rand 32 > "${KMS_MATERIAL_DIR}/ebs_key_material.bin"
echo "Generated 256-bit key material for EBS."

echo "=== 2. Creating KMS key (EXTERNAL origin) ==="

EBS_KEY_ID=$(aws kms create-key \
    --region "$REGION" \
    --origin EXTERNAL \
    --description "wg-bastion EBS BYOK" \
    --query "KeyMetadata.KeyId" \
    --output text)
echo "Created EBS KMS key: ${EBS_KEY_ID}"

echo "=== 3. Importing key material ==="

import_key_material() {
    local key_id="$1"
    local material_file="$2"
    local label="$3"

    local tmpdir
    tmpdir=$(mktemp -d)

    aws kms get-parameters-for-import \
        --key-id "$key_id" \
        --wrapping-key-algorithm RSAES_OAEP_SHA_256 \
        --region "$REGION" > "${tmpdir}/params.json"

    jq -r '.PublicKey' "${tmpdir}/params.json" | base64 -d > "${tmpdir}/wrapping_key.pem"
    jq -r '.ImportToken' "${tmpdir}/params.json" | base64 -d > "${tmpdir}/import_token.bin"

    openssl pkeyutl -encrypt \
        -pkeyopt rsa_padding_mode:oaep \
        -pkeyopt rsa_oaep_md:sha256 \
        -pkeyopt rsa_mgf1_md:sha256 \
        -pubin -inkey "${tmpdir}/wrapping_key.pem" \
        -in "$material_file" \
        -out "${tmpdir}/encrypted_material.bin"

    aws kms import-key-material \
        --key-id "$key_id" \
        --encrypted-key-material "fileb://${tmpdir}/encrypted_material.bin" \
        --import-token "fileb://${tmpdir}/import_token.bin" \
        --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE \
        --region "$REGION"

    rm -rf "${tmpdir}"
    echo "Imported key material for ${label}."
}

import_key_material "$EBS_KEY_ID" "${KMS_MATERIAL_DIR}/ebs_key_material.bin" "EBS"

echo "=== 4. Writing KMS key ID for Terraform ==="
jq -n \
    --arg ebs "$EBS_KEY_ID" \
    '{kms_ebs_key_id: $ebs}' > "${KMS_KEYS_FILE}"
chmod 600 "${KMS_KEYS_FILE}"

echo "KMS key configured. Key ID written to ${KMS_KEYS_FILE}."
echo ""
echo "Local key material stored at ${KMS_MATERIAL_DIR}/"
echo "Delete it when you no longer need to re-import:"
echo "  rm -rf ${KMS_MATERIAL_DIR}"
