# mullet-product-agent

Terraform-managed AWS Lightsail deployment for `openclaw/claudbot` (agent name: **Paige**) with a WhatsApp-first communication path.

## What this repo manages

- Terraform remote state bootstrap (S3 + DynamoDB lock table)
- Lightsail instance (`$5/mo` bundle), static IP, and public ports
- Daily Lightsail snapshots
- Monthly AWS budget alert
- IAM operator group/policy (optional attachment to existing user, default `mullet-dev`)
- Cloud-init provisioning for Docker + `openclaw/claudbot` deployment bootstrap

## Default architecture choices

- AWS region: `us-west-2`
- Instance size: `nano_3_0` (Lightsail Linux/Unix $5 tier target)
- OS image: `ubuntu_24_04`
- Deployment method: Docker Compose (installed by cloud-init)
- WhatsApp provider recommendation: **Twilio WhatsApp**
- Secrets strategy (v1): server-local `.env` at `/opt/paige/.env` with strict file perms

## Prerequisites

- Terraform >= 1.6
- AWS CLI configured with profile `mullet-dev`
- SSH public key available locally
- GitHub CLI (`gh`) if you want this repo created/pushed via CLI

## 1) Bootstrap Terraform remote state

```bash
cp terraform/bootstrap/terraform.tfvars.example terraform/bootstrap/terraform.tfvars
# edit values
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply
```

Capture outputs:
- `state_bucket_name`
- `lock_table_name`

## 2) Configure and deploy infrastructure

```bash
cp terraform/envs/prod/backend.hcl.example terraform/envs/prod/backend.hcl
cp terraform/envs/prod/terraform.tfvars.example terraform/envs/prod/terraform.tfvars
# edit backend.hcl + terraform.tfvars
terraform -chdir=terraform/envs/prod init -backend-config=backend.hcl
terraform -chdir=terraform/envs/prod plan
terraform -chdir=terraform/envs/prod apply
```

## 3) Post-provision steps on instance

After apply, SSH to the instance and configure app secrets:

```bash
ssh ubuntu@<STATIC_IP>
sudo cp /opt/paige/.env.example /opt/paige/.env
sudo chmod 600 /opt/paige/.env
sudo nano /opt/paige/.env
sudo systemctl restart paige-claudbot
```

## 4) WhatsApp onboarding

See [`docs/whatsapp-setup.md`](docs/whatsapp-setup.md).

## 5) Paige operating model

See [`docs/paige-operating-state.md`](docs/paige-operating-state.md).

## Notes

- No custom domain is required for initial setup.
- Start with best-effort ops; hardening can be added later (TLS, monitoring, secret manager, CI).
