# REGION must match the aws_region Terraform variable (default sa-east-1):
# these scripts locate the instance with the AWS CLI while Terraform owns it.
REGION="sa-east-1"
SSH_USER="wgadmin"
SSH_PORT="50022"
SSH_KEY="$HOME/.ssh/wg_ec2_ed25519"
INSTANCE_TAG="wg-bastion"
