# tunnel

WireGuard hub-and-spoke VPN using AWS EC2 as a relay, designed for CGNAT environments. Connects multiple devices (Arch Linux desktop, Android tablet, smartphone, etc.) through a central EC2 relay with per-peer preshared keys (post-quantum), 2FA on the desktop SSH daemon, and explicit iptables rules to prevent VPN peers from pivoting into the home LAN.

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
| Secret storage | All private keys and PSKs stored in AWS SSM Parameter Store (SecureString) |
| Secret retrieval | EC2 fetches keys at boot via IAM role — never embedded in user_data |
| Desktop authentication | SSH key + Google Authenticator 2FA (KbdInteractive) — configured by the operator on the home machine, not provisioned by this repo |
| EC2 access | Key-only SSH on non-standard port 50022, fail2ban, non-root user (`wgadmin`) |
| SSH access control | Configurable CIDR allowlist (`ssh_allowed_cidrs` variable) |
| LAN isolation | `iptables FORWARD DROP` on desktop: VPN peers cannot reach home LAN |
| EC2 disk | EBS volume encrypted at rest |
| EC2 metadata | IMDSv2 enforced (SSRF protection) |
| IPv6 | Disabled on EC2 to prevent bypass leaks |
| Network forensics | VPC Flow Logs to CloudWatch (30-day retention) |
| CPU billing | `standard` credit mode prevents unexpected billing spikes |

> **Note:** The EC2 relay decrypts and re-encrypts traffic between peers (hub-and-spoke). It is not end-to-end transparent. For content privacy over the relay, run SSH sessions to `10.10.0.2` from the tablet — the EC2 sees opaque SSH ciphertext.

---

## Prerequisites

- AWS CLI v2 configured (`aws configure`) with permissions to EC2, EIP, SSM, IAM, and CloudWatch Logs
- Terraform ≥ 1.3
- Arch Linux desktop (packages installed by `01-bootstrap.sh`)
- Google Authenticator already configured on the desktop for SSH 2FA
- `jq` for JSON processing (installed by `01-bootstrap.sh`)

---

## Setup (First Time)

### Step 1 — Bootstrap local keys and Terraform variables

```bash
bash scripts/01-bootstrap.sh
```

This will:
- Install `wireguard-tools`, `aws-cli`, `qrencode`, `terraform`, `jq` via pacman
- Verify AWS CLI v2 is installed
- Generate a dedicated ED25519 SSH key at `~/.ssh/wg_ec2_ed25519` (enter a strong passphrase)
- Add a `wg-bastion` alias to `~/.ssh/config`
- Generate WireGuard keypairs and preshared keys in `~/wireguard-keys/` for server + 3 default peers (desktop, tablet, smartphone)
- Write `terraform/peers.auto.tfvars.json` with all peer public keys, PSKs, and IPs
- Write `terraform/terraform.tfvars` with SSH public key and server private key

> **Safe to re-run** — all steps are idempotent. Existing keys and config are never overwritten.

### Step 2 — (Optional) Configure remote Terraform state

By default, state is stored locally. For production use, configure an S3 backend:

```bash
# 1. Create the S3 bucket and DynamoDB table first
aws s3 mb s3://YOUR-GLOBALLY-UNIQUE-BUCKET-NAME --region sa-east-1
aws dynamodb create-table --table-name wg-bastion-tf-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region sa-east-1

# 2. Configure the backend
cp terraform/backend.tf.example terraform/backend_override.tf
# Edit the bucket name to match the bucket you created

# 3. Migrate state
cd terraform && terraform init -migrate-state
```

Both `terraform.tfstate` and `peers.auto.tfvars.json` contain sensitive data — remote state with encryption is strongly recommended.

### Step 3 — (Optional) Restrict SSH access

By default, SSH (port 50022) is open to `0.0.0.0/0`. To restrict to known networks:

```bash
# In terraform.tfvars, add:
ssh_allowed_cidrs = ["203.0.113.0/24", "198.51.100.50/32"]
```

### Step 4 — Provision EC2

```bash
cd terraform
terraform init
terraform apply
```

This creates:
- VPC, subnet, internet gateway, hardened security group
- SSM parameters for server private key and all peer PSKs (SecureString, encrypted at rest)
- IAM role with least-privilege access to only the specific SSM parameters
- EC2 t3.nano (Debian 12) with instance profile attached
- Elastic IP associated with the instance
- VPC Flow Logs to CloudWatch

The instance self-configures via cloud-init on first boot (~3–5 min):
1. Installs packages (WireGuard, UFW, fail2ban, AWS CLI)
2. Fetches server private key and peer PSKs from SSM
3. Writes WireGuard config with secrets resolved from SSM
4. Configures UFW, SSH hardening, fail2ban
5. Reboots if security updates require it

### Step 5 — Configure clients

```bash
bash scripts/02-configure-clients.sh
```

