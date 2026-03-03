#!/usr/bin/env bash
set -Eeuo pipefail

# Optional debug tracing: DEBUG=1 ./scripts/recover_and_reconcile_paige.sh
if [[ "${DEBUG:-0}" == "1" ]]; then
  set -x
fi

on_error() {
  local exit_code=$?
  echo "ERROR: command failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
  echo "ERROR: exit code ${exit_code}" >&2
  exit "$exit_code"
}
trap on_error ERR

# Deterministic recovery + reconcile flow for Paige on Lightsail.
# 1) Ensure instance reaches stopped -> running states
# 2) Refresh temporary SSH credentials
# 3) Sync local .env to /opt/paige/.env
# 4) Restart paige-claudbot and print health snapshot

AWS_PROFILE="${AWS_PROFILE:-mullet-dev}"
AWS_REGION="${AWS_REGION:-us-west-2}"
INSTANCE_NAME="${INSTANCE_NAME:-mullet-product-agent-prod-instance}"
INSTANCE_IP="${INSTANCE_IP:-54.187.38.122}"
LOCAL_ENV_FILE="${LOCAL_ENV_FILE:-.env}"
SSH_KEY_FILE="/tmp/paige-lightsail.key"
SSH_CERT_FILE="/tmp/paige-lightsail.key-cert.pub"
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
  -o StrictHostKeyChecking=accept-new
  -T
  -i "$SSH_KEY_FILE"
)

if [[ ! -f "$LOCAL_ENV_FILE" ]]; then
  echo "ERROR: local env file not found: $LOCAL_ENV_FILE"
  exit 1
fi

# Fail fast on malformed shell syntax in .env (unclosed quotes/backticks, etc.).
if ! bash -n "$LOCAL_ENV_FILE" >/tmp/paige-env-syntax.out 2>/tmp/paige-env-syntax.err; then
  echo "ERROR: malformed .env syntax in $LOCAL_ENV_FILE"
  cat /tmp/paige-env-syntax.err
  echo "Tip: check the referenced line for stray backticks/quotes."
  exit 1
fi

required_keys=(
  SLACK_BOT_TOKEN
  SLACK_APP_TOKEN
  SLACK_SIGNING_SECRET
  SLACK_TEAM_ID
  ALLOWED_SLACK_USER_ID
  OPENAI_API_KEY
)
for key in "${required_keys[@]}"; do
  if ! grep -q "^${key}=" "$LOCAL_ENV_FILE"; then
    echo "ERROR: missing $key in $LOCAL_ENV_FILE"
    exit 1
  fi
done

echo "[1/7] Requesting stop (best effort)"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail stop-instance --instance-name "$INSTANCE_NAME" >/dev/null 2>&1 || true

echo "[2/7] Waiting for instance to stop"
until [[ "$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail get-instance --instance-name "$INSTANCE_NAME" --query 'instance.state.name' --output text)" == "stopped" ]]; do
  sleep 5
done

echo "[3/7] Starting instance"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail start-instance --instance-name "$INSTANCE_NAME" >/dev/null

echo "[4/7] Waiting for instance to run"
until [[ "$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail get-instance --instance-name "$INSTANCE_NAME" --query 'instance.state.name' --output text)" == "running" ]]; do
  sleep 5
done

echo "[5/7] Refreshing temporary SSH credentials"
AWS_PAGER='' aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail get-instance-access-details \
  --instance-name "$INSTANCE_NAME" --protocol ssh --output json >/tmp/paige-access.json
jq -r '.accessDetails.privateKey' /tmp/paige-access.json >/tmp/paige-lightsail.key
jq -r '.accessDetails.certKey' /tmp/paige-access.json >/tmp/paige-lightsail.key-cert.pub
chmod 600 /tmp/paige-lightsail.key /tmp/paige-lightsail.key-cert.pub

echo "[6/7] Waiting for SSH to accept connections"
ready=no
for _ in $(seq 1 30); do
  if ssh "${SSH_OPTS[@]}" "ubuntu@${INSTANCE_IP}" 'echo ssh-ready' >/dev/null 2>&1; then
    ready=yes
    break
  fi
  sleep 5
done

if [[ "$ready" != "yes" ]]; then
  echo "ERROR: SSH did not become ready in time on ${INSTANCE_IP}"
  exit 1
