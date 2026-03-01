# WhatsApp Setup (Recommended: Twilio)

## Why Twilio here

Twilio is the fastest path to initial terminal-driven setup, supports webhook-based bots, and can later move from sandbox to a dedicated WhatsApp sender.

## Reality check on provisioning

- You can buy a Twilio phone number via API/CLI.
- WhatsApp sender activation still requires Twilio/Meta onboarding steps.
- For fastest start, use Twilio WhatsApp Sandbox first, then promote to a dedicated sender.

## Minimum flow

1. Create Twilio account + API credentials.
2. Configure WhatsApp Sandbox (or dedicated sender when approved).
3. Point webhook to Paige endpoint on Lightsail.
4. Allowlist only your WhatsApp number in app config.

## Owner allowlist rule

Paige must process only inbound messages where `From == ALLOWED_WHATSAPP_FROM`.

Set this in `/opt/paige/.env`:

```env
ALLOWED_WHATSAPP_FROM=whatsapp:+1YOURNUMBER
```

## Suggested `/opt/paige/.env` fields

```env
# Twilio
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_WHATSAPP_NUMBER=whatsapp:+14155238886

# Owner lock
ALLOWED_WHATSAPP_FROM=whatsapp:+1YOURNUMBER

# Claudbot/app
CLAUDBOT_WEBHOOK_PORT=3000
CLAUDBOT_LOG_LEVEL=info
```

## Initial security posture (best effort)

- Keep `.env` only on instance (`chmod 600`)
- Do not commit secrets to git
- Keep SSH CIDR narrow in Terraform
- Move secrets to SSM/Secrets Manager when hardening
