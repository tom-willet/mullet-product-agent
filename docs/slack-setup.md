# Slack Setup (Recommended: Socket Mode)

## Why Socket Mode here

Socket Mode avoids public ingress and custom domain requirements. Paige opens an outbound WebSocket to Slack, which is simpler for a best-effort v1 on Lightsail.

## Minimum flow

1. Create Slack app in your workspace.
2. Enable Socket Mode and generate an app-level token.
3. Add bot scopes and install app to workspace.
4. Configure event subscriptions (or commands) required by claudbot.
5. Set owner-only allowlist in app config.

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

## Initial security posture (best effort)

- Keep `.env` only on instance (`chmod 600`)
- Do not commit secrets to git
- Keep SSH CIDR narrow in Terraform
- Move secrets to SSM/Secrets Manager when hardening
