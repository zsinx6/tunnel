variable "ssh_public_key" {
  description = "Public SSH key for EC2 operator user"
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to SSH into the EC2 bastion. Restrict to known networks when possible."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "aws_region" {
  description = "AWS region for the bastion"
  type        = string
  default     = "sa-east-1"
}

variable "kms_ebs_key_id" {
  description = "KMS key ARN for EBS volume encryption (BYOK). Must be the full ARN: EC2 canonicalizes the value to an ARN in state, so a bare key ID causes a perpetual forces-replacement diff on the instance."
  type        = string

  validation {
    condition     = startswith(var.kms_ebs_key_id, "arn:")
    error_message = "kms_ebs_key_id must be the full key ARN (arn:aws:kms:...). Re-run scripts/00-import-kms-keys.sh — it upgrades an existing kms_keys.auto.tfvars.json in place."
  }
}

variable "headscale_domain" {
  description = "Fully-qualified domain name for the Headscale endpoint (e.g. hs.example.com). Must have an A record pointing at the Elastic IP; Caddy obtains a Let's Encrypt certificate for it on the instance."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.headscale_domain))
    error_message = "headscale_domain must be a fully-qualified DNS name, e.g. hs.example.com."
  }
}

variable "route53_zone_id" {
  description = "Optional Route53 hosted zone ID. When set, Terraform manages the A record for headscale_domain -> Elastic IP. Leave empty to manage DNS at your own provider."
  type        = string
  default     = ""
}
