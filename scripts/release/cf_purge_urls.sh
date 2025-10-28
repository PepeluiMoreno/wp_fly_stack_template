#!/usr/bin/env bash
set -euo pipefail
: "${CF_ZONE_ID:?Falta CF_ZONE_ID}"
: "${CF_API_TOKEN:?Falta CF_API_TOKEN}"
readarray -t URLS < <( if [ $# -gt 0 ]; then printf "%s\n" "$@"; else cat -; fi   | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -E '^https?://' || true)
mapfile -t URLS < <(printf "%s\n" "${URLS[@]}" | awk '!x[$0]++')
chunk(){ arr=("$@"); payload=$(printf '%s\n' "${arr[@]}" | jq -R . | jq -s '{files: .}');
  curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/purge_cache"     -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json"     --data "$payload" | jq -e '.success == true' >/dev/null; echo "Purged ${#arr[@]} URL(s)"; }
buf=(); c=0; for u in "${URLS[@]}"; do buf+=("$u"); ((c++)); if ((c==30)); then chunk "${buf[@]}"; buf=(); c=0; fi; done
((c>0)) && chunk "${buf[@]}"; echo "OK"