fi

echo "[7/7] Syncing env, restarting service, and health snapshot"
scp -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_FILE" "$LOCAL_ENV_FILE" "ubuntu@${INSTANCE_IP}:/tmp/paige.env" >/dev/null
RECONCILE_REMOTE_LOCAL="/tmp/paige-reconcile-remote.sh"
cat > "$RECONCILE_REMOTE_LOCAL" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

install -m 600 /tmp/paige.env /opt/paige/.env

ENV=/opt/paige/.env

ensure_trailing_newline() {
  if [[ -s "$ENV" ]] && [[ "$(tail -c 1 "$ENV" | wc -l)" -eq 0 ]]; then
    echo >>"$ENV"
  fi
}

upsert() {
  key="$1"
  val="$2"
  tmp="$(mktemp)"
  awk -v k="$key" 'index($0, k"=") == 1 {next} {print}' "$ENV" >"$tmp"
  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  install -m 600 "$tmp" "$ENV"
  rm -f "$tmp"
}

get_env_value() {
  local key="$1"
  grep -E "^${key}=" "$ENV" | tail -n1 | cut -d= -f2- || true
}

upsert_if_missing_or_empty() {
  local key="$1"
  local default_val="$2"
  local current
  current="$(get_env_value "$key")"
  if [[ -z "$current" ]]; then
    upsert "$key" "$default_val"
  fi
}

upsert OPENCLAW_CONFIG_DIR /opt/paige/state
upsert OPENCLAW_WORKSPACE_DIR /opt/paige/workspace
upsert OPENCLAW_GATEWAY_BIND lan
upsert OPENCLAW_GATEWAY_PORT 18789
upsert OPENCLAW_BRIDGE_PORT 18790
upsert OPENCLAW_IMAGE ghcr.io/openclaw/openclaw:latest

upsert_if_missing_or_empty OPENCLAW_GATEWAY_TOKEN "$(openssl rand -hex 24)"
upsert_if_missing_or_empty OPENCLAW_MODEL_PRIMARY openai/gpt-5.2
upsert_if_missing_or_empty OPENCLAW_MODEL_FALLBACKS openai/gpt-5.1-codex
upsert_if_missing_or_empty OPENCLAW_SLACK_DM_POLICY open
upsert_if_missing_or_empty NODE_OPTIONS --max-old-space-size=768

ensure_trailing_newline

CFG=/opt/paige/state/openclaw.json
TMP=/tmp/openclaw.json.reconcile.tmp
ALLOWED="$(get_env_value ALLOWED_SLACK_USER_ID)"
GATEWAY_TOKEN="$(get_env_value OPENCLAW_GATEWAY_TOKEN)"
MODEL_PRIMARY="$(get_env_value OPENCLAW_MODEL_PRIMARY)"
MODEL_FALLBACKS_RAW="$(get_env_value OPENCLAW_MODEL_FALLBACKS)"
SLACK_DM_POLICY="$(get_env_value OPENCLAW_SLACK_DM_POLICY)"
SLACK_BOT_TOKEN="$(get_env_value SLACK_BOT_TOKEN)"
SLACK_APP_TOKEN="$(get_env_value SLACK_APP_TOKEN)"
SLACK_SIGNING_SECRET="$(get_env_value SLACK_SIGNING_SECRET)"

if [[ -z "$ALLOWED" ]]; then
  echo "ERROR: ALLOWED_SLACK_USER_ID is required in /opt/paige/.env" >&2
  exit 1
fi
if [[ -z "$SLACK_BOT_TOKEN" || -z "$SLACK_APP_TOKEN" ]]; then
  echo "ERROR: SLACK_BOT_TOKEN and SLACK_APP_TOKEN are required in /opt/paige/.env" >&2
  exit 1
fi
if [[ -z "$SLACK_DM_POLICY" ]]; then
  SLACK_DM_POLICY="open"
fi
if [[ "$SLACK_DM_POLICY" != "open" && "$SLACK_DM_POLICY" != "allowlist" ]]; then
  echo "ERROR: OPENCLAW_SLACK_DM_POLICY must be 'open' or 'allowlist'" >&2
  exit 1
fi

