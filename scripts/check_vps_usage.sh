#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-mullet-dev}"
AWS_REGION="${AWS_REGION:-us-west-2}"
INSTANCE_NAME="${INSTANCE_NAME:-mullet-product-agent-prod-instance}"
INSTANCE_IP="${INSTANCE_IP:-}"
HOURS="${HOURS:-24}"

# Heuristic thresholds (override with env vars when needed).
WARN_CPU_AVG_PCT="${WARN_CPU_AVG_PCT:-70}"
WARN_CPU_PEAK_PCT="${WARN_CPU_PEAK_PCT:-90}"
WARN_MEM_USED_PCT="${WARN_MEM_USED_PCT:-85}"
WARN_DISK_USED_PCT="${WARN_DISK_USED_PCT:-85}"

LOW_CPU_AVG_PCT="${LOW_CPU_AVG_PCT:-5}"
LOW_CPU_PEAK_PCT="${LOW_CPU_PEAK_PCT:-35}"
LOW_MEM_USED_PCT="${LOW_MEM_USED_PCT:-45}"
LOW_DISK_USED_PCT="${LOW_DISK_USED_PCT:-35}"

TMPDIR_PATH="$(mktemp -d /tmp/paige-usage.XXXXXX)"
ACCESS_JSON="$TMPDIR_PATH/access.json"
SSH_KEY_FILE="$TMPDIR_PATH/lightsail.key"
SSH_CERT_FILE="$TMPDIR_PATH/lightsail.key-cert.pub"
KNOWN_HOSTS_FILE="$TMPDIR_PATH/known_hosts"
CPU_JSON="$TMPDIR_PATH/cpu.json"

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

float_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 >= b + 0) ? 0 : 1 }'
}

float_le() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 <= b + 0) ? 0 : 1 }'
}

echo "== VPS Usage Report =="
echo "profile=$AWS_PROFILE region=$AWS_REGION instance=$INSTANCE_NAME hours=$HOURS"

aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail get-instance \
  --instance-name "$INSTANCE_NAME" --output json >"$ACCESS_JSON"

INSTANCE_STATE="$(jq -r '.instance.state.name' "$ACCESS_JSON")"
BUNDLE_ID="$(jq -r '.instance.bundleId' "$ACCESS_JSON")"
BLUEPRINT="$(jq -r '.instance.blueprintId' "$ACCESS_JSON")"
PUBLIC_IP="$(jq -r '.instance.publicIpAddress // empty' "$ACCESS_JSON")"

if [[ -z "$INSTANCE_IP" ]]; then
  INSTANCE_IP="$PUBLIC_IP"
fi

echo ""
echo "-- Instance --"
echo "state=$INSTANCE_STATE bundle=$BUNDLE_ID blueprint=$BLUEPRINT public_ip=$PUBLIC_IP"

aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail get-bundles \
  --include-inactive --output json | jq -r --arg b "$BUNDLE_ID" '
  .bundles[] | select(.bundleId == $b)
  | "plan_ram_gb=\(.ramSizeInGb) plan_disk_gb=\(.diskSizeInGb) transfer_gb_month=\(.transferPerMonthInGb) plan_price_usd=\(.price)"
'

START_TIME="$(date -u -v-"${HOURS}"H '+%Y-%m-%dT%H:%M:%SZ')"
END_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail get-instance-metric-data \
  --instance-name "$INSTANCE_NAME" \
  --metric-name CPUUtilization \
  --period 300 \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --unit Percent \
  --statistics Maximum Average \
  --output json >"$CPU_JSON"

echo ""
echo "-- CPU (${HOURS}h) --"
CPU_AVG="$(jq -r '[.metricData[]?.average] | if length > 0 then (add / length) else -1 end' "$CPU_JSON")"
CPU_PEAK="$(jq -r '[.metricData[]?.maximum] | if length > 0 then max else -1 end' "$CPU_JSON")"
if [[ "$CPU_AVG" != "-1" ]]; then
  printf 'cpu_avg_%.0fh=%.2f%%\n' "$HOURS" "$CPU_AVG"
else
  echo "cpu_avg_${HOURS}h=n/a"
fi
if [[ "$CPU_PEAK" != "-1" ]]; then
  printf 'cpu_peak_%.0fh=%.2f%%\n' "$HOURS" "$CPU_PEAK"
else
  echo "cpu_peak_${HOURS}h=n/a"
fi

if [[ -z "$INSTANCE_IP" ]]; then
  echo ""
  echo "WARN: No instance IP found; skipping in-guest checks."
  exit 0
fi

