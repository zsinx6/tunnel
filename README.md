# tunnel

Ephemeral Tailscale DERP relay on AWS EC2 with self-hosted Headscale, designed for CGNAT environments. No WireGuard private keys ever leave your devices — the EC2 relay only forwards encrypted packets and stores public keys in Headscale. TLS uses a real domain with a Let's Encrypt certificate obtained by Caddy **on the instance** (the TLS private key never leaves the box either).

```
Arch Desktop (CGNAT)            EC2 Relay (sa-east-1)           Android Tablet
  100.64.x.x                      DERP relay only                 100.64.x.x
      │                                  │                              │
      └── Tailscale (encrypted) ─────────┤─────────── Tailscale (encrypted) ─┘
                                  Headscale coordinator
                                  https://<your-domain>
                                  (public keys only, no private keys)
```

When at home, devices connect directly via LAN — the EC2 instance is off. When leaving home, `vpn-up.sh` starts the EC2 relay and Tailscale clients connect through it.

---

## Security Properties

| Property | Implementation |
|---|---|
| Transport encryption | Tailscale (WireGuard under the hood, Curve25519, ChaCha20-Poly1305) |
| API encryption | Headscale API served over HTTPS with a Let's Encrypt certificate (Caddy reverse proxy); clients fully verify TLS — no trust-store hacks |
| Key ownership | WireGuard private keys generated on your devices only — never on EC2 or any server. The TLS private key is generated on the instance and never leaves it |
| EC2 role | DERP relay (encrypted packet forwarder) + Headscale coordinator (public keys only) |
| DERP access control | `verify_clients: true` — only nodes registered in Headscale may use the relay; strangers cannot relay traffic through it |
| DERP privacy | `derp.urls` is empty — clients use only your relay, never Tailscale Inc's DERP servers |
| Headscale keys | Headscale's own coordination keys (noise, DERP) are generated on EC2 — these protect the coordination protocol, not your traffic |
| EC2 disk | EBS encrypted at rest with customer-owned BYOK KMS key |
| EC2 access | Key-only SSH on non-standard port 50022, fail2ban (systemd backend, watching port 50022), non-root user (`wgadmin`) with scoped sudo |
| SSH access control | Configurable CIDR allowlist (`ssh_allowed_cidrs` variable) |
| EC2 metadata | IMDSv2 enforced (SSRF protection); the instance has **no IAM role** — nothing to steal |
| IPv6 | Disabled on EC2 to prevent bypass leaks |
| Network forensics | VPC Flow Logs (REJECT traffic) to CloudWatch, 30-day retention |
| CPU billing | `standard` credit mode prevents unexpected billing spikes |
| Ephemeral | EC2 runs only when needed — off most of the time, no persistent attack surface |

