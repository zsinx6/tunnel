#!/usr/bin/env bash
set -euo pipefail

# One-time setup (per desktop registration): make the home services box
# reachable from the tailnet.
#
# The services run on a separate LAN machine that is not a tailnet node
# (set LAN_SERVICES_HOST in scripts/config.local.sh). This script turns the
# desktop into a subnet router for that single host:
#   1. enables IPv4 forwarding on the desktop (persistent)
#   2. enables the NIC UDP GRO forwarding offload (persistent, for throughput)
#   3. advertises LAN_SERVICES_ROUTE as a Tailscale subnet route
#   4. approves the route in Headscale over SSH
#
# The approval lives in the Headscale database. Re-run this script after the
# desktop re-registers or after the EC2 instance is re-provisioned (both
# create a new node entry without the approval).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
SSH_OPTS=(-i "${SSH_KEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

echo "Fetching Terraform outputs..."
EIP=$(terraform -chdir="${TF_DIR}" output -raw wg_elastic_ip 2>/dev/null) || {
    echo "Error: could not read wg_elastic_ip output. Did 'terraform apply' succeed?"
    exit 1
}

echo "=== 1. Checking prerequisites ==="
if [ -z "${LAN_SERVICES_HOST}" ]; then
    echo "Error: LAN_SERVICES_HOST is not set."
    echo "Create scripts/config.local.sh (gitignored) with the LAN host to"
    echo "expose, for example:"
    echo ""
    echo "  LAN_SERVICES_HOST=\"192.168.1.42\""
    echo "  LAN_SERVICES_PROBE_PORT=\"8096\"    # optional reachability check"
    echo "  LAN_SERVICES=(                     # optional cheat sheet"
    echo "      \"Jellyfin  http://\${LAN_SERVICES_HOST}:8096\""
    echo "  )"
    exit 1
fi
if ! [[ "${LAN_SERVICES_HOST}" =~ ^(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}$ ]]; then
    echo "Error: LAN_SERVICES_HOST must be a bare IPv4 address (got"
    echo "'${LAN_SERVICES_HOST}'). The route is <host>/32, so a hostname or a"
    echo "value with a CIDR suffix does not work. Fix it in config.local.sh."
    exit 1
fi
if ! command -v tailscale &>/dev/null; then
    echo "Error: Tailscale client not installed. Run 01-bootstrap.sh first."
    exit 1
fi
if ! tailscale status --json 2>/dev/null | jq -e '.Self.Online == true' > /dev/null 2>&1; then
    echo "Error: Tailscale is not online. Start the tunnel first:"
    echo "  bash scripts/vpn-up.sh"
    exit 1
fi

# Soft check that the services box answers on the LAN.
if [ -n "${LAN_SERVICES_PROBE_PORT}" ]; then
    if timeout 3 bash -c \
        "exec 3<>/dev/tcp/${LAN_SERVICES_HOST}/${LAN_SERVICES_PROBE_PORT}" 2>/dev/null; then
        echo "Services box ${LAN_SERVICES_HOST} is reachable on the LAN."
    else
        echo "Warning: ${LAN_SERVICES_HOST}:${LAN_SERVICES_PROBE_PORT} did not"
        echo "answer. The route setup continues, but remote access only works"
        echo "while this desktop can reach that machine on the LAN."
    fi
fi

echo "=== 2. Enabling IPv4 forwarding ==="
# Without forwarding, the kernel drops packets that arrive from the tailnet
# and need to continue to the LAN.
# Own filename (not the 99-tailscale.conf that Tailscale's own subnet-router
# docs use), so this never overwrites a file the user or Tailscale wrote for
# other forwarding rules.
SYSCTL_FILE="/etc/sysctl.d/99-tunnel-lan-services.conf"
if [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" = "1" ] && [ -f "${SYSCTL_FILE}" ]; then
    echo "IPv4 forwarding is already enabled."
else
    echo "net.ipv4.ip_forward = 1" | sudo tee "${SYSCTL_FILE}" > /dev/null
    sudo sysctl -q -p "${SYSCTL_FILE}"
    echo "IPv4 forwarding enabled (persisted in ${SYSCTL_FILE})."
fi

echo "=== 3. Enabling UDP GRO forwarding offload ==="
# A subnet router forwards the tunnel's UDP packets. The NIC GRO-forwarding
# offload raises that throughput a lot, and 'tailscale up' warns when it is
# off. ethtool settings do not survive a reboot, so a helper (which resolves
# the current uplink at run time, in case it is not the same interface at
# every boot, e.g. wired vs wifi) is re-run on every boot by a systemd unit.
# Non-fatal: the route works without it.
GRO_HELPER="/usr/local/sbin/tunnel-udp-gro"
GRO_UNIT="/etc/systemd/system/tunnel-udp-gro.service"

# The interface that currently reaches the internet (honours metrics/rules).
uplink_iface() {
    ip -o route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}'
}
CURRENT_IFACE=$(uplink_iface)

if ! command -v ethtool &>/dev/null; then
    echo "Warning: ethtool is not installed. Skipping GRO tuning."
    echo "Install it and re-run this script: sudo pacman -S ethtool"
elif [ -f "${GRO_HELPER}" ] && [ -f "${GRO_UNIT}" ] && [ -n "${CURRENT_IFACE}" ] \
    && ethtool -k "${CURRENT_IFACE}" 2>/dev/null | grep -q 'rx-udp-gro-forwarding: on'; then
    echo "UDP GRO forwarding already enabled on ${CURRENT_IFACE}."
else
    # Helper resolves the uplink each time it runs, so it follows a wired/wifi
    # switch without an interface name pinned anywhere.
    sudo tee "${GRO_HELPER}" > /dev/null <<'EOF'
#!/usr/bin/env bash
# Enable UDP GRO forwarding offload on the current uplink, for Tailscale
# subnet-router throughput. Installed by tunnel/scripts/03-lan-services.sh.
set -uo pipefail
iface=$(ip -o route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
if [ -z "${iface}" ]; then
    echo "tunnel-udp-gro: no uplink interface found; nothing to do" >&2
    exit 0
fi
# Some NICs (often wifi) do not support these offloads; tolerate that.
ethtool -K "${iface}" rx-udp-gro-forwarding on rx-gro-list off || {
    echo "tunnel-udp-gro: ${iface} does not support the offload; skipped" >&2
    exit 0
}
EOF
    sudo chmod 0755 "${GRO_HELPER}"
    sudo tee "${GRO_UNIT}" > /dev/null <<EOF
[Unit]
Description=Enable UDP GRO forwarding offload for Tailscale subnet routing
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${GRO_HELPER}

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable tunnel-udp-gro.service > /dev/null 2>&1 || true
    if sudo systemctl restart tunnel-udp-gro.service; then
        echo "UDP GRO forwarding enabled on ${CURRENT_IFACE:-the uplink} (persisted via ${GRO_UNIT})."
    else
        echo "Warning: could not apply GRO tuning. The route still works; only"
        echo "forwarded throughput is affected. Inspect with:"
        echo "  systemctl status tunnel-udp-gro.service"
    fi
fi

echo "=== 4. Advertising route ${LAN_SERVICES_ROUTE} ==="
# 'tailscale set' changes only this preference. Note that vpn-up.sh and
# 02-configure-clients.sh must pass the same --advertise-routes value:
# 'tailscale up' rejects a call that omits a non-default preference.
sudo tailscale set --advertise-routes "${LAN_SERVICES_ROUTE}"
echo "Route advertised."

echo "=== 5. Approving the route in Headscale ==="
NODE_KEY=$(tailscale status --json | jq -r '.Self.PublicKey // empty')
if [ -z "${NODE_KEY}" ]; then
    echo "Error: could not read this machine's node key from 'tailscale status'."
    exit 1
fi

SSH_ERR=$(mktemp)
trap 'rm -f "${SSH_ERR}"' EXIT

NODES_JSON=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
    "sudo headscale nodes list --output json" 2>"${SSH_ERR}") || {
    echo "Error: SSH to the instance failed:"
    cat "${SSH_ERR}"
    echo "If the instance was re-provisioned, clear the old host key first:"
    echo "  ssh-keygen -R '[${EIP}]:${SSH_PORT}'"
    exit 1
}
# Field naming differs between Headscale JSON flavors; accept both.
NODE_JSON=$(echo "${NODES_JSON}" | jq -c --arg key "${NODE_KEY}" \
    '[.[] | select((.nodeKey // .node_key) == $key)][0] // empty')
if [ -z "${NODE_JSON}" ]; then
    echo "Error: this machine's node key was not found in Headscale."
    echo "Re-register the desktop first: bash scripts/02-configure-clients.sh"
    exit 1
fi
NODE_ID=$(echo "${NODE_JSON}" | jq -r '.id // empty')
if [ -z "${NODE_ID}" ]; then
    echo "Error: could not read the node id from the Headscale response."
    exit 1
fi

# 'approve-routes' REPLACES the node's approved set, and exit-node approval
# (0.0.0.0/0, ::/0) lives in that same set. Merge the LAN /32 with whatever is
# already approved, so a re-run does not silently revoke an exit node.
ROUTES_CSV=$(echo "${NODE_JSON}" | jq -r --arg r "${LAN_SERVICES_ROUTE}" \
    '((.approvedRoutes // .approved_routes // []) + [$r]) | unique | join(",")')

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
    "sudo headscale nodes approve-routes --identifier ${NODE_ID} --routes ${ROUTES_CSV}" \
    > /dev/null 2>"${SSH_ERR}" || {
    echo "Error: route approval failed:"
    cat "${SSH_ERR}"
    exit 1
}
echo "Route approved for node ${NODE_ID} (approved set: ${ROUTES_CSV})."

echo ""
echo "Routes known to Headscale:"
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" "sudo headscale nodes list-routes" 2>/dev/null \
    || echo "(could not list routes; check on the server with 'headscale nodes list-routes')"

echo ""
echo "=== 6. Verifying the route is active on this node ==="
MAX_WAIT=30; ELAPSED=0
TIMED_OUT=false
until tailscale status --json 2>/dev/null | jq -e --arg r "${LAN_SERVICES_ROUTE}" \
    '((.Self.PrimaryRoutes // []) + (.Self.AllowedIPs // [])) | index($r) != null' > /dev/null 2>&1; do
    echo -n "."
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        TIMED_OUT=true
        break
    fi
done
echo ""
if [ "${TIMED_OUT}" = true ]; then
    echo "Warning: the route does not show as active on this node yet. It can"
    echo "take a moment to propagate. Check later with:"
    echo "  tailscale status --json | jq '.Self.PrimaryRoutes'"
else
    echo "Route is active."
fi

echo ""
echo "Done. From any tailnet device you can now reach:"
echo ""
print_lan_services
echo ""
echo "Notes:"
echo "- The desktop must be on and connected (vpn-up.sh) for the route to work."
echo "- The whole host is routed, so every port on ${LAN_SERVICES_HOST} is"
echo "  reachable."
echo "- Linux clients need --accept-routes (the scripts here already pass it)."
echo "  The Tailscale mobile apps use subnet routes by default; on Android,"
echo "  check 'Use Tailscale subnets' if it does not work."
