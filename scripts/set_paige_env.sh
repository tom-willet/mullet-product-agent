#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <instance_ip> <allowed_slack_user_id> [slack_team_id]"
  echo "Example: $0 203.0.113.10 U0123456789 T0123456789"
  exit 1
fi

INSTANCE_IP="$1"
ALLOWED_SLACK_USER_ID="$2"
SLACK_TEAM_ID="${3:-}"

ssh "ubuntu@${INSTANCE_IP}" "sudo mkdir -p /opt/paige && sudo cp -n /opt/paige/.env.example /opt/paige/.env && sudo chmod 600 /opt/paige/.env"
ssh "ubuntu@${INSTANCE_IP}" "sudo sed -i -e 's|^ALLOWED_SLACK_USER_ID=.*|ALLOWED_SLACK_USER_ID=${ALLOWED_SLACK_USER_ID}|' /opt/paige/.env"

if [[ -n "${SLACK_TEAM_ID}" ]]; then
  ssh "ubuntu@${INSTANCE_IP}" "sudo sed -i -e 's|^SLACK_TEAM_ID=.*|SLACK_TEAM_ID=${SLACK_TEAM_ID}|' /opt/paige/.env"
fi

ssh "ubuntu@${INSTANCE_IP}" "sudo systemctl restart paige-claudbot"

echo "Updated /opt/paige/.env and restarted paige-claudbot on ${INSTANCE_IP}."
