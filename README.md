# tunnel

WireGuard hub-and-spoke VPN using AWS EC2 as a relay, designed for CGNAT environments. Connects an Arch Linux desktop and an Android tablet with per-peer preshared keys (post-quantum), 2FA on the desktop SSH daemon, and explicit iptables rules to prevent VPN peers from pivoting into the home LAN.

```
Arch Desktop (CGNAT)            EC2 Relay (sa-east-1)           Android Tablet
  10.10.0.2                       10.10.0.1 (EIP)                 10.10.0.3
      │                                  │                              │
      └── WireGuard + PSK ───────────────┤──────────── WireGuard + PSK ─┘
                                  Hub / relay only
                                  (peers cannot reach home LAN)
```

---

## Security Properties

| Property | Implementation |
|---|---|
| Transport encryption | WireGuard (Noise Protocol, Curve25519, ChaCha20-Poly1305) |
| Post-quantum resistance | Per-peer preshared keys (PSK) add a symmetric layer |
| Desktop authentication | SSH key + Google Authenticator 2FA (KbdInteractive) |
| EC2 access | Key-only SSH on non-standard port 50022, fail2ban, non-root operator |
| LAN isolation | `iptables FORWARD DROP` on desktop: VPN peers cannot reach home LAN |
| EC2 disk | EBS volume encrypted at rest |
| EC2 metadata | IMDSv2 enforced (SSRF protection) |
| IPv6 | Disabled on EC2 to prevent bypass leaks |
| DNS | Clients use 1.1.1.1 routed over the tunnel |

> **Note:** The EC2 relay decrypts and re-encrypts traffic between peers (hub-and-spoke). It is not end-to-end transparent. For content privacy over the relay, run SSH sessions to `10.10.0.2` from the tablet — the EC2 sees opaque SSH ciphertext.

---

## Prerequisites

- AWS CLI configured (`aws configure`) with permissions to EC2 and EIP
- Terraform ≥ 1.3
- Arch Linux desktop (packages installed by `01-bootstrap.sh`)
- Google Authenticator already configured on the desktop for SSH 2FA

---

## Setup (First Time)

### Step 1 — Bootstrap local keys and Terraform variables

```bash
bash scripts/01-bootstrap.sh
```

This will:
- Install `wireguard-tools`, `aws-cli`, `qrencode`, `terraform` via pacman
- Generate a dedicated ED25519 SSH key at `~/.ssh/wg_ec2_ed25519` (enter a strong passphrase)
- Add a `wg-bastion` alias to `~/.ssh/config`
- Generate WireGuard keypairs and preshared keys in `~/wireguard-keys/`
- Write `terraform/terraform.tfvars` with all keys

> **Safe to re-run** — all steps are idempotent. Existing keys and config are never overwritten.

### Step 2 — Provision EC2

```bash
cd terraform
terraform init
terraform apply
```

This creates: VPC, subnet, internet gateway, hardened security group, EC2 t3.nano (Debian 12), and an Elastic IP. The instance self-configures via cloud-init on first boot (~3–5 min including security updates).

### Step 3 — Configure clients

```bash
bash scripts/02-configure-clients.sh
```

This will:
- Detect your physical network interface
- Write `/etc/wireguard/wg0.conf` on the desktop (prompts before overwriting)
- Print a QR code for the Android tablet — scan it with the [WireGuard Android app](https://play.google.com/store/apps/details?id=com.wireguard.android)

---

## Daily Operation

### Start the tunnel (leaving home)

```bash
bash scripts/vpn-up.sh
```

- Enforces 2FA settings on local sshd
- Starts the EC2 instance (if stopped)
- Waits for WireGuard to come up (up to 180s)

### Stop the tunnel (returning home)

```bash
bash scripts/vpn-down.sh
```

- Stops the local WireGuard interface
- Stops the EC2 instance to halt billing

> The Elastic IP is retained while the instance is stopped (~$0.005/hr). This keeps the WireGuard endpoint stable so clients never need reconfiguration.

---

## LAN Isolation

The desktop's `wg0.conf` includes:

```ini
PostUp   = iptables -I FORWARD -i wg0 -o <PHYS_IF> -j DROP
PostDown = iptables -D FORWARD -i wg0 -o <PHYS_IF> -j DROP
```

This ensures no VPN peer (e.g. the tablet) can forward traffic from `wg0` onto the physical home network — protecting devices like a Raspberry Pi running Immich/Jellyfin. The rule is inserted at the top of the FORWARD chain (`-I`) so it takes precedence over any permissive rules.

`<PHYS_IF>` is detected and hardcoded at the time `02-configure-clients.sh` runs. If you permanently change your primary interface (e.g. `eth0` → `wlan0`), re-run `02-configure-clients.sh`.

---

## Emergency SSH Access

If WireGuard fails to come up, SSH directly to the EC2 using the public Elastic IP:

```bash
# Get the EIP
terraform -chdir=terraform output wg_elastic_ip

ssh -i ~/.ssh/wg_ec2_ed25519 -p 50022 operator@<EIP>

# Diagnose on the instance
journalctl -u wg-quick@wg0
journalctl -u startup-update
sudo wg show
```

The `wg-bastion` SSH alias (added to `~/.ssh/config` by `01-bootstrap.sh`) routes through `10.10.0.1` and only works when the tunnel is already up.

---

## Re-keying

To rotate all WireGuard keys (e.g. after a suspected compromise):

```bash
rm ~/wireguard-keys/*
rm terraform/terraform.tfvars
bash scripts/01-bootstrap.sh          # regenerates all keys and tfvars
terraform -chdir=terraform apply      # user_data_replace_on_change forces instance replacement
bash scripts/02-configure-clients.sh  # writes new desktop config and tablet QR code
```

---

## File Structure

```
.
├── scripts/
│   ├── 01-bootstrap.sh          # Local setup: keys, SSH alias, tfvars
│   ├── 02-configure-clients.sh  # Desktop wg0.conf + tablet QR code
│   ├── vpn-up.sh                # Start EC2 + tunnel
│   └── vpn-down.sh              # Stop tunnel + EC2
└── terraform/
    ├── main.tf                  # VPC, SG, EC2, EIP
    ├── variables.tf             # Input variables (keys, PSKs)
    ├── init-ec2.sh.tftpl        # EC2 cloud-init: WireGuard server config
    └── terraform.tfvars         # Generated by 01-bootstrap.sh — gitignored
```

---

## Security Notes

- `terraform.tfvars` and `terraform.tfstate` contain WireGuard private keys in plaintext. Both are gitignored. Protect them: `chmod 600 terraform/terraform.tfvars terraform/terraform.tfstate`
- The tablet private key is generated on the desktop and displayed as a QR code. It never leaves `~/wireguard-keys/` except via the QR scan. For maximum security, generate the keypair on the tablet and only transfer the public key.
- The EC2 runs `startup-update.service` on every boot, which installs security updates and reboots if required. This is why `vpn-up.sh` waits up to 180s for the tunnel to appear.
