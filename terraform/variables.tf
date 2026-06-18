variable "ssh_public_key" {
  description = "Public SSH key for EC2 operator user (emergency SSH access)"
  type        = string
}

variable "wg_server_private_key" {
  description = "WireGuard server private key"
  type        = string
  sensitive   = true
}

variable "wg_desktop_public_key" {
  description = "WireGuard desktop peer public key"
  type        = string
}

variable "wg_tablet_public_key" {
  description = "WireGuard tablet peer public key"
  type        = string
}

variable "wg_desktop_psk" {
  description = "WireGuard preshared key for the desktop peer (post-quantum symmetric layer)"
  type        = string
  sensitive   = true
}

variable "wg_tablet_psk" {
  description = "WireGuard preshared key for the tablet peer (post-quantum symmetric layer)"
  type        = string
  sensitive   = true
}
