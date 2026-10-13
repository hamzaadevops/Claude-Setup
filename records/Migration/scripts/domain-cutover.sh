#!/usr/bin/env bash
# Domain cutover automation for the Dealerships (dealerpulse-*) AWS infra.
#
# Walks through the exact manual playbook already proven on surfcitynissan.com /
# coronanissan.com: nginx vhost (shared long-lived self-signed origin cert) -> ACM
# cert request+validate -> backend CORS/ALLOWED_HOSTS -> attach cert to the ALB.
#
# Usage:
#   ./domain-cutover.sh <apex-domain> <local-port>
#
# Example:
#   ./domain-cutover.sh coronanissan.com 3002
#
# Requires: aws CLI configured (aws login already run), bash, base64.
# Safe to re-run: every step checks current state first and skips what's already done.

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <apex-domain> <local-port>" >&2
  echo "Example: $0 coronanissan.com 3002" >&2
  exit 1
fi

DOMAIN="$1"
WWW_DOMAIN="www.${DOMAIN}"
PORT="$2"

# --- Project constants -------------------------------------------------------
NODE_A=i-061291ea974c4ea1b
NODE_B=i-0c982c44f93bfbc0a
INTEGRATIONS_VM=i-03efb82c808863f84
REGION=us-west-2
LISTENER_ARN="arn:aws:elasticloadbalancing:us-west-2:409289617504:listener/app/dealerpulse-alb/dc80177beaa3aa2f/4752820ee903f2ee"
OCEAN_ENV=/opt/dealerpulse/backend/ocean/.env
CHATBACK_ENV=/opt/dealerpulse/chat/chat_back/.env
NGINX_VHOST_PATH="/etc/nginx/sites-enabled/${DOMAIN}"
# Shared long-lived self-signed cert already used by every vhost on this ALB --
# safe because the ALB<->nginx leg is already locked down to SG-to-SG traffic
# and neither the ALB nor Cloudflare's "Full" SSL mode validate this cert's
# hostname/trust chain. See MIGRATION_HISTORY.md 2026-09-07/08 for the full
# reasoning. Do not generate a new cert here -- reuse the existing one.
SELFSIGNED_CRT=/etc/nginx/selfsigned-test/phn-test.crt
SELFSIGNED_KEY=/etc/nginx/selfsigned-test/phn-test.key

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

log()  { echo "[cutover][$DOMAIN] $*"; }
step() { echo; echo "=== $* ==="; }

ssm_run() {
  # ssm_run <instance-id...> -- runs the given shell commands (array passed as
  # remaining args, one per line) and prints stdout/stderr per instance.
  local ids="$1"; shift
  local params="$SCRATCH/ssm_params.json"
  # No reliable jq/python3 on this machine (python3 resolves to a non-functional
  # Windows Store alias stub) -- escape for JSON by hand instead. Each command
  # here is always a single line with no embedded newlines, so this is safe.
  { echo '{"commands":['; local first=1; for c in "$@"; do
      [ $first -eq 1 ] && first=0 || echo ','
      printf '%s' "$c" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "\"%s\"", $0}'
    done; echo ']}'; } > "$params"

  local cmd_id
  cmd_id=$(aws ssm send-command --instance-ids $ids --document-name AWS-RunShellScript \
    --parameters "file://$params" --query "Command.CommandId" --output text)
  sleep 15
  for id in $ids; do
    echo "--- $id ---"
    aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" \
      --query "{Status:Status,Out:StandardOutputContent,Err:StandardErrorContent}" --output json
  done
}

# ============================================================================
step "Phase 1/5: nginx vhost (Node A + Node B), proxy_pass -> 127.0.0.1:${PORT}"
# ============================================================================

