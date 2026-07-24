# tunnel

Ephemeral Tailscale DERP relay on AWS EC2 with self-hosted Headscale, designed for CGNAT environments. No WireGuard private keys ever leave your devices — the EC2 relay only forwards encrypted packets and stores public keys in Headscale.

```
Arch Desktop (CGNAT)            EC2 Relay (sa-east-1)           Android Tablet
  100.64.x.x                      DERP relay only                 100.64.x.x
      │                                  │                              │
      └── Tailscale (encrypted) ─────────┤──────────── Tailscale (encrypted) ─┘
                                    Headscale coordinator
                                    (public keys only, no private keys)
```

When at home, devices connect directly via LAN — the EC2 instance is off. When leaving home, `vpn-up.sh` starts the EC2 relay and Tailscale clients connect through it.

---

## Security Properties

| Property | Implementation |
|---|---|
| Transport encryption | Tailscale (WireGuard under the hood, Curve25519, ChaCha20-Poly1305) |
| API encryption | Headscale API served over HTTPS with self-signed certificate (Caddy reverse proxy) |
| Key ownership | Private keys generated on your devices only — never on EC2 or any server |
| EC2 role | DERP relay (encrypted packet forwarder) + Headscale coordinator (public keys only) |
| Secret storage | No WireGuard secrets on EC2 — Headscale stores only public keys and network config |
| Headscale keys | Headscale's own coordination keys (private.key, noise_private.key, derp_private.key) are generated on EC2 — these protect the coordination protocol, not your traffic |
| EC2 disk | EBS encrypted at rest with customer-owned BYOK KMS key |
| EC2 access | Key-only SSH on non-standard port 50022, fail2ban, non-root user (`wgadmin`) |
| SSH access control | Configurable CIDR allowlist (`ssh_allowed_cidrs` variable) |
| EC2 metadata | IMDSv2 enforced (SSRF protection) |
| IPv6 | Disabled on EC2 to prevent bypass leaks |
| Network forensics | VPC Flow Logs to CloudWatch (30-day retention) |
| CPU billing | `standard` credit mode prevents unexpected billing spikes |
| Ephemeral | EC2 runs only when needed — off most of the time, no persistent attack surface |

> **Key point:** AWS never has access to your WireGuard private keys. The EC2 instance only stores public keys in Headscale and forwards encrypted DERP packets. Even with full access to the running instance, AWS cannot decrypt your traffic.

---

## Prerequisites

- AWS CLI v2 configured (`aws configure`) with permissions to EC2, EIP, KMS, IAM, and CloudWatch Logs
- Terraform >= 1.3
- Arch Linux desktop (packages installed by `01-bootstrap.sh`)
- Tailscale installed on desktop (installed automatically by `01-bootstrap.sh` via official install script)
- Tailscale app on mobile devices (see limitations below)

> **Mobile device note:** The official Tailscale mobile app does not support custom coordination servers. For mobile devices, you'll need to either use an unofficial fork or configure them manually. See the setup instructions for details.

---

## Setup (First Time)

### Step 1 — Bootstrap local keys and Terraform variables

```bash
bash scripts/01-bootstrap.sh
```

