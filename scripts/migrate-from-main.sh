#!/usr/bin/env bash
set -euo pipefail

# Migrates a machine + AWS deployment from the WireGuard hub-and-spoke design
# (main branch) to the Headscale/Tailscale design (this branch).
#
# Interactive and idempotent: safe to re-run, prompts before touching anything
# sensitive, and never runs 'terraform apply' itself — you review the plan.
# Old secrets are moved to a backup directory, not deleted.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
BACKUP_DIR="$HOME/wireguard-keys/migration-backup-main"

umask 077
mkdir -p "${BACKUP_DIR}"

echo "==============================================================="
echo " Migration: WireGuard (main) -> Headscale/Tailscale (improve)"
echo "==============================================================="
echo ""
echo "This will clean up local WireGuard-era state and regenerate the"
echo "Terraform inputs. Old secrets are MOVED to:"
echo "  ${BACKUP_DIR}"
echo "Nothing on AWS is changed until you run 'terraform apply' yourself."
echo ""

# --- 1. Stop and retire the local WireGuard interface --------------------------

echo "=== 1. Local WireGuard interface ==="
if [ -f /etc/wireguard/wg0.conf ]; then
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        echo "Stopping wg-quick@wg0..."
        sudo systemctl stop wg-quick@wg0
    fi
    sudo systemctl disable wg-quick@wg0 2>/dev/null || true
    read -r -p "Move /etc/wireguard/wg0.conf (contains old PSKs) to the backup dir? [Y/n] " REPLY
    if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
        sudo mv /etc/wireguard/wg0.conf "${BACKUP_DIR}/wg0.conf"
        sudo chown "$(id -un):$(id -gn)" "${BACKUP_DIR}/wg0.conf"
        chmod 600 "${BACKUP_DIR}/wg0.conf"
        echo "Moved."
    fi
else
    echo "No /etc/wireguard/wg0.conf — nothing to do."
fi

# --- 2. Remove the stale 'wg-bastion' SSH alias --------------------------------

echo ""
echo "=== 2. SSH alias ==="
SSH_CONFIG="$HOME/.ssh/config"
if [ -f "${SSH_CONFIG}" ] && grep -q "^Host wg-bastion" "${SSH_CONFIG}"; then
    cp "${SSH_CONFIG}" "${BACKUP_DIR}/ssh_config.bak"
    # Drop the 'Host wg-bastion' line plus its indented option lines.
    awk '
        /^Host wg-bastion([[:space:]]|$)/ { skip = 1; next }
        skip && /^[[:space:]]/ { next }
        { skip = 0; print }
    ' "${SSH_CONFIG}" > "${SSH_CONFIG}.tmp"
    mv "${SSH_CONFIG}.tmp" "${SSH_CONFIG}"
    chmod 600 "${SSH_CONFIG}"
    echo "Removed 'wg-bastion' alias (it pointed at the dead 10.10.0.1 tunnel IP)."
    echo "Backup of the old config: ${BACKUP_DIR}/ssh_config.bak"
else
    echo "No 'wg-bastion' alias — nothing to do."
fi

# --- 3. Clear stale SSH host keys (the instance gets replaced) ------------------

echo ""
echo "=== 3. Stale SSH host keys ==="
EIP=$(terraform -chdir="${TF_DIR}" output -raw wg_elastic_ip 2>/dev/null || true)
if [ -n "${EIP}" ]; then
    ssh-keygen -R "[${EIP}]:${SSH_PORT}" 2>/dev/null || true
    echo "Cleared known_hosts entry for [${EIP}]:${SSH_PORT} (host key changes on replacement)."
else
    echo "No terraform state / EIP found — skipping known_hosts cleanup."
fi
# Main's alias connected to 10.10.0.1 on port 50022, stored in bracketed form.
ssh-keygen -R "[10.10.0.1]:${SSH_PORT}" 2>/dev/null >/dev/null || true

# --- 4. Retire WireGuard-era Terraform inputs -----------------------------------

