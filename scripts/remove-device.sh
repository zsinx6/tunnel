#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
SSH_OPTS=(-i "${SSH_KEY}" -p "${SSH_PORT}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <identifier>

Remove a device from the Tailscale network.

Arguments:
  identifier         Exact node name, hostname, or Tailscale IP (100.x.x.x),
                     as shown by --list. Letter case does not matter. A name
                     match wins over a hostname match.

Options:
  --list             List all registered nodes
  --expire           Expire the node instead of deleting it (softer, can re-register)
  --force            Skip confirmation prompt
  -h, --help         Show this help message

Examples:
  $(basename "$0") my-phone              # Remove node by name
  $(basename "$0") 100.64.0.5            # Remove node by IP
  $(basename "$0") --expire my-tablet    # Expire instead of delete
  $(basename "$0") --list                # List all nodes
EOF
}

# Parse arguments
ACTION="delete"
IDENTIFIER=""
FORCE=false
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)
            LIST_ONLY=true
            shift
            ;;
        --expire)
            ACTION="expire"
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            echo "Error: Unknown option $1"
            show_usage
            exit 1
            ;;
        *)
            if [ -z "${IDENTIFIER}" ]; then
                IDENTIFIER="$1"
                # Validate identifier: only allow alphanumeric, dots, hyphens, underscores
                if [[ ! "${IDENTIFIER}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                    echo "Error: Invalid identifier format."
                    echo "Only alphanumeric characters, dots, hyphens, and underscores are allowed."
                    exit 1
                fi
            else
                echo "Error: Multiple identifiers provided"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

if ! ${LIST_ONLY} && [ -z "${IDENTIFIER}" ]; then
    echo "Error: identifier required"
    show_usage
    exit 1
fi

echo "Fetching Terraform outputs..."
EIP=$(terraform -chdir="${TF_DIR}" output -raw wg_elastic_ip 2>/dev/null) || {
    echo "Error: could not read wg_elastic_ip output. Did 'terraform apply' succeed?"
    exit 1
}

echo "Checking Headscale connectivity..."
HEADSCALE_URL=$(terraform -chdir="${TF_DIR}" output -raw headscale_url 2>/dev/null) || {
    echo "Error: could not read headscale_url output. Did 'terraform apply' succeed?"
    exit 1
}

if ! curl -fsS --max-time 5 "${HEADSCALE_URL}/health" > /dev/null 2>&1; then
    echo "Headscale is not reachable at ${HEADSCALE_URL}."
    echo "Start the tunnel first:"
    echo "  bash scripts/vpn-up.sh"
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

# Field naming differs between Headscale JSON flavors; accept both. "name" is
# the hostname the device reports; "given_name" is its name in the tailnet.
# With no nodes, Headscale prints null instead of an empty list.
JQ_NODE_DEFS='
    def nodes: (. // [])[];
    def ips: (.ip_addresses // .ipAddresses // []);
    def given: (.given_name // .givenName // "");
    def last_seen:
        (.last_seen // .lastSeen) as $t
        | if $t == null then "never"
          elif ($t | type) == "object" then ($t.seconds // 0 | todate)
          else $t end;
    def summary:
        "ID: \(.id) | Name: \(given) | Hostname: \(.name // "") | IPs: \(ips | join(", ")) | User: \(.user.name // "") | Online: \(.online // false) | Last seen: \(last_seen)";
'

# List mode
if ${LIST_ONLY}; then
    echo ""
    echo "=== Registered Nodes ==="
    echo ""
    echo "${NODES_JSON}" | jq -r "${JQ_NODE_DEFS}"' nodes | summary'
    exit 0
fi

# Exact matches only: a partial match can select a different node than the
# one you named, and this script deletes it. Headscale keeps tailnet names
# unique, so a match on that name wins; hostnames can repeat.
echo "Searching for node '${IDENTIFIER}'..."
MATCHES=$(echo "${NODES_JSON}" | jq -c --arg id "${IDENTIFIER}" "${JQ_NODE_DEFS}"'
    ($id | ascii_downcase) as $want
    | [nodes | select((given | ascii_downcase) == $want)] as $by_name
    | if ($by_name | length) > 0 then $by_name
      else [nodes | select(((.name // "") | ascii_downcase) == $want or any(ips[]; . == $id))]
      end')
MATCH_COUNT=$(echo "${MATCHES}" | jq 'length')

if [ "${MATCH_COUNT}" -eq 0 ]; then
    echo "Error: No node found matching '${IDENTIFIER}'"
    echo ""
    echo "Available nodes:"
    echo "${NODES_JSON}" | jq -r "${JQ_NODE_DEFS}"' nodes | "  " + summary'
    exit 1
fi
if [ "${MATCH_COUNT}" -gt 1 ]; then
    echo "Error: ${MATCH_COUNT} nodes match '${IDENTIFIER}':"
    echo "${MATCHES}" | jq -r "${JQ_NODE_DEFS}"' .[] | "  " + summary'
    echo "Run the script again with the name or Tailscale IP of the node to remove."
    exit 1
fi

NODE_ID=$(echo "${MATCHES}" | jq -r '.[0].id // empty')
# NODE_ID goes into a remote shell command, so accept digits only.
if [[ ! "${NODE_ID}" =~ ^[0-9]+$ ]]; then
    echo "Error: could not read the node id from the Headscale response."
    exit 1
fi

echo ""
echo "Found node:"
echo "${MATCHES}" | jq -r "${JQ_NODE_DEFS}"' .[0] | "  " + summary'
echo ""

# Confirmation
if ! ${FORCE}; then
    read -p "Are you sure you want to ${ACTION} this node? [y/N] " -n 1 -r || REPLY=""
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

# Perform the action
echo ""
if [ "${ACTION}" = "delete" ]; then
    echo "Deleting node ${NODE_ID}..."
    # Without --force, Headscale asks y/n on stdin. A non-interactive SSH
    # session gives no answer, so Headscale keeps the node and still exits 0.
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
        "sudo headscale nodes delete --identifier ${NODE_ID} --force" 2>"${SSH_ERR}" || {
        echo "Error: failed to delete node:"
        cat "${SSH_ERR}"
        exit 1
    }
    REMAINING=$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
        "sudo headscale nodes list --output json" 2>"${SSH_ERR}" \
        | jq --arg nid "${NODE_ID}" '[(. // [])[] | select((.id | tostring) == $nid)] | length') || {
        echo "Error: could not list nodes to verify the delete:"
        cat "${SSH_ERR}"
        exit 1
    }
    if [ "${REMAINING}" != "0" ]; then
        echo "Error: node ${NODE_ID} is still registered after the delete."
        exit 1
    fi
    echo "Node deleted successfully."
else
    echo "Expiring node ${NODE_ID}..."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${EIP}" \
        "sudo headscale nodes expire --identifier ${NODE_ID}" 2>"${SSH_ERR}" || {
        echo "Error: failed to expire node:"
        cat "${SSH_ERR}"
        exit 1
    }
    echo "Node expired successfully. It can be re-registered later."
fi

echo ""
echo "Note: If this device had a subnet route approved (via 03-lan-services.sh),"
echo "you may need to re-run that script if another device is now serving that route."
