#!/usr/bin/env bash
set -euo pipefail
APP="${APP_PROD:-app-prod}"
echo "Releases recientes:"
fly releases -a "$APP" | head -n 8
read -rp "Version a revertir (VERSION_ID): " V
fly releases revert -a "$APP" "$V"
