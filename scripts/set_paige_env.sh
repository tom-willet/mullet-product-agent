#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <instance_ip> <allowed_whatsapp_e164>"
  echo "Example: $0 203.0.113.10 +15551234567"
  exit 1
fi

INSTANCE_IP="$1"
ALLOWED_E164="$2"

ssh "ubuntu@${INSTANCE_IP}" "sudo mkdir -p /opt/paige && sudo cp -n /opt/paige/.env.example /opt/paige/.env && sudo chmod 600 /opt/paige/.env"
ssh "ubuntu@${INSTANCE_IP}" "sudo sed -i -e 's|^ALLOWED_WHATSAPP_FROM=.*|ALLOWED_WHATSAPP_FROM=whatsapp:${ALLOWED_E164}|' /opt/paige/.env"
ssh "ubuntu@${INSTANCE_IP}" "sudo systemctl restart paige-claudbot"

echo "Updated /opt/paige/.env and restarted paige-claudbot on ${INSTANCE_IP}."
