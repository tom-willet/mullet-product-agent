# Slack Setup (Recommended: Socket Mode)

## Why Socket Mode here

Socket Mode avoids public ingress and custom domain requirements. Paige opens an outbound WebSocket to Slack, which is simpler for a best-effort v1 on Lightsail.

## Minimum flow

1. Create Slack app from manifest using [`slack/app-manifest.yaml`](../slack/app-manifest.yaml).
2. Enable Socket Mode and generate an app-level token (`xapp-...`) if not already enabled.
3. Install app to workspace to generate the bot token (`xoxb-...`).
4. Add required Slack secrets to `/opt/paige/.env`.
5. Set owner-only allowlist in app config.

## Create app from manifest

In Slack:

1. Go to `api.slack.com/apps` and choose `Create New App`.
2. Select `From an app manifest`.
3. Pick your workspace.
4. Paste the YAML from [`slack/app-manifest.yaml`](../slack/app-manifest.yaml).
5. Create app, then install it to your workspace.

## Owner allowlist rule

Paige must process only messages from your Slack user ID.

Set this in `/opt/paige/.env`:

```env
ALLOWED_SLACK_USER_ID=U0123456789
```

## Suggested `/opt/paige/.env` fields

```env
# Slack
SLACK_BOT_TOKEN=xoxb-...
SLACK_APP_TOKEN=xapp-...
SLACK_SIGNING_SECRET=...
SLACK_TEAM_ID=T0123456789

# Owner lock
ALLOWED_SLACK_USER_ID=U0123456789

# Claudbot/app
CLAUDBOT_WEBHOOK_PORT=3000
CLAUDBOT_LOG_LEVEL=info
```

You can also copy keys from [`.env.example`](../.env.example).

## Initial security posture (best effort)

- Keep `.env` only on instance (`chmod 600`)
- Do not commit secrets to git
- Keep SSH CIDR narrow in Terraform
- Move secrets to SSM/Secrets Manager when hardening
