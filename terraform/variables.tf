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

variable "wg_server_private_key" {
  description = "WireGuard server private key"
  type        = string
  sensitive   = true
}

# This single variable now holds ALL peers dynamically
variable "wg_peers" {
  description = "Map of all WireGuard peers"
  type = map(object({
    public_key = string
    psk        = string
    ip         = string
  }))
  sensitive = true
  default   = {}
}