This will:
- Read all peer IPs from `peers.auto.tfvars.json`
- Detect your physical network interface
- Write `/etc/wireguard/wg0.conf` on the desktop (prompts before overwriting)
- Print QR codes for all non-desktop peers — scan with the [WireGuard app](https://play.google.com/store/apps/details?id=com.wireguard.android)

---

## Daily Operation

### Start the tunnel (leaving home)

```bash
bash scripts/vpn-up.sh
```

- Starts the EC2 instance (if stopped)
- Waits for EC2 status checks to pass
- Starts the local WireGuard interface
- Polls for WireGuard handshake (up to 180s)

### Stop the tunnel (returning home)

```bash
bash scripts/vpn-down.sh
```

- Stops the local WireGuard interface
- Stops the EC2 instance to halt billing

> The Elastic IP is retained while the instance is stopped (~$0.005/hr). This keeps the WireGuard endpoint stable so clients never need reconfiguration.

---

## Adding a Device

To add a new peer (e.g., a laptop):

```bash
bash scripts/add-device.sh laptop
```

This will:
- Validate the device name (lowercase letters, numbers, hyphens only)
- Generate WireGuard keypair and PSK in `~/wireguard-keys/`
- Calculate the next available IP in the 10.10.0.0/24 subnet
- Check for IP conflicts
- Add the device to `terraform/peers.auto.tfvars.json`

Then apply and generate a QR code:

```bash
cd terraform && terraform apply
# The add-device.sh output includes the exact QR command to run
```

The `terraform apply` will:
- Create a new SSM parameter for the device's PSK
- Update the IAM policy to grant access to the new parameter
- Replace the EC2 instance (new user_data with the additional peer)

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

ssh -i ~/.ssh/wg_ec2_ed25519 -p 50022 wgadmin@<EIP>

# Diagnose on the instance
sudo journalctl -u wg-quick@wg0
sudo journalctl -u startup-update
sudo wg show
```

The `wg-bastion` SSH alias (added to `~/.ssh/config` by `01-bootstrap.sh`) routes through `10.10.0.1` and only works when the tunnel is already up.

---

## Re-keying

To rotate all WireGuard keys (e.g. after a suspected compromise):

```bash
rm ~/wireguard-keys/*
rm terraform/terraform.tfvars
rm terraform/peers.auto.tfvars.json
bash scripts/01-bootstrap.sh          # regenerates all keys, peers, and tfvars
terraform -chdir=terraform apply      # replaces SSM params + instance
bash scripts/02-configure-clients.sh  # writes new desktop config and QR codes
```

> **Important:** You must delete `peers.auto.tfvars.json` before re-running `01-bootstrap.sh`, otherwise the old peer keys will be reused and won't match the newly generated key files.

---

## Teardown

To remove all AWS resources and stop billing entirely:

```bash
terraform -chdir=terraform destroy
```

This deletes the EC2 instance, Elastic IP, VPC, SSM parameters, IAM roles, and flow logs. Your local keys in `~/wireguard-keys/` and the generated `tfvars` are left untouched, so you can re-provision later with `terraform apply`.

> **Note:** Re-provisioning allocates a **new** Elastic IP, so the WireGuard endpoint changes. Re-run `02-configure-clients.sh` (and re-scan the mobile QR codes) to update the endpoint in every client config.

---

## File Structure

```
.
├── scripts/
│   ├── config.sh                  # Shared configuration (AWS region)
│   ├── 01-bootstrap.sh            # Local setup: keys, SSH alias, tfvars, peers JSON
│   ├── 02-configure-clients.sh    # Desktop wg0.conf + QR codes for all mobile peers
│   ├── add-device.sh              # Add a new peer dynamically
│   ├── vpn-up.sh                  # Start EC2 + tunnel
│   └── vpn-down.sh                # Stop tunnel + EC2
├── terraform/
│   ├── main.tf                    # VPC, SG, EC2, EIP, SSM, IAM, Flow Logs
│   ├── variables.tf               # Input variables (keys, PSKs, CIDRs, region)
│   ├── init-ec2.sh.tftpl          # EC2 cloud-init: fetches secrets from SSM, configures WireGuard
│   ├── backend.tf.example         # S3 remote state backend template
│   ├── .terraform.lock.hcl        # Provider version lock (committed)
│   ├── terraform.tfvars           # Generated by 01-bootstrap.sh — gitignored
│   └── peers.auto.tfvars.json     # Generated by 01-bootstrap.sh — gitignored
└── .gitignore
```

---

## Security Notes

- **Secret storage:** The WireGuard server private key and all peer PSKs are stored in AWS SSM Parameter Store (SecureString, encrypted with AWS-managed KMS key). They are never embedded in user_data or visible via the EC2 API.
- **IAM least privilege:** The EC2 instance's IAM role can only read the specific SSM parameters for this bastion — not any other parameters in the account.
- **Local secrets:** `terraform.tfvars` contains the server private key. `peers.auto.tfvars.json` contains all peer PSKs and public keys. Both are gitignored. Protect them: `chmod 600 terraform/terraform.tfvars terraform/peers.auto.tfvars.json`.
- **Remote state:** Use the S3 backend (`backend.tf.example`) to avoid storing state locally. State files contain sensitive data.
- **Tablet private key:** Generated on the desktop and displayed as a QR code. It never leaves `~/wireguard-keys/` except via the QR scan. For maximum security, generate the keypair on the tablet and only transfer the public key.
- **Startup updates:** The EC2 runs `startup-update.service` on every boot, which installs security updates. If a reboot is required, it happens at the end of cloud-init (after WireGuard is configured). This is why `vpn-up.sh` polls for up to 180s.