FALLBACKS_JSON='[]'
if [[ -n "$MODEL_FALLBACKS_RAW" ]]; then
  IFS=',' read -r -a FB_ARR <<<"$MODEL_FALLBACKS_RAW"
  FALLBACKS_JSON='['
  SEP=''
  for fb in "${FB_ARR[@]}"; do
    fb="$(printf '%s' "$fb" | sed -e 's/^ *//' -e 's/ *$//')"
    [[ -z "$fb" ]] && continue
    FALLBACKS_JSON+="$SEP\"$fb\""
    SEP=','
  done
  FALLBACKS_JSON+=']'
fi

jq -n \
  --arg token "$GATEWAY_TOKEN" \
  --arg allowed "$ALLOWED" \
  --arg dm_policy "$SLACK_DM_POLICY" \
  --arg slack_bot_token "$SLACK_BOT_TOKEN" \
  --arg slack_app_token "$SLACK_APP_TOKEN" \
  --arg slack_signing_secret "$SLACK_SIGNING_SECRET" \
  --arg model_primary "$MODEL_PRIMARY" \
  --argjson model_fallbacks "$FALLBACKS_JSON" \
  '{
    gateway: { mode: "local", auth: { token: $token } },
    channels: { slack: { enabled: true, mode: "socket", botToken: $slack_bot_token, appToken: $slack_app_token, signingSecret: $slack_signing_secret, dmPolicy: $dm_policy, allowFrom: [$allowed], groupPolicy: "disabled" } },
    agents: { defaults: { model: { primary: $model_primary, fallbacks: $model_fallbacks } } }
  }' >"$TMP"
install -m 644 "$TMP" "$CFG"

chmod 600 "$ENV"
mkdir -p /opt/paige/state /opt/paige/workspace
chown -R 1000:1000 /opt/paige/state /opt/paige/workspace
find /opt/paige/state -type d -exec chmod 755 {} \;
find /opt/paige/state -type f -exec chmod 644 {} \;
find /opt/paige/workspace -type d -exec chmod 755 {} \;
find /opt/paige/workspace -type f -exec chmod 644 {} \;

# Keep any local repo edits, but clear worktree so paige-deploy can fast-forward.
if [[ -d /opt/paige/openclaw/.git ]]; then
  git -C /opt/paige/openclaw stash push -u -m "paige-auto-reconcile-$(date +%s)" >/dev/null 2>&1 || true
fi

systemctl restart paige-claudbot || true
REMOTE
chmod +x "$RECONCILE_REMOTE_LOCAL"
scp -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_FILE" "$RECONCILE_REMOTE_LOCAL" "ubuntu@${INSTANCE_IP}:/tmp/paige-reconcile-remote.sh" >/dev/null
ssh "${SSH_OPTS[@]}" "ubuntu@${INSTANCE_IP}" "sudo bash -x /tmp/paige-reconcile-remote.sh"

echo "[7a] Checking service state"
# Always surface systemd diagnostics when service did not come up.
svc_state="$(ssh "${SSH_OPTS[@]}" "ubuntu@${INSTANCE_IP}" 'sudo systemctl is-active paige-claudbot || true')"
if [[ "$svc_state" != "active" ]]; then
  echo "SERVICE=${svc_state}"
  echo "--- systemctl status ---"
  ssh "${SSH_OPTS[@]}" "ubuntu@${INSTANCE_IP}" 'sudo systemctl status paige-claudbot --no-pager | sed -n "1,80p"' || true
  echo "--- journalctl (last 80) ---"
  ssh "${SSH_OPTS[@]}" "ubuntu@${INSTANCE_IP}" 'sudo journalctl -u paige-claudbot -n 80 --no-pager' || true
  exit 1
fi

echo "[7b] Collecting health snapshot"
HEALTH_CHECK_SCRIPT="$(cat <<'REMOTE'
set -e
echo "SERVICE=$(sudo systemctl is-active paige-claudbot || true)"
echo "MODEL_PRIMARY=$(sudo jq -r '.agents.defaults.model.primary // ""' /opt/paige/state/openclaw.json 2>/dev/null || true)"
echo "MODEL_FALLBACKS=$(sudo jq -c '.agents.defaults.model.fallbacks // []' /opt/paige/state/openclaw.json 2>/dev/null || true)"
CID="$(sudo docker ps -q --filter name=openclaw-gateway | head -n1)"
echo "CONTAINER_ID=${CID}"
if [[ -n "$CID" ]]; then
  sudo docker inspect "$CID" --format "CONTAINER_STATUS={{.State.Status}} RESTART_COUNT={{.RestartCount}}"
  echo "--- recent logs (filtered) ---"
  sudo docker logs --tail 120 "$CID" 2>&1 | egrep -i "error|fail|auth|openai|model|slack|quota|rate|invalid|exception" || true