AWS_PAGER='' aws --profile "$AWS_PROFILE" --region "$AWS_REGION" lightsail get-instance-access-details \
  --instance-name "$INSTANCE_NAME" --protocol ssh --output json >"$ACCESS_JSON"

jq -r '.accessDetails.privateKey' "$ACCESS_JSON" >"$SSH_KEY_FILE"
jq -r '.accessDetails.certKey' "$ACCESS_JSON" >"$SSH_CERT_FILE"
chmod 600 "$SSH_KEY_FILE" "$SSH_CERT_FILE"

echo ""
echo "-- In-Guest Usage --"
REMOTE_REPORT="$(ssh -o BatchMode=yes \
  -o ConnectTimeout=20 \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
  -i "$SSH_KEY_FILE" \
  "ubuntu@${INSTANCE_IP}" '
set -e

echo "host=$(hostname)"
echo ""
echo "[memory]"
free -h

echo ""
echo "[disk]"
df -h / /opt/paige

echo ""
echo "[docker]"
sudo docker system df || true

echo ""
echo "[top memory processes]"
ps -eo pid,comm,%mem,%cpu,rss --sort=-%mem | head -n 8

echo ""
echo "[openclaw container]"
CID="$(sudo docker ps -q --filter name=openclaw-gateway | head -n1)"
if [[ -n "$CID" ]]; then
  sudo docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}" "$CID"
else
  echo "openclaw-gateway not running"
fi

echo ""
echo "[metrics_raw]"
MEM_TOTAL_KB="$(awk "/MemTotal:/ {print \$2}" /proc/meminfo)"
MEM_AVAIL_KB="$(awk "/MemAvailable:/ {print \$2}" /proc/meminfo)"
MEM_USED_PCT="$(awk -v t="$MEM_TOTAL_KB" -v a="$MEM_AVAIL_KB" "BEGIN { if (t > 0) printf \"%.2f\", ((t - a) / t) * 100; else print \"0\" }")"
ROOT_DISK_PCT="$(df -P / | awk "NR==2 {gsub(/%/, \"\", \$5); print \$5}")"
echo "METRIC_MEM_USED_PCT=$MEM_USED_PCT"
echo "METRIC_ROOT_DISK_USED_PCT=$ROOT_DISK_PCT"
'
 )"

echo "$REMOTE_REPORT"

MEM_USED_PCT="$(printf '%s\n' "$REMOTE_REPORT" | awk -F= '/^METRIC_MEM_USED_PCT=/{print $2}' | tail -n1)"
ROOT_DISK_USED_PCT="$(printf '%s\n' "$REMOTE_REPORT" | awk -F= '/^METRIC_ROOT_DISK_USED_PCT=/{print $2}' | tail -n1)"

if [[ -z "$MEM_USED_PCT" || -z "$ROOT_DISK_USED_PCT" ]]; then
  echo ""
  echo "-- Verdict --"
  echo "verdict=unknown"
  echo "reason=missing metrics from remote host"
  exit 0
fi

echo ""
echo "-- Verdict --"
printf 'memory_used_pct=%s%% disk_used_pct=%s%%\n' "$MEM_USED_PCT" "$ROOT_DISK_USED_PCT"

REASONS=()
VERDICT="right_sized"

if float_ge "$CPU_AVG" "$WARN_CPU_AVG_PCT"; then
  REASONS+=("cpu_avg_high")
fi
if float_ge "$CPU_PEAK" "$WARN_CPU_PEAK_PCT"; then
  REASONS+=("cpu_peak_high")
fi
if float_ge "$MEM_USED_PCT" "$WARN_MEM_USED_PCT"; then
  REASONS+=("memory_high")
fi
if float_ge "$ROOT_DISK_USED_PCT" "$WARN_DISK_USED_PCT"; then
  REASONS+=("disk_high")
fi

if [[ ${#REASONS[@]} -gt 0 ]]; then
  VERDICT="upgrade_or_tune"
else
  if float_le "$CPU_AVG" "$LOW_CPU_AVG_PCT" \
    && float_le "$CPU_PEAK" "$LOW_CPU_PEAK_PCT" \
    && float_le "$MEM_USED_PCT" "$LOW_MEM_USED_PCT" \
    && float_le "$ROOT_DISK_USED_PCT" "$LOW_DISK_USED_PCT"; then
    VERDICT="consider_downgrade"
    REASONS+=("consistently_low_utilization")
  fi
fi

echo "verdict=$VERDICT"
if [[ ${#REASONS[@]} -gt 0 ]]; then
  printf 'reasons=%s\n' "$(IFS=,; echo "${REASONS[*]}")"
else
  echo "reasons=within_target"
fi