echo ""
echo "=== 4. Terraform inputs ==="
PEERS_JSON="${TF_DIR}/peers.auto.tfvars.json"
if [ -f "${PEERS_JSON}" ]; then
    mv "${PEERS_JSON}" "${BACKUP_DIR}/peers.auto.tfvars.json"
    echo "Moved peers.auto.tfvars.json (contains peer PSKs) to the backup dir."
fi

TFVARS="${TF_DIR}/terraform.tfvars"
PRESERVED_CIDRS=""
if [ -f "${TFVARS}" ] && grep -q '^wg_server_private_key' "${TFVARS}"; then
    # Carry the SSH allowlist forward — losing it would silently reopen
    # SSH to 0.0.0.0/0 (the variable default) on the next apply.
    PRESERVED_CIDRS=$(grep '^ssh_allowed_cidrs' "${TFVARS}" || true)
    mv "${TFVARS}" "${BACKUP_DIR}/terraform.tfvars"
    echo "Moved old terraform.tfvars (contains the WireGuard server private key)"
    echo "to the backup dir. A new one is generated in the next step."
fi

# --- 5. Retire local WireGuard key material -------------------------------------

echo ""
echo "=== 5. Local WireGuard keys ==="
# Only top-level WG key files; the kms/ subdirectory (BYOK material) stays.
mapfile -t WG_KEY_FILES < <(find "$HOME/wireguard-keys" -maxdepth 1 -type f \
    \( -name '*.key' -o -name '*.pub' -o -name '*.psk' \) 2>/dev/null)
if [ ${#WG_KEY_FILES[@]} -gt 0 ]; then
    echo "Found ${#WG_KEY_FILES[@]} obsolete WireGuard key file(s) in ~/wireguard-keys/."
    read -r -p "Move them to the backup dir? [Y/n] " REPLY
    if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
        mv "${WG_KEY_FILES[@]}" "${BACKUP_DIR}/"
        echo "Moved."
    fi
else
    echo "No obsolete WireGuard key files — nothing to do."
fi

# --- 6. Generate config for the new design ---------------------------------------

echo ""
echo "=== 6. Bootstrap for the new design ==="
bash "${SCRIPT_DIR}/01-bootstrap.sh"

if [ -n "${PRESERVED_CIDRS}" ] && ! grep -q '^ssh_allowed_cidrs' "${TFVARS}"; then
    printf '%s\n' "${PRESERVED_CIDRS}" >> "${TFVARS}"
    echo "Restored your SSH allowlist in terraform.tfvars: ${PRESERVED_CIDRS}"
fi

# --- 7. Next steps ----------------------------------------------------------------

echo ""
echo "==============================================================="
echo " Local migration done. Next steps:"
echo "==============================================================="
echo ""
echo "1. Review and apply the infrastructure change:"
echo "     terraform -chdir=terraform apply"
echo "   Expect in the plan:"
echo "     ~ REPLACED:  the EC2 instance (new Headscale provisioning)"
echo "     ~ REPLACED:  the security group (its description changed, which"
echo "                  forces recreation) and the VPC flow log (ALL -> REJECT)"
echo "     - DESTROYED: SSM parameters, wg-bastion IAM role/profile, key pair"
echo "     + ADDED:     port 80 SG rule (ACME), dns_setup output"
echo "     PRESERVED:   the Elastic IP (same address as before)"
echo ""
echo "2. Create the DNS record (one time):"
echo "     terraform -chdir=terraform output dns_setup"
echo ""
echo "3. Re-register this desktop:"
echo "     bash scripts/02-configure-clients.sh"
echo ""
echo "4. Other devices: the old WireGuard tunnels are dead. Delete their"
echo "   WireGuard app profiles and register them via:"
echo "     bash scripts/add-device.sh"
echo ""
echo "5. When everything works, destroy the old secrets in the backup dir:"
echo "     find '${BACKUP_DIR}' -type f -exec shred -u {} \\; && rmdir '${BACKUP_DIR}'"
echo "   Also shred the pre-migration Terraform state backup — the old design"
echo "   stored the WireGuard private key and PSKs in state:"
echo "     shred -u terraform/terraform.tfstate.backup"
echo "   (Do this only AFTER the first successful post-migration apply and"
echo "   verification — the backup is your rollback until then.)"