cat > "$SCRATCH/vhost.conf" <<EOF
server {
    server_name ${WWW_DOMAIN} ${DOMAIN};

    limit_req zone=api burst=150 nodelay;
    limit_conn conn 300;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: https:; media-src 'self' https://dealerpulse-media-409289617504.s3.us-west-2.amazonaws.com; font-src 'self' data: https:; connect-src 'self' https: wss:; frame-src 'self' https:; frame-ancestors 'self'; report-uri https://api.callingyounow.us/api/csp-report/;" always;

    location ~ /\.(?!well-known) {
        deny all;
        return 404;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?|ttf|eot|webp|avif)\$ {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache static_cache;
        proxy_cache_valid 200 60m;
        proxy_cache_use_stale error timeout updating;
        add_header X-Cache-Status \$upstream_cache_status;
        add_header Cache-Control "public, max-age=2592000";
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https:; style-src 'self' 'unsafe-inline' https:; img-src 'self' data: https:; media-src 'self' https://dealerpulse-media-409289617504.s3.us-west-2.amazonaws.com; font-src 'self' data: https:; connect-src 'self' https: wss:; frame-src 'self' https:; frame-ancestors 'self'; report-uri https://api.callingyounow.us/api/csp-report/;" always;
    }

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    listen [::]:443 ssl http2;
    listen 443 ssl http2;
    ssl_certificate ${SELFSIGNED_CRT};
    ssl_certificate_key ${SELFSIGNED_KEY};
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
}
server {
    if (\$host = ${WWW_DOMAIN}) {
        return 301 https://\$host\$request_uri;
    }
    if (\$host = ${DOMAIN}) {
        return 301 https://\$host\$request_uri;
    }

    listen 80;
    listen [::]:80;
    server_name ${WWW_DOMAIN} ${DOMAIN};
    return 404;
}
EOF

B64=$(base64 -w0 "$SCRATCH/vhost.conf")
ssm_run "$NODE_A $NODE_B" \
  "echo '${B64}' | base64 -d > ${NGINX_VHOST_PATH}" \
  "nginx -t && echo NGINX_TEST_OK" \
  "systemctl reload nginx && echo NGINX_RELOADED" \
  "curl -s -o /dev/null -w 'SNI_TEST:%{http_code}\n' --resolve ${DOMAIN}:443:127.0.0.1 https://${DOMAIN}/ -k" \
  "curl -s -o /dev/null -w 'WWW_SNI_TEST:%{http_code}\n' --resolve ${WWW_DOMAIN}:443:127.0.0.1 https://${WWW_DOMAIN}/ -k"

log "Check above: both nodes should show NGINX_TEST_OK, NGINX_RELOADED, and SNI_TEST/WWW_SNI_TEST as 200 (or 502 if the ${PORT} container isn't deployed yet -- that's fine, it proves routing works)."
read -rp "Press Enter to continue to Phase 2 (ACM), or Ctrl+C to stop here: " _

# ============================================================================
step "Phase 2/5: request ACM certificate (${DOMAIN} + ${WWW_DOMAIN})"
# ============================================================================

