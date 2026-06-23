variable "ssh_public_key" {
  description = "Public SSH key for EC2 operator user"
  type        = string
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
