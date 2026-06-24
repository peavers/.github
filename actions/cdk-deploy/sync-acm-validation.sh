#!/usr/bin/env bash
# Runs CONCURRENTLY with `cdk deploy`. Waits for the ACM certificate for $DOMAIN
# to appear in PENDING_VALIDATION, then publishes its DNS validation CNAME to
# Cloudflare so the cert issues without any manual step. Best-effort: never fails
# the build (if the cert is already issued there's nothing to do).
#
# Usage: sync-acm-validation.sh <domain> <cloudflare-zone> [aws-region]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cloudflare-dns.sh
source "${DIR}/cloudflare-dns.sh"

DOMAIN="$1"; ZONE="$2"; REGION="${3:-us-east-1}"
_cf_require || exit 0

ZID=$(cf_zone_id "$ZONE")
[ -n "$ZID" ] || { echo "::warning::cloudflare zone '${ZONE}' not found; skipping ACM validation sync"; exit 0; }

echo "cloudflare: watching ACM for a pending validation record for ${DOMAIN}…"
for _ in $(seq 1 60); do
  arn=$(aws acm list-certificates --region "$REGION" \
        --certificate-statuses PENDING_VALIDATION \
        --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" \
        --output text 2>/dev/null)
  if [ -n "$arn" ] && [ "$arn" != "None" ]; then
    name=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$arn" \
          --query "Certificate.DomainValidationOptions[0].ResourceRecord.Name" --output text 2>/dev/null)
    value=$(aws acm describe-certificate --region "$REGION" --certificate-arn "$arn" \
          --query "Certificate.DomainValidationOptions[0].ResourceRecord.Value" --output text 2>/dev/null)
    if [ -n "$name" ] && [ "$name" != "None" ] && [ -n "$value" ] && [ "$value" != "None" ]; then
      # Validation records MUST be DNS-only (grey) so ACM can resolve them.
      cf_upsert_cname "$ZID" "$name" "$value" false
      echo "cloudflare: ACM validation record published for ${DOMAIN}"
      exit 0
    fi
  fi
  sleep 10
done
echo "cloudflare: no pending ACM validation record for ${DOMAIN} within timeout (cert likely already issued)"
exit 0