This will:
- Install `aws-cli`, `qrencode`, `terraform`, `jq`, `openssl` via pacman
- Install Tailscale via the official install script (https://tailscale.com/install.sh)
- Verify AWS CLI v2 is installed
- Generate BYOK KMS key material locally and import it into AWS KMS (for EBS encryption)
- Generate a dedicated ED25519 SSH key at `~/.ssh/wg_ec2_ed25519` (enter a strong passphrase)
- Write `terraform/terraform.tfvars` with SSH public key and KMS key ID

> **Safe to re-run** — all steps are idempotent. Existing keys and config are never overwritten.

### Step 2 — (Optional) Configure remote Terraform state

By default, state is stored locally. For production use, configure an S3 backend:

```bash
# 1. Create the S3 bucket and DynamoDB table first
aws s3 mb s3://YOUR-GLOBALLY-UNIQUE-BUCKET-NAME --region sa-east-1
aws dynamodb create-table --table-name wg-bastion-tf-lock \
  --attribute-definition AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region sa-east-1

# 2. Configure the backend
cp terraform/backend.tf.example terraform/backend_override.tf
# Edit the bucket name to match the bucket you created

# 3. Migrate state
cd terraform && terraform init -migrate-state
```

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
- IAM role (minimal — no SSM access needed)
- EC2 t3.nano (Debian 12) with instance profile attached
- Elastic IP associated with the instance
- VPC Flow Logs to CloudWatch

The instance self-configures via cloud-init on first boot (~3-5 min):
1. Installs packages (Headscale, Caddy, UFW, fail2ban, AWS CLI)
2. Configures Headscale with DERP relay (listening on localhost)
3. Configures Caddy as reverse proxy with self-signed TLS certificate
4. Configures UFW, SSH hardening, fail2ban
5. Reboots if security updates require it

### Step 5 — Register devices

```bash
bash scripts/02-configure-clients.sh
```

This will:
- Print the Headscale URL (HTTPS with self-signed certificate)
- Show how to generate an auth key via SSH
- Show how to register the desktop with `tailscale up --authkey`
- Explain mobile device limitations and workarounds

> **Note:** Since Headscale uses a self-signed certificate, you may need to add `--accept-risk` to the `tailscale up` command or configure your system to trust the certificate.

---

## Daily Operation

### Start the tunnel (leaving home)

```bash
bash scripts/vpn-up.sh
```

- Starts the EC2 instance (if stopped)
- Waits for EC2 status checks to pass
- Waits for Headscale to become ready
- Starts the local Tailscale client

### Stop the tunnel (returning home)

```bash
bash scripts/vpn-down.sh
```

- Stops the local Tailscale client
- Stops the EC2 instance to halt billing

> The Elastic IP is retained while the instance is stopped (~$0.005/hr). This keeps the Headscale endpoint stable so clients never need reconfiguration.

---

## Adding a Device

To add a new peer (e.g., a laptop):

```bash
bash scripts/add-device.sh
```

This will:
- Print the Headscale URL
- Show how to SSH into the EC2 instance
- Show how to generate a reusable auth key with `headscale preauthkeys create`
- Provide step-by-step instructions for the new device

> **Note:** Headscale must be running (EC2 must be up) to generate auth keys. Start the tunnel first with `vpn-up.sh`.

---

## Accessing Home Services (e.g., Jellyfin)

Once registered, all Tailscale devices can access each other directly:

```
# From tablet, access Jellyfin on desktop:
curl http://<desktop-tailscale-ip>:8096

# Or use the Tailscale hostname:
curl http://desktop:8096
```

When at home, devices are on the same LAN — no relay needed. When away, traffic goes through the encrypted DERP relay on EC2.

---

## Emergency SSH Access

If Headscale fails to come up, SSH directly to the EC2 using the public Elastic IP:

```bash
# Get the EIP
terraform -chdir=terraform output wg_elastic_ip

ssh -i ~/.ssh/wg_ec2_ed25519 -p 50022 wgadmin@<EIP>

# Diagnose on the instance
sudo journalctl -u headscale
```

---

## Teardown

To remove all AWS resources and stop billing entirely:

```bash
terraform -chdir=terraform destroy
```

This deletes the EC2 instance, Elastic IP, VPC, IAM roles, and flow logs. Your local KMS key material in `~/wireguard-keys/kms/` and the generated `tfvars` are left untouched, so you can re-provision later with `terraform apply`.

> **Note:** The BYOK KMS keys are created outside Terraform and are **not** deleted by `terraform destroy`. To remove them:
> ```bash
> aws kms schedule-key-deletion --key-id <KMS_KEY_ID> --pending-window-in-days 7 --region sa-east-1
> ```
> The key IDs are in `terraform/kms_keys.auto.tfvars.json`.

---

## File Structure

```
.
├── scripts/
│   ├── config.sh                  # Shared configuration (AWS region)
│   ├── 00-import-kms-keys.sh      # BYOK: generate local key material, import into AWS KMS
│   ├── 01-bootstrap.sh            # Local setup: KMS keys, tfvars
│   ├── 02-configure-clients.sh    # Register devices with Headscale
│   ├── add-device.sh              # Generate auth keys for new devices
│   ├── vpn-up.sh                  # Start EC2 + Tailscale
│   └── vpn-down.sh                # Stop Tailscale + EC2
├── terraform/
│   ├── main.tf                    # VPC, SG, EC2, EIP, Flow Logs
│   ├── variables.tf               # Input variables (SSH key, KMS key, region)
│   ├── init-ec2.sh.tftpl          # EC2 cloud-init: installs Headscale + Caddy (TLS) + DERP
│   ├── backend.tf.example         # S3 remote state backend template
│   ├── .terraform.lock.hcl        # Provider version lock (committed)
│   ├── terraform.tfvars           # Generated by 01-bootstrap.sh — gitignored
│   └── kms_keys.auto.tfvars.json  # Generated by 00-import-kms-keys.sh — gitignored
└── .gitignore
```

---

## Security Notes

- **No WireGuard private keys on EC2:** Headscale only stores public keys. The EC2 instance never has access to WireGuard private keys — they exist only on your devices.
- **Headscale coordination keys:** Headscale generates its own keys (private.key, noise_private.key, derp_private.key) on EC2 for the coordination protocol. These are not your WireGuard keys and cannot decrypt your traffic.
- **Self-signed TLS certificate:** The Headscale API uses HTTPS with a self-signed certificate (via Caddy). Clients must accept the self-signed cert or use `--accept-risk`. This protects against passive eavesdropping but not active MITM.
- **EBS encryption:** The EC2 root volume is encrypted with a customer-owned BYOK KMS key (key material generated locally).
- **Ephemeral by design:** EC2 runs only when you leave home. No persistent attack surface.
- **Local secrets:** `terraform.tfvars` contains the SSH public key and KMS key ID. `kms_keys.auto.tfvars.json` contains the BYOK KMS key ID. Both are gitignored.
- **BYOK key material:** The raw key material used for KMS encryption is stored at `~/wireguard-keys/kms/`. Delete it when you no longer need to re-import: `rm -rf ~/wireguard-keys/kms/`.
- **Remote state:** Use the S3 backend (`backend.tf.example`) to avoid storing state locally.
- **Mobile device limitations:** The official Tailscale mobile app does not support custom coordination servers. You'll need to use an unofficial fork or configure devices manually.