fi
REMOTE
)"
ssh "${SSH_OPTS[@]}" "ubuntu@${INSTANCE_IP}" "bash -s" <<<"$HEALTH_CHECK_SCRIPT"

echo "--- Enforcing compose env passthrough ---"
COMPOSE_ENFORCE_SCRIPT="$(cat <<'REMOTE'
set -e
REPO_DIR="/opt/paige/openclaw"
ENV_FILE="/opt/paige/.env"

cd "$REPO_DIR"

if ! grep -q 'NODE_OPTIONS: ${NODE_OPTIONS:-' docker-compose.yml; then
  awk '
    BEGIN {in_gateway=0; in_gateway_env=0; inserted=0}
    /^  openclaw-gateway:/ {in_gateway=1}
    in_gateway && /^    environment:/ {in_gateway_env=1}
    {
      print
      if (in_gateway_env && /^      CLAUDE_WEB_COOKIE:/) {
        print "      NODE_OPTIONS: ${NODE_OPTIONS:---max-old-space-size=768}"
        print "      OPENAI_API_KEY: ${OPENAI_API_KEY:-}"
        print "      SLACK_BOT_TOKEN: ${SLACK_BOT_TOKEN:-}"
        print "      SLACK_APP_TOKEN: ${SLACK_APP_TOKEN:-}"
        print "      SLACK_SIGNING_SECRET: ${SLACK_SIGNING_SECRET:-}"
        inserted=1
        in_gateway_env=0
      }
      if (in_gateway && /^  openclaw-cli:/) {in_gateway=0}
    }
    END { if (!inserted) exit 2 }
  ' docker-compose.yml > docker-compose.yml.tmp
  mv docker-compose.yml.tmp docker-compose.yml
fi

if ! grep -q '^NODE_OPTIONS=' "$ENV_FILE"; then
  echo 'NODE_OPTIONS=--max-old-space-size=768' | sudo tee -a "$ENV_FILE" >/dev/null
fi

sudo docker compose -f "$REPO_DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d openclaw-gateway >/dev/null
CID="$(sudo docker ps -q --filter name=openclaw-gateway | head -n1)"
echo "COMPOSE_ENFORCE_CID=$CID"
if [[ -n "$CID" ]]; then
  sudo docker inspect "$CID" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | egrep '^(NODE_OPTIONS|OPENAI_API_KEY|SLACK_BOT_TOKEN|SLACK_APP_TOKEN|SLACK_SIGNING_SECRET)=' \
    | cut -d= -f1 || true
fi
REMOTE
)"
ssh "${SSH_OPTS[@]}" "ubuntu@${INSTANCE_IP}" "sudo bash -s" <<<"$COMPOSE_ENFORCE_SCRIPT"

echo "--- Enforcing runtime model ---"
MODEL_ENFORCE_SCRIPT="$(cat <<'REMOTE'
set -e
CID="$(sudo docker ps -q --filter name=openclaw-gateway | head -n1)"
if [[ -z "$CID" ]]; then
  echo "MODEL_ENFORCE=skipped_no_container"
  exit 0
fi

# Force model config directly in mounted state file, then restart only gateway container.
CFG="/opt/paige/state/openclaw.json"
TMP="/tmp/openclaw.model.tmp"
ENV_FILE="/opt/paige/.env"
DM_POLICY="$(sudo grep -E '^OPENCLAW_SLACK_DM_POLICY=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
ALLOWED_USER="$(sudo grep -E '^ALLOWED_SLACK_USER_ID=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
SLACK_BOT_TOKEN="$(sudo grep -E '^SLACK_BOT_TOKEN=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
SLACK_APP_TOKEN="$(sudo grep -E '^SLACK_APP_TOKEN=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
SLACK_SIGNING_SECRET="$(sudo grep -E '^SLACK_SIGNING_SECRET=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
[[ -z "$DM_POLICY" ]] && DM_POLICY="open"

