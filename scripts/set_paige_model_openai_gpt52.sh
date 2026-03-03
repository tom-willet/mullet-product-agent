#!/usr/bin/env bash
set -euo pipefail

# One-shot updater: pushes OPENAI_API_KEY to server env, sets model to openai/gpt-5.2,
# restarts Paige, and prints health/status checks.

AWS_PROFILE="${AWS_PROFILE:-mullet-dev}"
AWS_REGION="${AWS_REGION:-us-west-2}"
INSTANCE_NAME="${INSTANCE_NAME:-mullet-product-agent-prod-instance}"
LOCAL_ENV_FILE="${LOCAL_ENV_FILE:-.env}"
REMOTE_ENV_FILE="/opt/paige/.env"
REMOTE_CONFIG_FILE="/opt/paige/state/openclaw.json"

if [[ ! -f "$LOCAL_ENV_FILE" ]]; then
  echo "ERROR: local env file not found: $LOCAL_ENV_FILE"
  exit 1
fi

OPENAI_LINE="$(grep '^OPENAI_API_KEY=' "$LOCAL_ENV_FILE" | tail -n1 || true)"
if [[ -z "$OPENAI_LINE" ]]; then
  echo "ERROR: OPENAI_API_KEY is missing in $LOCAL_ENV_FILE"
  exit 1
fi

echo "[1/5] Fetching temporary Lightsail SSH credentials..."
AWS_PAGER='' aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail get-instance-access-details \
  --instance-name "$INSTANCE_NAME" --protocol ssh --output json > /tmp/paige-access.json
jq -r '.accessDetails.privateKey' /tmp/paige-access.json > /tmp/paige-lightsail.key
jq -r '.accessDetails.certKey' /tmp/paige-access.json > /tmp/paige-lightsail.key-cert.pub
chmod 600 /tmp/paige-lightsail.key /tmp/paige-lightsail.key-cert.pub

echo "[2/5] Preparing remote update payload..."
cat > /tmp/paige-gpt52-remote.sh <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

REMOTE_ENV_FILE="/opt/paige/.env"
REMOTE_CONFIG_FILE="/opt/paige/state/openclaw.json"
OPENAI_LINE_FILE="/tmp/openai_line.txt"

if [[ ! -f "$OPENAI_LINE_FILE" ]]; then
  echo "ERROR: missing OPENAI line payload ($OPENAI_LINE_FILE)"
  exit 1
fi
OPENAI_LINE="$(cat "$OPENAI_LINE_FILE")"

if grep -q '^OPENAI_API_KEY=' "$REMOTE_ENV_FILE"; then
  sed -i "s|^OPENAI_API_KEY=.*|$OPENAI_LINE|" "$REMOTE_ENV_FILE"
else
  echo "$OPENAI_LINE" >> "$REMOTE_ENV_FILE"
fi
chmod 600 "$REMOTE_ENV_FILE"

TMP_JSON="/tmp/openclaw.json.gpt52.tmp"
jq '
  .agents = (.agents // {}) |
  .agents.defaults = (.agents.defaults // {}) |
  .agents.defaults.model = ((.agents.defaults.model // {}) + {
    "primary": "openai/gpt-5.2",
    "fallbacks": ["openai/gpt-5.1-codex"]
  })
' "$REMOTE_CONFIG_FILE" > "$TMP_JSON"
install -m 600 "$TMP_JSON" "$REMOTE_CONFIG_FILE"

systemctl restart paige-claudbot
sleep 2

echo "SERVICE_STATE=$(systemctl is-active paige-claudbot)"
echo "MODEL_PRIMARY=$(jq -r '.agents.defaults.model.primary // ""' "$REMOTE_CONFIG_FILE")"
echo "MODEL_FALLBACKS=$(jq -c '.agents.defaults.model.fallbacks // []' "$REMOTE_CONFIG_FILE")"

CID="$(docker ps -q --filter name=openclaw-gateway | head -n1)"
echo "CONTAINER_ID=$CID"
if [[ -n "$CID" ]]; then
  docker inspect "$CID" --format 'CONTAINER_STATUS={{.State.Status}} RESTART_COUNT={{.RestartCount}}'
fi
REMOTE

# Write key line to a separate payload file to avoid cross-platform sed quirks.
printf '%s\n' "$OPENAI_LINE" > /tmp/openai_line.txt
chmod 700 /tmp/paige-gpt52-remote.sh

echo "[3/5] Copying update payload to instance..."
scp -i /tmp/paige-lightsail.key /tmp/paige-gpt52-remote.sh ubuntu@54.187.38.122:/tmp/paige-gpt52-remote.sh >/dev/null
scp -i /tmp/paige-lightsail.key /tmp/openai_line.txt ubuntu@54.187.38.122:/tmp/openai_line.txt >/dev/null

echo "[4/5] Applying model + env updates on instance..."
ssh -i /tmp/paige-lightsail.key ubuntu@54.187.38.122 'sudo bash /tmp/paige-gpt52-remote.sh'

echo "[5/5] Done."
echo "Now test in Slack DM: /model status"
echo "Then send: hey paige, reply with gpt-5.2 online"
