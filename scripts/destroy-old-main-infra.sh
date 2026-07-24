#!/usr/bin/env bash
set -euo pipefail

# Tears down a main-branch (WireGuard) deployment whose Terraform state was
# lost, WITHOUT manual deletion: rebuilds the state via 'terraform import'
# against a throwaway git worktree of main, then runs 'terraform destroy'.
#
# Assumes the old infra was never hand-modified (it matches main's config).
# Idempotent: discovery skips resources that no longer exist, imports skip
# what is already in state, and a partial destroy can be resumed by re-running.
# The only mutation is the 'terraform destroy' at the end, which shows its
# plan and asks for explicit confirmation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
source "${SCRIPT_DIR}/config.sh"
REPO_DIR="${SCRIPT_DIR}/.."

for cmd in aws terraform git jq; do
    command -v "$cmd" &>/dev/null || { echo "Error: '$cmd' is required."; exit 1; }
done

if [ -f "${REPO_DIR}/terraform/terraform.tfstate" ]; then
    echo "Error: ${REPO_DIR}/terraform/terraform.tfstate exists — your state is NOT lost."
    echo "Use the normal migration (scripts/migrate-from-main.sh) instead."
    exit 1
fi

WORKDIR=$(mktemp -d /tmp/tunnel-main-destroy.XXXXXX)
cleanup() {
    git -C "${REPO_DIR}" worktree remove --force "${WORKDIR}" 2>/dev/null || rm -rf "${WORKDIR}"
}
trap cleanup EXIT

echo "=== 1. Checking out 'main' into a throwaway worktree ==="
git -C "${REPO_DIR}" worktree add --detach "${WORKDIR}" main >/dev/null
TF="${WORKDIR}/terraform"

echo "=== 2. Discovering old resources in ${REGION} ==="
INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_TAG}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || echo "None")
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=wg-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")
PEER_PARAMS=$(aws ssm get-parameters-by-path --path /wg-bastion/peer-psk/ --region "$REGION" \
    --query 'Parameters[].Name' --output text 2>/dev/null || true)
SERVER_PARAM=$(aws ssm get-parameters-by-path --path /wg-bastion/ --region "$REGION" \
    --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n' | grep -x '/wg-bastion/server-private-key' || true)
HAS_WG_ROLE=$(aws iam get-role --role-name wg-bastion-role --query 'Role.RoleName' --output text 2>/dev/null || true)
HAS_FL_ROLE=$(aws iam get-role --role-name vpc-flow-log-role --query 'Role.RoleName' --output text 2>/dev/null || true)
HAS_KEYPAIR=$(aws ec2 describe-key-pairs --region "$REGION" --key-names wg-bastion-key \
    --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)
HAS_LOG_GROUP=$(aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix /aws/vpc/flow-logs/wg-vpc \
    --query 'logGroups[0].logGroupName' --output text 2>/dev/null || true)

if [ "$INSTANCE_ID" = "None" ] && [ "$VPC_ID" = "None" ] && [ -z "$PEER_PARAMS" ] && \
   [ -z "$HAS_WG_ROLE" ] && [ -z "$HAS_FL_ROLE" ] && [ -z "${HAS_KEYPAIR}" ]; then
    echo "No old wg-bastion infrastructure found — the account is already clean."
    exit 0
fi

echo "  instance:   ${INSTANCE_ID}"
echo "  vpc:        ${VPC_ID}"
echo "  ssm peers:  $(echo "${PEER_PARAMS}" | wc -w) parameter(s)"
echo "  iam roles:  ${HAS_WG_ROLE:-none} ${HAS_FL_ROLE:-none}"
echo "  key pair:   ${HAS_KEYPAIR:-none}"

if [ "$VPC_ID" != "None" ]; then
    SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query 'Subnets[0].SubnetId' --output text)
    IGW_ID=$(aws ec2 describe-internet-gateways --region "$REGION" \
        --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
        --query 'InternetGateways[0].InternetGatewayId' --output text)
    RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=association.main,Values=false" \
        --query 'RouteTables[0].RouteTableId' --output text)
    SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=wg-hardened-sg" \
        --query 'SecurityGroups[0].GroupId' --output text)
    FLOW_LOG_ID=$(aws ec2 describe-flow-logs --region "$REGION" \
        --filter "Name=resource-id,Values=${VPC_ID}" \
        --query 'FlowLogs[0].FlowLogId' --output text)
fi