if [[ -z "$SLACK_BOT_TOKEN" || -z "$SLACK_APP_TOKEN" ]]; then
  echo "MODEL_ENFORCE=failed_missing_slack_tokens"
  exit 1
fi

if [[ "$DM_POLICY" == "open" ]]; then
  sudo jq --arg bot "$SLACK_BOT_TOKEN" --arg app "$SLACK_APP_TOKEN" --arg sign "$SLACK_SIGNING_SECRET" '.
    | .channels = ((.channels // {}) + {slack: (((.channels // {}).slack // {}) + {mode: "socket", botToken: $bot, appToken: $app, signingSecret: $sign, dmPolicy: "open", allowFrom: ["*"]})})
    | .agents = ((.agents // {}) + {defaults: (((.agents // {}).defaults // {}) + {model: ((((.agents // {}).defaults // {}).model // {}) + {primary: "openai/gpt-5.2", fallbacks: ["openai/gpt-5.1-codex"]})})})
  ' "$CFG" > "$TMP"
else
  sudo jq --arg bot "$SLACK_BOT_TOKEN" --arg app "$SLACK_APP_TOKEN" --arg sign "$SLACK_SIGNING_SECRET" --arg allowed "$ALLOWED_USER" '.
    | .channels = ((.channels // {}) + {slack: (((.channels // {}).slack // {}) + {mode: "socket", botToken: $bot, appToken: $app, signingSecret: $sign, dmPolicy: "allowlist", allowFrom: [$allowed]})})
    | .agents = ((.agents // {}) + {defaults: (((.agents // {}).defaults // {}) + {model: ((((.agents // {}).defaults // {}).model // {}) + {primary: "openai/gpt-5.2", fallbacks: ["openai/gpt-5.1-codex"]})})})
  ' "$CFG" > "$TMP"
fi
sudo install -m 644 "$TMP" "$CFG"
sudo chown 1000:1000 "$CFG"

if sudo docker restart "$CID" >/dev/null 2>&1; then
  echo "MODEL_ENFORCE=ok"
else
  echo "MODEL_ENFORCE=failed"
  exit 1
fi

echo "MODEL_STATUS=$(sudo jq -r '.agents.defaults.model.primary // ""' "$CFG")"
echo "DM_POLICY_STATUS=$(sudo jq -r '.channels.slack.dmPolicy // ""' "$CFG")"
echo "ALLOW_FROM_STATUS=$(sudo jq -c '.channels.slack.allowFrom // []' "$CFG")"
REMOTE
)"
ssh "${SSH_OPTS[@]}" "ubuntu@${INSTANCE_IP}" "bash -s" <<<"$MODEL_ENFORCE_SCRIPT"

echo "--- OpenAI key auth check ---"
OPENAI_CHECK_SCRIPT="$(cat <<'REMOTE'
set -e
OPENAI_KEY="$(sudo grep -E '^OPENAI_API_KEY=' /opt/paige/.env | tail -n1 | cut -d= -f2-)"
if [[ -z "$OPENAI_KEY" ]]; then
  echo "OPENAI_AUTH=missing_key"
  exit 1
fi
RESULT="$(curl -sS --connect-timeout 5 --max-time 20 https://api.openai.com/v1/models -H "Authorization: Bearer $OPENAI_KEY")"
if echo "$RESULT" | grep -q '"data"'; then
  echo "OPENAI_AUTH=ok"
else
  echo "OPENAI_AUTH=failed"
  echo "$RESULT"
  exit 1
fi
REMOTE
)"
openai_check_ok="no"
for _ in 1 2 3; do
  if ssh "${SSH_OPTS[@]}" "ubuntu@${INSTANCE_IP}" "bash -s" <<<"$OPENAI_CHECK_SCRIPT"; then
    openai_check_ok="yes"
    break
  fi
  sleep 5
done
if [[ "$openai_check_ok" != "yes" ]]; then
  echo "WARN: OpenAI auth check could not complete after retries (transient SSH/network issue)."
fi

echo "Done. Next test in Slack: 'hey paige, reply with gpt-5.2 online'"
