#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
KMS_KEYS_FILE="${TF_DIR}/kms_keys.auto.tfvars.json"
KMS_MATERIAL_DIR="$HOME/wireguard-keys/kms"
MATERIAL_FILE="${KMS_MATERIAL_DIR}/ebs_key_material.bin"
# Written immediately after create-key so an interrupted run resumes with the
# same key instead of orphaning it and minting another.
KEY_ID_STATE="${KMS_MATERIAL_DIR}/ebs_key_id"

TMP_IMPORT_DIR=""
trap '[ -n "${TMP_IMPORT_DIR}" ] && rm -rf "${TMP_IMPORT_DIR}"' EXIT

for cmd in openssl aws jq; do
    command -v "$cmd" &>/dev/null || { echo "Error: '$cmd' is required."; exit 1; }
done

if [ -f "${KMS_KEYS_FILE}" ]; then
    # The key must be recorded as a full ARN: EC2 canonicalizes the value to an
    # ARN in Terraform state, so a bare key ID causes a perpetual
    # "forces replacement" diff on the instance.
    EXISTING=$(jq -r '.kms_ebs_key_id // empty' "${KMS_KEYS_FILE}")
    if [ -n "${EXISTING}" ] && [[ "${EXISTING}" != arn:* ]]; then
        ARN=$(aws kms describe-key --key-id "${EXISTING}" --region "$REGION" \
            --query "KeyMetadata.Arn" --output text)
        jq -n --arg ebs "$ARN" '{kms_ebs_key_id: $ebs}' > "${KMS_KEYS_FILE}"
        chmod 600 "${KMS_KEYS_FILE}"
        echo "Upgraded ${KMS_KEYS_FILE} to use the key ARN (${ARN})."
    else
        echo "KMS keys already configured at ${KMS_KEYS_FILE}. Skipping."
    fi
    exit 0
fi

echo "=== 1. Generating local key material ==="
umask 077
mkdir -p "${KMS_MATERIAL_DIR}"
chmod 700 "$HOME/wireguard-keys" "${KMS_MATERIAL_DIR}"

if [ -f "${MATERIAL_FILE}" ]; then
    # Never regenerate: this material may already be imported into a KMS key,
    # and the local copy is the only way to ever re-import it.
    echo "Reusing existing key material at ${MATERIAL_FILE}."
else
    openssl rand 32 > "${MATERIAL_FILE}"
    echo "Generated 256-bit key material for EBS."
fi

echo "=== 2. Creating KMS key (EXTERNAL origin) ==="
if [ -f "${KEY_ID_STATE}" ]; then
    EBS_KEY_ID=$(cat "${KEY_ID_STATE}")
    if [[ "${EBS_KEY_ID}" != arn:* ]]; then
        EBS_KEY_ID=$(aws kms describe-key --key-id "${EBS_KEY_ID}" --region "$REGION" \
            --query "KeyMetadata.Arn" --output text)
        echo "$EBS_KEY_ID" > "${KEY_ID_STATE}"
    fi
    echo "Reusing previously created KMS key: ${EBS_KEY_ID}"
else
    # Record the ARN (not the bare key ID) — see the note at the top.
    EBS_KEY_ID=$(aws kms create-key \
        --region "$REGION" \
        --origin EXTERNAL \
        --description "wg-bastion EBS BYOK" \
        --tags TagKey=Name,TagValue=wg-bastion-ebs \
        --query "KeyMetadata.Arn" \
        --output text)
    echo "$EBS_KEY_ID" > "${KEY_ID_STATE}"
    echo "Created EBS KMS key: ${EBS_KEY_ID}"
fi

echo "=== 3. Importing key material ==="

import_key_material() {
    local key_id="$1"
    local material_file="$2"
    local label="$3"

    TMP_IMPORT_DIR=$(mktemp -d)

    aws kms get-parameters-for-import \
        --key-id "$key_id" \
        --wrapping-algorithm RSAES_OAEP_SHA_256 \
        --wrapping-key-spec RSA_2048 \
        --region "$REGION" > "${TMP_IMPORT_DIR}/params.json"

    # The wrapping public key is DER-encoded (SubjectPublicKeyInfo).
    jq -r '.PublicKey' "${TMP_IMPORT_DIR}/params.json" | base64 -d > "${TMP_IMPORT_DIR}/wrapping_key.der"
    jq -r '.ImportToken' "${TMP_IMPORT_DIR}/params.json" | base64 -d > "${TMP_IMPORT_DIR}/import_token.bin"

    openssl pkeyutl -encrypt \
        -pkeyopt rsa_padding_mode:oaep \
        -pkeyopt rsa_oaep_md:sha256 \
        -pkeyopt rsa_mgf1_md:sha256 \
        -pubin -keyform DER -inkey "${TMP_IMPORT_DIR}/wrapping_key.der" \
        -in "$material_file" \
        -out "${TMP_IMPORT_DIR}/encrypted_material.bin"

    aws kms import-key-material \
        --key-id "$key_id" \
        --encrypted-key-material "fileb://${TMP_IMPORT_DIR}/encrypted_material.bin" \
        --import-token "fileb://${TMP_IMPORT_DIR}/import_token.bin" \
        --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE \
        --region "$REGION"

    rm -rf "${TMP_IMPORT_DIR}"
    TMP_IMPORT_DIR=""
    echo "Imported key material for ${label}."
}

KEY_STATE=$(aws kms describe-key --key-id "$EBS_KEY_ID" --region "$REGION" \
    --query "KeyMetadata.KeyState" --output text)
case "$KEY_STATE" in
    PendingImport)
        import_key_material "$EBS_KEY_ID" "${MATERIAL_FILE}" "EBS"
        ;;
    Enabled)
        echo "Key material already imported (key state: Enabled). Skipping import."
        ;;
    *)
        echo "Error: KMS key ${EBS_KEY_ID} is in unexpected state '${KEY_STATE}'."
        echo "Resolve it manually, or delete ${KEY_ID_STATE} to create a fresh key."
        exit 1
        ;;
esac

echo "=== 4. Writing KMS key ID for Terraform ==="
jq -n \
    --arg ebs "$EBS_KEY_ID" \
    '{kms_ebs_key_id: $ebs}' > "${KMS_KEYS_FILE}"
chmod 600 "${KMS_KEYS_FILE}"

echo "KMS key configured. Key ID written to ${KMS_KEYS_FILE}."
echo ""
echo "Local key material stored at ${KMS_MATERIAL_DIR}/"
echo "It is only needed to RE-import material into this same key (AWS holds a"
echo "copy of the imported material and uses it for all EBS operations)."
