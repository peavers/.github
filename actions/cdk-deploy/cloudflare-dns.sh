#!/usr/bin/env bash
# Idempotent Cloudflare DNS helpers (CNAME upsert + zone lookup).
# Requires: curl, jq, and $CLOUDFLARE_API_TOKEN (Cloudflare API token with
# Zone.DNS:Edit on the target zone).
set -uo pipefail

CF_API="https://api.cloudflare.com/client/v4"

_cf_require() {
  for c in curl jq; do
    command -v "$c" >/dev/null 2>&1 || { echo "::error::$c is required but not installed on the runner"; return 1; }
  done
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "::error::CLOUDFLARE_API_TOKEN is empty (Vault fetch failed?)"; return 1; }
}

# cf_zone_id <zone-name>  ->  prints the zone id (empty if not found)
cf_zone_id() {
  local zone="$1"
  curl -sf -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    "${CF_API}/zones?name=${zone}&status=active" | jq -r '.result[0].id // empty'
}

# cf_upsert_cname <zone-id> <name> <content> [proxied:true|false]
# Creates or updates a CNAME so re-runs are safe. Returns non-zero (and prints a
# ::error:: with Cloudflare's own message) if the API rejects the change — e.g. a
# conflicting record already exists at the name (an A record at the apex). We
# check the API's `success` field rather than just curl's exit code so a 200-with-
# errors response can't masquerade as success.
cf_upsert_cname() {
  local zone_id="$1" name="${2%.}" content="${3%.}" proxied="${4:-false}"
  local existing body resp
  existing=$(curl -s -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    "${CF_API}/zones/${zone_id}/dns_records?type=CNAME&name=${name}" \
    | jq -r '.result[0].id // empty')
  body=$(jq -nc --arg n "$name" --arg c "$content" --argjson p "$proxied" \
    '{type:"CNAME",name:$n,content:$c,proxied:$p,ttl:1}')
  if [ -n "$existing" ]; then
    resp=$(curl -s -X PUT -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      "${CF_API}/zones/${zone_id}/dns_records/${existing}" --data "$body")
  else
    resp=$(curl -s -X POST -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      "${CF_API}/zones/${zone_id}/dns_records" --data "$body")
  fi
  if [ "$(printf '%s' "$resp" | jq -r '.success // false')" = "true" ]; then
    echo "cloudflare: upserted CNAME ${name} -> ${content} (proxied=${proxied})"
  else
    echo "::error::Cloudflare rejected CNAME ${name} -> ${content}: $(printf '%s' "$resp" | jq -c '.errors // .')" >&2
    return 1
  fi
}
