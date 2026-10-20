#!/bin/bash
#
# Provision Cloudflare Tunnel + DNS + Access for the home server.
# Idempotent: safe to re-run. Writes TUNNEL_TOKEN into ../.env
#
# Requires: wrangler, curl, jq and CLOUDFLARE_API_TOKEN with:
#   Account > Cloudflare Tunnel: Edit
#   Account > Access: Apps and Policies: Edit
#   Account > Access: Organizations, Identity Providers, and Groups: Edit
#   Account > Account Settings: Read
#   Zone    > DNS: Edit, Zone: Read   (for the domain below)
#
set -euo pipefail

DOMAIN="${DOMAIN:-berkslv.com}"
SSH_HOST="${SSH_HOST:-ssh.$DOMAIN}"
TUNNEL_NAME="${TUNNEL_NAME:-home-server}"
ACCESS_EMAILS="${ACCESS_EMAILS:?ACCESS_EMAILS is required (comma separated)}"
SESSION_DURATION="${SESSION_DURATION:-24h}"
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
export CLOUDFLARE_API_TOKEN

API="https://api.cloudflare.com/client/v4"

cf() {
    local method="$1" path="$2" body="${3:-}"
    local resp
    resp=$(curl -sS -X "$method" "$API$path" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" \
        ${body:+--data "$body"})
    if [ "$(jq -r '.success' <<<"$resp")" != "true" ]; then
        echo "Cloudflare API error on $method $path:" >&2
        jq '.errors' <<<"$resp" >&2
        return 1
    fi
    echo "$resp"
}

log() { echo -e "\033[0;34m[INFO]\033[0m $*" >&2; }

# Zone and account
ZONE=$(cf GET "/zones?name=$DOMAIN" | jq -r '.result[0]')
ZONE_ID=$(jq -r '.id' <<<"$ZONE")
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-$(jq -r '.account.id' <<<"$ZONE")}"
export CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID"
[ "$ZONE_ID" != "null" ] || { echo "Zone $DOMAIN not found" >&2; exit 1; }
log "Zone $DOMAIN ($ZONE_ID), account $ACCOUNT_ID"

# Tunnel (created with wrangler)
TUNNEL_ID=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" | jq -r '.result[0].id // empty')
if [ -z "$TUNNEL_ID" ]; then
    log "Creating tunnel $TUNNEL_NAME with wrangler"
    wrangler tunnel create "$TUNNEL_NAME"
    TUNNEL_ID=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" | jq -r '.result[0].id')
else
    log "Tunnel $TUNNEL_NAME exists"
fi
log "Tunnel id $TUNNEL_ID"
wrangler tunnel info "$TUNNEL_ID" >&2 || true

# Remotely-managed ingress: ssh host -> agent container
cf PUT "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" "$(jq -nc --arg h "$SSH_HOST" '{
    config: { ingress: [
        { hostname: $h, service: "ssh://agent:22" },
        { service: "http_status:404" }
    ] }
}')" >/dev/null
log "Ingress: $SSH_HOST -> ssh://agent:22"

# DNS CNAME
DNS_BODY=$(jq -nc --arg n "$SSH_HOST" --arg c "$TUNNEL_ID.cfargotunnel.com" \
    '{type: "CNAME", name: $n, content: $c, proxied: true, comment: "home-server tunnel"}')
RECORD_ID=$(cf GET "/zones/$ZONE_ID/dns_records?name=$SSH_HOST" | jq -r '.result[0].id // empty')
if [ -n "$RECORD_ID" ]; then
    cf PUT "/zones/$ZONE_ID/dns_records/$RECORD_ID" "$DNS_BODY" >/dev/null
else
    cf POST "/zones/$ZONE_ID/dns_records" "$DNS_BODY" >/dev/null
fi
log "DNS: $SSH_HOST CNAME $TUNNEL_ID.cfargotunnel.com"

# Access: make sure the One-time PIN login method exists
if ! cf GET "/accounts/$ACCOUNT_ID/access/identity_providers" | jq -e '.result[] | select(.type == "onetimepin")' >/dev/null; then
    cf POST "/accounts/$ACCOUNT_ID/access/identity_providers" '{"name":"One-time PIN","type":"onetimepin","config":{}}' >/dev/null
    log "Added One-time PIN login method"
fi

# Access: reusable allow policy for the listed emails
POLICY_NAME="$TUNNEL_NAME allow"
POLICY_BODY=$(jq -nc --arg n "$POLICY_NAME" --arg e "$ACCESS_EMAILS" --arg s "$SESSION_DURATION" '{
    name: $n, decision: "allow", session_duration: $s,
    include: ($e | split(",") | map({ email: { email: (. | gsub("\\s"; "")) } }))
}')
POLICY_ID=$(cf GET "/accounts/$ACCOUNT_ID/access/policies" | jq -r --arg n "$POLICY_NAME" '.result[] | select(.name == $n) | .id' | head -1)
if [ -n "$POLICY_ID" ]; then
    cf PUT "/accounts/$ACCOUNT_ID/access/policies/$POLICY_ID" "$POLICY_BODY" >/dev/null
else
    POLICY_ID=$(cf POST "/accounts/$ACCOUNT_ID/access/policies" "$POLICY_BODY" | jq -r '.result.id')
fi
log "Access policy $POLICY_ID allows: $ACCESS_EMAILS"

# Access: application for the ssh host (type "ssh" also enables browser-rendered terminal)
APP_BODY=$(jq -nc --arg h "$SSH_HOST" --arg p "$POLICY_ID" --arg s "$SESSION_DURATION" '{
    name: "Agent SSH", domain: $h, type: "ssh", session_duration: $s,
    app_launcher_visible: true,
    policies: [ { id: $p, precedence: 1 } ]
}')
APP_ID=$(cf GET "/accounts/$ACCOUNT_ID/access/apps" | jq -r --arg h "$SSH_HOST" '.result[] | select(.domain == $h) | .id' | head -1)
if [ -n "$APP_ID" ]; then
    cf PUT "/accounts/$ACCOUNT_ID/access/apps/$APP_ID" "$APP_BODY" >/dev/null
else
    APP_ID=$(cf POST "/accounts/$ACCOUNT_ID/access/apps" "$APP_BODY" | jq -r '.result.id')
fi
log "Access app $APP_ID protects $SSH_HOST"

# Connector token -> .env
TUNNEL_TOKEN=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | jq -r '.result')
touch "$ENV_FILE" && chmod 600 "$ENV_FILE"
grep -v '^TUNNEL_TOKEN=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
echo "TUNNEL_TOKEN=$TUNNEL_TOKEN" >> "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
log "Wrote TUNNEL_TOKEN to $ENV_FILE"
