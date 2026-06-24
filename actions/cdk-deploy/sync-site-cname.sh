#!/usr/bin/env bash
# Runs AFTER `cdk deploy`. Resolves the CloudFront domain (via the distribution
# id published to SSM by the stack) and upserts the site CNAME in Cloudflare so
# the hostname resolves with no manual step.
#
# Usage: sync-site-cname.sh <domain> <cloudflare-zone> <ssm-distribution-id-param> [proxied] [aws-region]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloudflare-dns.sh
source "${DIR}/cloudflare-dns.sh"

DOMAIN="$1"; ZONE="$2"; DIST_PARAM="$3"; PROXIED="${4:-false}"; REGION="${5:-us-east-1}"
_cf_require || exit 1

ZID=$(cf_zone_id "$ZONE")
[ -n "$ZID" ] || { echo "::error::cloudflare zone '${ZONE}' not found"; exit 1; }

dist_id=$(aws ssm get-parameter --name "$DIST_PARAM" --query 'Parameter.Value' --output text 2>/dev/null)
[ -n "$dist_id" ] && [ "$dist_id" != "None" ] || { echo "::error::could not read distribution id from SSM ${DIST_PARAM}"; exit 1; }

cf_domain=$(aws cloudfront get-distribution --id "$dist_id" \
  --query 'Distribution.DomainName' --output text 2>/dev/null)
[ -n "$cf_domain" ] && [ "$cf_domain" != "None" ] || { echo "::error::could not resolve CloudFront domain for ${dist_id}"; exit 1; }

# DNS-only by default: CloudFront/ACM own TLS, so no Cloudflare proxy needed.
# Fail loudly if Cloudflare rejects it (e.g. a conflicting record already exists
# at the apex) instead of silently leaving the hostname pointed at the old origin.
if ! cf_upsert_cname "$ZID" "$DOMAIN" "$cf_domain" "$PROXIED"; then
  echo "::error::Could not point ${DOMAIN} at ${cf_domain}. If this is an apex, delete the pre-existing A/CNAME record (e.g. the old hosting provider's) and re-run." >&2
  exit 1
fi
