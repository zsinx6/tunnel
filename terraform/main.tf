terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_vpc" "wg_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "wg-vpc" }
}

resource "aws_internet_gateway" "wg_igw" {
  vpc_id = aws_vpc.wg_vpc.id
}

resource "aws_subnet" "wg_subnet" {
  vpc_id                  = aws_vpc.wg_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "sa-east-1a"
}

resource "aws_route_table" "wg_rt" {
  vpc_id = aws_vpc.wg_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.wg_igw.id
  }
}

resource "aws_route_table_association" "wg_rta" {
  subnet_id      = aws_subnet.wg_subnet.id
  route_table_id = aws_route_table.wg_rt.id
}

resource "aws_security_group" "wg_sg" {
  name        = "wg-hardened-sg"
  description = "WireGuard bastion: SSH for emergency access, WireGuard UDP for tunnel peers"
  vpc_id      = aws_vpc.wg_vpc.id

  # SSH kept open to internet for emergency access when WireGuard tunnel is unavailable.
  # Protected by key-only auth, non-standard port, and fail2ban on the instance.
  ingress {
    from_port   = 50022
    to_port     = 50022
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
    description = "SSH emergency access"
  }

  ingress {
    from_port   = 51920
    to_port     = 51920
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "WireGuard tunnel"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"]
  filter {
    name   = "name"
    values = ["debian-12-amd64-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_key_pair" "wg_key" {
  key_name   = "wg-bastion-key"
  public_key = var.ssh_public_key
}

resource "aws_ssm_parameter" "wg_server_private_key" {
  name        = "/wg-bastion/server-private-key"
  description = "WireGuard server private key"
  type        = "SecureString"
  value       = var.wg_server_private_key
  tags        = { Name = "wg-bastion-wg-key" }
}

resource "aws_ssm_parameter" "wg_peer_psk" {
  for_each    = nonsensitive(var.wg_peers)
  name        = "/wg-bastion/peer-psk/${each.key}"
  description = "WireGuard PSK for peer ${each.key}"
  type        = "SecureString"
  value       = each.value.psk
}

resource "aws_iam_role" "wg_server_role" {
  name = "wg-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "wg_server_ssm" {
  name = "wg-bastion-ssm-access"
  role = aws_iam_role.wg_server_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:GetParameter"]
      Resource = concat(
        [aws_ssm_parameter.wg_server_private_key.arn],
        [for p in aws_ssm_parameter.wg_peer_psk : p.arn]
      )
    }]
  })
}

resource "aws_iam_instance_profile" "wg_server_profile" {
  name = "wg-bastion-profile"
  role = aws_iam_role.wg_server_role.name
}

resource "aws_instance" "wg_server" {
  ami                    = data.aws_ami.debian.id
  instance_type          = "t3.nano"
  subnet_id              = aws_subnet.wg_subnet.id
  vpc_security_group_ids = [aws_security_group.wg_sg.id]
  key_name               = aws_key_pair.wg_key.key_name
  iam_instance_profile   = aws_iam_instance_profile.wg_server_profile.name
  tags                   = { Name = "wg-bastion" }

  # The instance fetches its WireGuard secrets from SSM at boot via its IAM role,
  # so the parameters and the policy granting access must exist before it launches.
  depends_on = [
    aws_iam_role_policy.wg_server_ssm,
    aws_ssm_parameter.wg_server_private_key,
    aws_ssm_parameter.wg_peer_psk,
  ]

  credit_specification {
    cpu_credits = "standard"
  }

  user_data = templatefile("${path.module}/init-ec2.sh.tftpl", {
    ssh_public_key = var.ssh_public_key
    wg_peers       = var.wg_peers
    region         = var.aws_region
  })

  # Force instance replacement when user_data changes (e.g. key rotation),
  # since user_data is only applied on first boot and changes are otherwise ignored.
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
}

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flow-logs/wg-vpc"
  retention_in_days = 30
}

resource "aws_flow_log" "vpc_flow_log" {
  iam_role_arn    = aws_iam_role.flow_log_role.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.wg_vpc.id
}

resource "aws_iam_role" "flow_log_role" {
  name = "vpc-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "flow_log_policy" {
  name = "vpc-flow-log-policy"
  role = aws_iam_role.flow_log_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_eip" "wg_eip" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.wg_igw]
}

resource "aws_eip_association" "wg_eip_assoc" {
  instance_id   = aws_instance.wg_server.id
  allocation_id = aws_eip.wg_eip.id
}

output "wg_elastic_ip" {
  value       = aws_eip.wg_eip.public_ip
  description = "EC2 Elastic IP — use for emergency SSH and as WireGuard endpoint"
}
