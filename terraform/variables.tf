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
  description = "KMS key ID for EBS volume encryption (BYOK)"
  type        = string
}