EXISTING_ARN=$(aws acm list-certificates --region "$REGION" \
  --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" --output text)

if [ -n "$EXISTING_ARN" ] && [ "$EXISTING_ARN" != "None" ]; then
  log "Certificate for ${DOMAIN} already exists: $EXISTING_ARN -- reusing it."
  CERT_ARN="$EXISTING_ARN"
else
  CERT_ARN=$(aws acm request-certificate --region "$REGION" \
    --domain-name "$DOMAIN" --subject-alternative-names "$WWW_DOMAIN" \
    --validation-method DNS --query "CertificateArn" --output text)
  log "Requested: $CERT_ARN"
  sleep 5
fi

echo
echo "Add these CNAME records in DNS (DNS-only / grey cloud, NOT proxied):"
echo
aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$REGION" \
  --query "Certificate.DomainValidationOptions[].{Domain:DomainName,Name:ResourceRecord.Name,Type:ResourceRecord.Type,Value:ResourceRecord.Value}" \
  --output table

CONFIRM=""
while [ "$CONFIRM" != "yes" ]; do
  read -rp "Added both CNAME records? Type 'yes' to continue: " CONFIRM
done

# ============================================================================
step "Phase 3/5: waiting for ACM validation (polling every 20s, up to 30 min)"
# ============================================================================

for i in $(seq 1 90); do
  STATUS=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$REGION" \
    --query "Certificate.Status" --output text)
  echo "poll $i: $STATUS"
  [ "$STATUS" = "ISSUED" ] && break
  sleep 20
done

if [ "$STATUS" != "ISSUED" ]; then
  echo "Still not ISSUED after 30 min ($STATUS). Check the CNAME records, then re-run this script --" >&2
  echo "it will detect the existing certificate and skip straight back to this wait." >&2
  exit 1
fi
log "Certificate ISSUED: $CERT_ARN"

# ============================================================================
step "Phase 4/5: backend CORS / ALLOWED_HOSTS (ocean + chat_back)"
# ============================================================================

ssm_run "$NODE_A $NODE_B" \
  "F=${OCEAN_ENV}; cp \$F \$F.bak-before-${DOMAIN}-\$(date +%Y%m%d%H%M%S)" \
  "grep -q '${DOMAIN}' ${OCEAN_ENV} && echo 'ALREADY_PRESENT_SKIPPING' || sed -i 's/^ALLOWED_HOSTS=.*/&,${DOMAIN},${WWW_DOMAIN}/' ${OCEAN_ENV}" \
  "grep -q 'https://${DOMAIN}' ${OCEAN_ENV} && echo 'ALREADY_PRESENT_SKIPPING' || sed -i 's/^CORS_ALLOWED_ORIGINS=.*/&,https:\/\/${DOMAIN},https:\/\/${WWW_DOMAIN}/' ${OCEAN_ENV}" \
  "grep -E '^ALLOWED_HOSTS|^CORS_ALLOWED_ORIGINS' ${OCEAN_ENV}" \
  "cd /opt/dealerpulse/backend/ocean && docker compose -f docker-compose.yml --project-directory /opt/dealerpulse/backend/ocean up -d --no-deps web worker beat" \
  "sleep 15 && curl -s -o /dev/null -w 'OCEAN_HEALTH:%{http_code}\n' http://127.0.0.1:9000/api/"

ssm_run "$INTEGRATIONS_VM" \
  "F=${CHATBACK_ENV}; cp \$F \$F.bak-before-${DOMAIN}-\$(date +%Y%m%d%H%M%S)" \
  "grep -q 'https://${DOMAIN}' ${CHATBACK_ENV} && echo 'ALREADY_PRESENT_SKIPPING' || sed -i 's/^CORS_ALLOWED_ORIGINS=.*/&,https:\/\/${DOMAIN},https:\/\/${WWW_DOMAIN}/' ${CHATBACK_ENV}" \
  "grep -n '^CORS_ALLOWED_ORIGINS' ${CHATBACK_ENV}" \
  "cd /opt/dealerpulse/chat/chat_back && docker compose up -d --no-deps web" \
  "sleep 15 && curl -s -o /dev/null -w 'CHATBACK_HEALTH:%{http_code}\n' http://127.0.0.1:9002/health"

log "Backend CORS/ALLOWED_HOSTS updated on both ocean nodes + chat_back. Verify HEALTH lines above are 200/428."
read -rp "Press Enter to continue to Phase 5 (attach cert to ALB), or Ctrl+C to stop here: " _

# ============================================================================
step "Phase 5/5: attach certificate to the ALB listener"
# ============================================================================

ALREADY=$(aws elbv2 describe-listener-certificates --listener-arn "$LISTENER_ARN" \
  --query "Certificates[?CertificateArn=='${CERT_ARN}'] | [0].CertificateArn" --output text)

if [ "$ALREADY" = "$CERT_ARN" ]; then
  log "Already attached to the listener -- skipping."
else
  aws elbv2 add-listener-certificates --listener-arn "$LISTENER_ARN" \
    --certificates CertificateArn="$CERT_ARN" >/dev/null
  log "Attached."
fi

ALB_DNS=$(aws elbv2 describe-load-balancers --names dealerpulse-alb \
  --query "LoadBalancers[0].DNSName" --output text)

echo
echo "############################################################"
echo "DONE. Give this to whoever controls ${DOMAIN}'s DNS:"
echo
echo "  Point ${DOMAIN} and ${WWW_DOMAIN} at:"
echo "    ${ALB_DNS}"
echo "  (as a CNAME, or Cloudflare's orange-cloud 'CNAME flattening' if it's the apex)"
echo
echo "  Requirements on their end:"
echo "    - Proxied through Cloudflare (orange cloud), not DNS-only"
echo "    - SSL/TLS mode set to 'Full' (not 'Flexible', not 'Full strict')"
echo "############################################################"
