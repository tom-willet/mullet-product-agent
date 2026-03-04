#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-mullet-dev}"
AWS_REGION="${AWS_REGION:-us-west-2}"
INSTANCE_NAME="${INSTANCE_NAME:-mullet-product-agent-prod-instance}"
INSTANCE_IP="${INSTANCE_IP:-}"
TIMER_ONCALENDAR="${TIMER_ONCALENDAR:-daily}"

TMPDIR_PATH="$(mktemp -d /tmp/paige-usage-timer.XXXXXX)"
ACCESS_JSON="$TMPDIR_PATH/access.json"
SSH_KEY_FILE="$TMPDIR_PATH/lightsail.key"
SSH_CERT_FILE="$TMPDIR_PATH/lightsail.key-cert.pub"
KNOWN_HOSTS_FILE="$TMPDIR_PATH/known_hosts"
REMOTE_SETUP_SCRIPT="$TMPDIR_PATH/install-paige-usage-timer.remote.sh"

cleanup() {
  rm -rf "$TMPDIR_PATH"
}
trap cleanup EXIT

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

require_cmd aws
require_cmd jq
require_cmd ssh
require_cmd scp

echo "Installing VPS usage timer on instance=$INSTANCE_NAME region=$AWS_REGION profile=$AWS_PROFILE"

aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail get-instance \
  --instance-name "$INSTANCE_NAME" --output json >"$ACCESS_JSON"

PUBLIC_IP="$(jq -r '.instance.publicIpAddress // empty' "$ACCESS_JSON")"
if [[ -z "$INSTANCE_IP" ]]; then
  INSTANCE_IP="$PUBLIC_IP"
fi

if [[ -z "$INSTANCE_IP" ]]; then
  echo "ERROR: could not determine instance IP"
  exit 1
fi

AWS_PAGER='' aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail get-instance-access-details \
  --instance-name "$INSTANCE_NAME" --protocol ssh --output json >"$ACCESS_JSON"

jq -r '.accessDetails.privateKey' "$ACCESS_JSON" >"$SSH_KEY_FILE"
jq -r '.accessDetails.certKey' "$ACCESS_JSON" >"$SSH_CERT_FILE"
chmod 600 "$SSH_KEY_FILE" "$SSH_CERT_FILE"

cat >"$REMOTE_SETUP_SCRIPT" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

TIMER_ONCALENDAR="${TIMER_ONCALENDAR:-daily}"

sudo install -d -m 755 /opt/paige /opt/paige/logs

# Local in-guest usage collector (no AWS API dependency).
sudo tee /usr/local/bin/paige-vps-usage-report.sh >/dev/null <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
hostname_val="$(hostname)"

MEM_TOTAL_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
MEM_USED_PCT="$(awk -v t="$MEM_TOTAL_KB" -v a="$MEM_AVAIL_KB" 'BEGIN { if (t > 0) printf "%.2f", ((t - a) / t) * 100; else print "0" }')"
ROOT_DISK_USED_PCT="$(df -P / | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"

LOAD_1M="$(awk '{print $1}' /proc/loadavg)"
LOAD_5M="$(awk '{print $2}' /proc/loadavg)"

CID="$(sudo docker ps -q --filter name=openclaw-gateway | head -n1 || true)"
if [[ -n "$CID" ]]; then
  CONTAINER_MEM="$(sudo docker stats --no-stream --format '{{.MemUsage}}' "$CID" | head -n1)"
  CONTAINER_CPU="$(sudo docker stats --no-stream --format '{{.CPUPerc}}' "$CID" | head -n1)"
else
  CONTAINER_MEM="not-running"
  CONTAINER_CPU="not-running"
fi

printf 'ts=%s host=%s mem_used_pct=%s root_disk_used_pct=%s load1=%s load5=%s container_mem=%s container_cpu=%s\n' \
  "$timestamp" "$hostname_val" "$MEM_USED_PCT" "$ROOT_DISK_USED_PCT" "$LOAD_1M" "$LOAD_5M" "$CONTAINER_MEM" "$CONTAINER_CPU"
SCRIPT
sudo chmod 755 /usr/local/bin/paige-vps-usage-report.sh

sudo tee /etc/systemd/system/paige-vps-usage.service >/dev/null <<'UNIT'
[Unit]
Description=Paige VPS usage snapshot
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc '/usr/local/bin/paige-vps-usage-report.sh | tee -a /opt/paige/logs/vps-usage.log'
UNIT

sudo tee /etc/systemd/system/paige-vps-usage.timer >/dev/null <<UNIT
[Unit]
Description=Run Paige VPS usage snapshot daily

[Timer]
OnCalendar=${TIMER_ONCALENDAR}
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now paige-vps-usage.timer
sudo systemctl start paige-vps-usage.service

echo "timer_status=$(sudo systemctl is-active paige-vps-usage.timer)"
echo "next_run=$(systemctl list-timers paige-vps-usage.timer --no-legend | awk '{print $1" "$2" "$3" "$4}')"
echo "last_log_line=$(sudo tail -n 1 /opt/paige/logs/vps-usage.log 2>/dev/null || true)"
REMOTE

chmod 700 "$REMOTE_SETUP_SCRIPT"

scp \
  -o BatchMode=yes \
  -o ConnectTimeout=20 \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
  -i "$SSH_KEY_FILE" \
  "$REMOTE_SETUP_SCRIPT" \
  "ubuntu@${INSTANCE_IP}:/tmp/install-paige-usage-timer.remote.sh" >/dev/null

ssh \
  -o BatchMode=yes \
  -o ConnectTimeout=20 \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
  -i "$SSH_KEY_FILE" \
  "ubuntu@${INSTANCE_IP}" \
  "TIMER_ONCALENDAR='${TIMER_ONCALENDAR}' bash /tmp/install-paige-usage-timer.remote.sh"

echo "Done. Timer installed with OnCalendar=${TIMER_ONCALENDAR}."
