#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "Stopping local Tailscale client..."
if command -v tailscale &>/dev/null; then
    sudo tailscale down || echo "Warning: 'tailscale down' failed; check 'tailscale status'."
fi

echo "Locating instances to halt..."
# Include pending: an instance still booting (e.g. after an aborted vpn-up)
# must also be stopped, or it bills indefinitely. Stop ALL tagged instances.
INSTANCE_IDS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_TAG}" "Name=instance-state-name,Values=pending,running,stopping" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text)

if [ -z "${INSTANCE_IDS}" ]; then
    echo "No running or starting bastion found. Nothing to stop."
    exit 0
fi

for INSTANCE_ID in ${INSTANCE_IDS}; do
    STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].State.Name" --output text)
    case "$STATE" in
        pending)
            echo "Instance ${INSTANCE_ID} is still starting; waiting before stopping it..."
            aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
            aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
            ;;
        running)
            echo "Stopping EC2 instance ${INSTANCE_ID}..."
            aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null
            ;;
        stopping)
            echo "Instance ${INSTANCE_ID} is already stopping."
            ;;
    esac
done

echo "Waiting for instance(s) to stop..."
# shellcheck disable=SC2086
aws ec2 wait instance-stopped --instance-ids ${INSTANCE_IDS} --region "$REGION"

for INSTANCE_ID in ${INSTANCE_IDS}; do
    FINAL_STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query "Reservations[0].Instances[0].State.Name" --output text)
    echo "Instance ${INSTANCE_ID}: ${FINAL_STATE}"
done
echo "Infrastructure halted. (The Elastic IP keeps billing ~\$0.005/h while reserved.)"