EIP_ALLOC="None"; EIP_ASSOC="None"
if [ "$INSTANCE_ID" != "None" ]; then
    read -r EIP_ALLOC EIP_ASSOC < <(aws ec2 describe-addresses --region "$REGION" \
        --filters "Name=instance-id,Values=${INSTANCE_ID}" \
        --query 'Addresses[0].[AllocationId,AssociationId]' --output text) || true
fi

echo "=== 3. Writing dummy variables (values are irrelevant for destroy) ==="
cat > "${TF}/terraform.tfvars" <<EOF
ssh_public_key        = "ssh-ed25519 AAAA dummy-for-destroy"
wg_server_private_key = "dummy-for-destroy"
EOF
PEERS_JSON='{"wg_peers":{}}'
for p in ${PEER_PARAMS}; do
    n=$(basename "$p")
    PEERS_JSON=$(echo "$PEERS_JSON" | jq --arg n "$n" \
        '.wg_peers[$n] = {public_key: "dummy", psk: "dummy", ip: "10.10.0.99"}')
done
echo "$PEERS_JSON" > "${TF}/peers.auto.tfvars.json"

echo "=== 4. Rebuilding state via terraform import ==="
terraform -chdir="${TF}" init -input=false >/dev/null

try_import() {
    terraform -chdir="${TF}" import -input=false "$1" "$2" >/dev/null 2>&1 \
        && echo "  imported: $1" \
        || echo "  skipped:  $1 (already imported, or import failed)"
}

[ "$VPC_ID" != "None" ] && {
    try_import aws_vpc.wg_vpc "$VPC_ID"
    try_import aws_internet_gateway.wg_igw "$IGW_ID"
    try_import aws_subnet.wg_subnet "$SUBNET_ID"
    try_import aws_route_table.wg_rt "$RT_ID"
    try_import aws_route_table_association.wg_rta "${SUBNET_ID}/${RT_ID}"
    try_import aws_security_group.wg_sg "$SG_ID"
    [ -n "${FLOW_LOG_ID:-}" ] && [ "$FLOW_LOG_ID" != "None" ] && \
        try_import aws_flow_log.vpc_flow_log "$FLOW_LOG_ID"
}
[ -n "$HAS_LOG_GROUP" ] && [ "$HAS_LOG_GROUP" != "None" ] && \
    try_import aws_cloudwatch_log_group.vpc_flow_logs /aws/vpc/flow-logs/wg-vpc
[ "$INSTANCE_ID" != "None" ] && try_import aws_instance.wg_server "$INSTANCE_ID"
[ "$EIP_ALLOC" != "None" ] && [ -n "$EIP_ALLOC" ] && try_import aws_eip.wg_eip "$EIP_ALLOC"
[ "$EIP_ASSOC" != "None" ] && [ -n "$EIP_ASSOC" ] && \
    try_import aws_eip_association.wg_eip_assoc "$EIP_ASSOC"
[ -n "$HAS_KEYPAIR" ] && [ "$HAS_KEYPAIR" != "None" ] && \
    try_import aws_key_pair.wg_key wg-bastion-key
[ -n "$HAS_WG_ROLE" ] && {
    try_import aws_iam_role.wg_server_role wg-bastion-role
    try_import aws_iam_role_policy.wg_server_ssm wg-bastion-role:wg-bastion-ssm-access
    try_import aws_iam_instance_profile.wg_server_profile wg-bastion-profile
}
[ -n "$HAS_FL_ROLE" ] && {
    try_import aws_iam_role.flow_log_role vpc-flow-log-role
    try_import aws_iam_role_policy.flow_log_policy vpc-flow-log-role:vpc-flow-log-policy
}
[ -n "$SERVER_PARAM" ] && \
    try_import aws_ssm_parameter.wg_server_private_key /wg-bastion/server-private-key
for p in ${PEER_PARAMS}; do
    n=$(basename "$p")
    try_import "aws_ssm_parameter.wg_peer_psk[\"$n\"]" "$p"
done

echo ""
echo "State rebuilt. Resources now managed:"
terraform -chdir="${TF}" state list

echo ""
echo "=== 5. Destroying the old deployment ==="
echo "Review the plan below carefully — everything listed will be deleted"
echo "(including the old Elastic IP; the new design allocates a fresh one)."
echo ""
terraform -chdir="${TF}" destroy

echo ""
echo "Old infrastructure destroyed. The worktree and its state are discarded."
echo "Continue with the fresh deployment: bash scripts/01-bootstrap.sh"
