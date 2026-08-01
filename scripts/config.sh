# REGION must match the aws_region Terraform variable (default sa-east-1):
# these scripts locate the instance with the AWS CLI while Terraform owns it.
REGION="sa-east-1"
SSH_USER="wgadmin"
SSH_PORT="50022"
SSH_KEY="$HOME/.ssh/wg_ec2_ed25519"
INSTANCE_TAG="wg-bastion"

# Optional: home services box — a LAN machine (not a tailnet node) that runs
# services you want to reach while away (a NAS, a Docker host, ...). The
# desktop advertises its /32 as a Tailscale subnet route.
# Machine-specific values belong in scripts/config.local.sh (gitignored),
# which overrides the defaults below. Setup: scripts/03-lan-services.sh
LAN_SERVICES_HOST=""
# Optional TCP port on LAN_SERVICES_HOST for a LAN reachability check.
LAN_SERVICES_PROBE_PORT=""
# Optional cheat-sheet lines printed by vpn-up.sh and 03-lan-services.sh,
# e.g. "Jellyfin  http://${LAN_SERVICES_HOST}:8096".
LAN_SERVICES=()

_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
if [ -f "${_CONFIG_DIR}/config.local.sh" ]; then
    source "${_CONFIG_DIR}/config.local.sh"
fi

LAN_SERVICES_ROUTE=""
if [ -n "${LAN_SERVICES_HOST}" ]; then
    LAN_SERVICES_ROUTE="${LAN_SERVICES_HOST}/32"
fi

print_lan_services() {
    if [ "${#LAN_SERVICES[@]}" -eq 0 ]; then
        echo "Home services host ${LAN_SERVICES_HOST} is routed (no service list in config.local.sh)."
        return
    fi
    echo "Home services on ${LAN_SERVICES_HOST} (through the desktop subnet route):"
    printf '  %s\n' "${LAN_SERVICES[@]}"
}
