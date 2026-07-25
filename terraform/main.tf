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

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
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
  availability_zone       = data.aws_availability_zones.available.names[0]
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
  description = "Tailscale DERP relay: SSH for maintenance, HTTPS for Headscale/DERP, HTTP for ACME"
  vpc_id      = aws_vpc.wg_vpc.id

  ingress {
    from_port   = 50022
    to_port     = 50022
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
    description = "SSH maintenance access"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "ACME HTTP-01 challenge + HTTPS redirect (Caddy)"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Headscale API + DERP HTTPS (TLS)"
  }

  ingress {
    from_port   = 3478
    to_port     = 3478
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "DERP STUN"
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

resource "aws_instance" "wg_server" {
  ami                    = data.aws_ami.debian.id
  instance_type          = "t3.nano"
  subnet_id              = aws_subnet.wg_subnet.id
  vpc_security_group_ids = [aws_security_group.wg_sg.id]
  tags                   = { Name = "wg-bastion" }

  credit_specification {
    cpu_credits = "standard"
  }

  user_data = templatefile("${path.module}/init-ec2.sh.tftpl", {
    ssh_public_key   = var.ssh_public_key
    headscale_domain = var.headscale_domain
  })

  # Replacing the instance wipes the Headscale DB (all registered devices) and
  # the Let's Encrypt account/cert state. user_data changes intentionally force
  # replacement; a new upstream AMI must not.
  user_data_replace_on_change = true

  lifecycle {
    ignore_changes = [ami]
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_ebs_key_id
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
  traffic_type    = "REJECT"
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
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "flow_log_policy" {
  name = "vpc-flow-log-policy"
  role = aws_iam_role.flow_log_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          aws_cloudwatch_log_group.vpc_flow_logs.arn,
          "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      }
    ]
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

resource "aws_route53_record" "headscale" {
  count   = var.route53_zone_id != "" ? 1 : 0
  zone_id = var.route53_zone_id
  name    = var.headscale_domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.wg_eip.public_ip]
}

output "wg_elastic_ip" {
  value       = aws_eip.wg_eip.public_ip
  description = "EC2 Elastic IP — point the headscale_domain A record here; also used for emergency SSH"
}

output "headscale_url" {
  value       = "https://${var.headscale_domain}"
  description = "Headscale control-server URL used by all Tailscale clients"
}

output "dns_setup" {
  description = "What to do (if anything) to make the domain point at the relay"
  value = var.route53_zone_id != "" ? format(
    "DNS is managed by Terraform: %s -> %s (Route53 zone %s). Nothing to do.",
    var.headscale_domain, aws_eip.wg_eip.public_ip, var.route53_zone_id
    ) : format(
    "ACTION REQUIRED (one time): in your registrar's DNS panel create -> Type: A | Name: %s | Value: %s | TTL: 300. Verify with: dig +short %s (must print %s). The Elastic IP never changes, so this record never needs updating.",
    var.headscale_domain, aws_eip.wg_eip.public_ip, var.headscale_domain, aws_eip.wg_eip.public_ip
  )
}