> **What AWS can and cannot see:** DERP relays end-to-end WireGuard-encrypted frames, so recorded traffic cannot be decrypted by AWS or anyone with the disk. However, the instance *is* the coordinator (the tailnet's trust root): an attacker with live access to it could mint auth keys and join rogue nodes to your tailnet going forward. Mitigations: the instance is off most of the time, registration requires operator-approved keys, and you can audit nodes with `sudo headscale nodes list`.

> **Privacy trade-off of Let's Encrypt:** the hostname you choose appears in public Certificate Transparency logs. Use a bland subdomain (e.g. `hs.yourdomain.com`). No key material goes to Let's Encrypt — only a certificate signing request.

---

## Prerequisites

- AWS CLI v2 configured (`aws configure`) with permissions to EC2, EIP, KMS, IAM, and CloudWatch Logs (plus S3/DynamoDB if you use remote state, and Route53 if Terraform manages your DNS record)
- Terraform >= 1.3
- A DNS name you control (e.g. `hs.example.com`) for the Headscale endpoint
- Arch Linux desktop (packages installed by `01-bootstrap.sh`, including `tailscale` from the official repos)
- Tailscale app on mobile devices (the official app — it supports custom coordination servers)

---

## Setup

### Step 1 — Bootstrap local machine

```bash
bash scripts/01-bootstrap.sh
```

This will:
- Install `aws-cli-v2`, `terraform`, `jq`, `openssl`, `tailscale` via pacman (no curl-pipe-to-shell)
- Verify AWS CLI v2 is installed
- Generate BYOK KMS key material locally and import it into AWS KMS (for EBS encryption)
- Generate a dedicated ED25519 SSH key at `~/.ssh/wg_ec2_ed25519` (enter a strong passphrase)
- Prompt for your Headscale domain
- Write `terraform/terraform.tfvars` with the SSH public key, KMS key ID, and domain

> **Safe to re-run** — all steps are idempotent. Existing keys and config are never overwritten, and an interrupted KMS import resumes with the same key instead of creating orphans.

### Step 2 — (Optional) Remote state backend

By default, state is stored locally. For production use, configure an S3 backend:

```bash
# 1. Create the S3 bucket and DynamoDB table first
aws s3 mb s3://YOUR-GLOBALLY-UNIQUE-BUCKET-NAME --region sa-east-1
aws dynamodb create-table --table-name wg-bastion-tf-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region sa-east-1

# 2. Copy the example and fill in your bucket name
cp terraform/backend.tf.example terraform/backend_override.tf

# 3. Re-initialize
cd terraform && terraform init -migrate-state
```

### Step 3 — (Optional) Restrict SSH access

By default, SSH (port 50022) is open to `0.0.0.0/0` (key-only auth + fail2ban still apply, and you may genuinely need SSH from unknown networks while travelling). To restrict to known networks:

```bash
echo 'ssh_allowed_cidrs = ["203.0.113.0/24"]' >> terraform/terraform.tfvars
```

### Step 4 — Provision AWS

```bash
cd terraform
terraform init
terraform apply
```

This creates:
- VPC, subnet, internet gateway, hardened security group (50022, 80, 443, 3478/udp)
- EC2 t3.nano (Debian 12) — no IAM instance profile (only a scoped flow-logs role exists, for the VPC)
- Elastic IP associated with the instance
- VPC Flow Logs (REJECT) to CloudWatch
- Optionally, the DNS A record — if you set `route53_zone_id` in `terraform.tfvars`

The instance self-configures via cloud-init on first boot (~3-5 min):
1. Creates `wgadmin`, hardens SSH onto port 50022 **first** (so a later failure never bricks access), locks the AMI's default `admin` user
2. Installs packages, configures UFW and fail2ban (systemd backend, port 50022)
3. Installs Headscale 0.29.2 (checksum-verified) with embedded DERP, `verify_clients` on, and no external DERP map
4. Installs Caddy, which obtains the Let's Encrypt certificate for your domain
5. Reboots only if a kernel upgrade was installed

### Step 5 — Point DNS at the relay (skip if using Route53)

After `terraform apply`, the exact record is printed by:

```bash
terraform output dns_setup
```

**Worked example — reusing `zsinx6.dev` (which already serves the blog):**

A subdomain is an independent DNS name: the blog's records (`zsinx6.dev`, `www.zsinx6.dev`) are untouched, no nameserver changes, nothing to migrate. In the DNS panel of whatever currently hosts `zsinx6.dev`'s DNS, add **one** record:

| Field | Value |
|---|---|
| Type | `A` |
| Name | `hs` (some panels want the full `hs.zsinx6.dev`) |
| Value | the Elastic IP from `terraform output wg_elastic_ip` |
| TTL | 300 (or the panel default) |

Then verify (may take 1–5 minutes to propagate):

```bash
dig +short hs.zsinx6.dev   # must print the Elastic IP
```

This is **one-time**: the Elastic IP is permanent (retained while the instance is stopped), so the record never needs updating.

Notes:
- **Cloudflare DNS users:** set the record to **DNS only** (grey cloud), *not* proxied — the proxy would terminate TLS itself and break Headscale/DERP.
- `.dev` is HSTS-preloaded (browsers force HTTPS on it) — fine here, since the relay only ever serves HTTPS with a real Let's Encrypt certificate.
- Caddy retries certificate issuance automatically, so it is fine that the record is created after the instance boots.
- Full automation is only possible when Terraform can talk to the DNS host: if you ever move `zsinx6.dev` (or just this subdomain) to Route53, set `route53_zone_id` in `terraform.tfvars` and Terraform manages the record itself.

### Step 6 — Register the desktop

```bash
bash scripts/02-configure-clients.sh
```

This will:
- Verify DNS resolves to the Elastic IP
- Start the EC2 instance if needed and wait for `https://<domain>/health` (with full TLS verification)
- Generate a **single-use, 15-minute** auth key over SSH
- Run `tailscale up --login-server https://<domain> --auth-key file:...` (the key is passed via file, not command line)
- Refuse to silently switch the machine if it is already registered against a different control server
- Print instructions for mobile devices

---

## Daily Usage

### Start the tunnel (before leaving home)

```bash
bash scripts/vpn-up.sh
```

- Starts the EC2 instance (if stopped)
- Waits for `https://<domain>/health` (proves EC2 + Headscale + Caddy + TLS end-to-end)
- Starts the local Tailscale client (with a timeout, so an expired node key fails loudly instead of hanging)
- If anything fails after the instance started, prints an unmissable warning that the instance is still running

### Stop the tunnel (returning home)

```bash
bash scripts/vpn-down.sh
```

- Stops the local Tailscale client
- Stops **all** tagged instances, including ones still starting (`pending`), and verifies they reached `stopped`

---

## Adding New Devices

```bash
bash scripts/add-device.sh
```

This checks that Headscale is reachable, generates a **single-use, 15-minute** auth key, and prints setup instructions:

- **Linux/desktop:** one `tailscale up` command with the key (safe to have in history — single-use and expired within 15 minutes).
- **Mobile:** the **official Tailscale app** supports custom coordination servers — Android: "Use an alternate server"; iOS: "Alternate Coordination Server URL". Enter your Headscale URL, sign in, and run the `headscale nodes register ...` command the browser page shows (via SSH with sudo). No certificate installation is needed.

> Headscale must be running (EC2 must be up) to generate auth keys. Start the tunnel first with `vpn-up.sh`.

---

## Accessing Home Services (e.g., Jellyfin)

Once registered, all Tailscale devices can access each other directly:

```
# From tablet, access Jellyfin on desktop:
curl http://<desktop-tailscale-ip>:8096

# Or use the MagicDNS hostname (enabled; base domain ts.internal):
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

# Diagnose on the instance (headscale + caddy + fail2ban logs)
sudo tunnel-logs
```

If the instance was ever re-provisioned, clear the stale host key first: `ssh-keygen -R '[<EIP>]:50022'`.

---

## Migrating from the WireGuard version (main branch)

If this AWS deployment (and your desktop) were set up from `main` — the WireGuard hub-and-spoke design — run the migration helper once:

```bash
bash scripts/migrate-from-main.sh
```

It is interactive, idempotent, and moves old secrets to `~/wireguard-keys/migration-backup-main/` instead of deleting them. It will:

1. Stop/disable `wg-quick@wg0` and retire `/etc/wireguard/wg0.conf`
2. Remove the stale `wg-bastion` SSH alias and stale `known_hosts` entries
3. Retire `peers.auto.tfvars.json` and the old `terraform.tfvars` (which contains the WireGuard server private key)
4. Retire the obsolete WireGuard key files in `~/wireguard-keys/` (keeping `kms/`)
5. Re-run the bootstrap (KMS key import, new tfvars, domain prompt)

Then apply and reconnect:

```bash
terraform -chdir=terraform apply     # replaces the instance, the security group
                                     # (description change) and the flow log
                                     # (ALL -> REJECT); destroys SSM params, the
                                     # old IAM role/profile and key pair;
                                     # KEEPS the Elastic IP (same address)
terraform -chdir=terraform output dns_setup   # create the printed A record
bash scripts/02-configure-clients.sh          # re-register this desktop
```

Mobile/tablet: the old WireGuard tunnels are dead — delete those WireGuard app profiles and register through the Tailscale app via `add-device.sh`. Once everything works, shred the backup directory **and** the pre-migration state backup — the old design stored the WireGuard server key and PSKs in Terraform state (the script prints the exact commands):

```bash
shred -u terraform/terraform.tfstate.backup
```

**Lost the state file?** If the old deployment's `terraform.tfstate` is gone but the infra was never hand-modified, run:

```bash
bash scripts/destroy-old-main-infra.sh
```

It rebuilds the state with `terraform import` against a throwaway git worktree of `main` (nothing drifted, so imports are exact), then runs `terraform destroy` — you review the plan and confirm. Afterwards deploy fresh: `01-bootstrap.sh` → `terraform apply` → DNS → `02-configure-clients.sh`. A new Elastic IP is allocated, which is harmless as long as the DNS record hasn't been created yet.

---

## Re-provisioning Caveats

Replacing the EC2 instance (changing `user_data`, or `terraform destroy`/`apply`) wipes the Headscale database and host keys:

- **All devices must re-register** (`02-configure-clients.sh` / `add-device.sh`).
- **SSH host keys change** — run `ssh-keygen -R '[<EIP>]:50022'` before reconnecting.
- The AMI is intentionally **not** tracked (`ignore_changes = [ami]`), so a new upstream Debian AMI release does not force a surprise replacement. Side effect: a replacement re-creates the instance with the AMI recorded in state; if Debian has deregistered that AMI by then, the apply fails — temporarily remove `ignore_changes = [ami]` to pick up the current AMI and re-apply.
- The Let's Encrypt certificate is re-issued automatically on the new instance (same domain).

---

## Costs (mostly-off usage)

The "off" state, not the instance, dominates the bill:

| Item | Cost |
|---|---|
| Elastic IP (billed 24/7, also while instance is stopped) | ~$3.70/mo |
| KMS customer key | $1.00/mo |
| EBS 8 GB gp3 | ~$0.80/mo |
| t3.nano at ~10 h/mo | ~$0.10/mo |

The EIP is the price of a stable endpoint (DNS record and SSH host key never change). Releasing it between sessions would save ~$3.7/mo but break DNS and host-key pinning on every cycle.

---

## Teardown

To remove all AWS resources and stop billing entirely:

```bash
terraform -chdir=terraform destroy
```

This deletes the EC2 instance, Elastic IP, VPC, IAM role, and flow logs. Your local KMS key material in `~/wireguard-keys/kms/` and the generated `tfvars` are left untouched, so you can re-provision later with `terraform apply` (see re-provisioning caveats above).

> **Note:** The BYOK KMS key is created outside Terraform and is **not** deleted by `terraform destroy`. To remove it:
> ```bash
> aws kms schedule-key-deletion --key-id <KMS_KEY_ID> --pending-window-in-days 7 --region sa-east-1
> ```
> The key ARN is in `terraform/kms_keys.auto.tfvars.json`. If you delete the key, also delete `terraform/kms_keys.auto.tfvars.json` and `~/wireguard-keys/kms/` before re-provisioning, so the bootstrap creates a fresh key instead of reusing a stale one.

---

## File Structure

```
.
├── scripts/
│   ├── config.sh                  # Shared configuration (region, SSH user/port/key, instance tag)
│   ├── 00-import-kms-keys.sh      # BYOK: generate local key material, import into AWS KMS
│   ├── 01-bootstrap.sh            # Local setup: packages, KMS keys, SSH key, tfvars (incl. domain)
│   ├── 02-configure-clients.sh    # Register the desktop with Headscale
│   ├── add-device.sh              # Generate one-time auth keys for new devices
│   ├── migrate-from-main.sh       # One-time migration from the WireGuard design
│   ├── destroy-old-main-infra.sh  # Lost-state recovery: import + destroy the old design
│   ├── vpn-up.sh                  # Start EC2 + Tailscale
│   └── vpn-down.sh                # Stop Tailscale + EC2 (verifies the stop)
├── terraform/
│   ├── main.tf                    # VPC, SG, EC2, EIP, Flow Logs, optional Route53 record
│   ├── variables.tf               # Input variables (SSH key, KMS key, domain, region)
│   ├── init-ec2.sh.tftpl          # EC2 cloud-init: Headscale + Caddy (Let's Encrypt) + DERP
│   ├── backend.tf.example         # S3 remote state backend template
│   ├── .terraform.lock.hcl        # Provider version lock (committed)
│   ├── terraform.tfvars           # Generated by 01-bootstrap.sh — gitignored
│   └── kms_keys.auto.tfvars.json  # Generated by 00-import-kms-keys.sh — gitignored
└── .gitignore
```

---

## Security Notes

- **No WireGuard private keys on EC2:** Headscale only stores public keys. Your devices' private keys exist only on your devices.
- **TLS key stays on the box:** Caddy generates the TLS private key on the instance; Let's Encrypt only ever receives a CSR. Clients verify the certificate normally — there is no flag to skip TLS verification in Tailscale, and none is needed.
- **DERP is not an open relay:** `verify_clients: true` restricts relaying to nodes registered in your Headscale. Registration itself requires operator-generated keys (single-use, 15-minute expiry, passed via `--auth-key file:` so they never appear in process listings).
- **Scoped sudo on the instance:** `wgadmin` can run only `headscale preauthkeys/nodes/users` subcommands and a fixed `tunnel-logs` script (unrestricted `journalctl` is a known root-shell escape via its pager, so it is not granted).
- **BYOK, honestly:** after import, AWS KMS holds a copy of the key material and uses it for all EBS operations — BYOK does **not** hide data from AWS. Its value here is provenance and the ability to delete the imported material (`aws kms delete-imported-key-material`) as a kill switch. The local copy at `~/wireguard-keys/kms/` exists solely so you can re-import after such a deletion. EBS encryption protects against physical-media exposure, not against the cloud provider.
- **Updates:** the instance refreshes package lists and installs security updates on every boot (it is powered off for weeks at a time, so this happens at the start of every session), rebooting only for kernel upgrades. Headscale itself is a pinned, checksum-verified release — update `HEADSCALE_VERSION` in `init-ec2.sh.tftpl` periodically and re-provision.
- **Remote state:** use the S3 backend (`backend.tf.example`) to avoid storing state locally. State contains no private keys in this design (unlike the old WireGuard design — after migrating, shred the old state backup as described above), but treat it as sensitive anyway.
