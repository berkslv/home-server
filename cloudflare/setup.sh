#!/bin/bash
#
# Provision Cloudflare Tunnel + DNS + Access for the home server.
# Idempotent: safe to re-run. Writes TUNNEL_TOKEN into ../.env
#
# Requires: wrangler, curl, jq and CLOUDFLARE_API_TOKEN with:
#   Account > Cloudflare Tunnel: Edit
#   Account > Access: Apps and Policies: Edit
#   Account > Access: Organizations, Identity Providers, and Groups: Edit
#   Account > Access: Service Tokens: Edit
#   Account > Account Settings: Read
#   Zone    > DNS: Edit, Zone: Read   (for the domain below)
#
set -euo pipefail

DOMAIN="${DOMAIN:-berkslv.com}"
SSH_HOST="${SSH_HOST:-ssh.$DOMAIN}"
IMMICH_HOST="${IMMICH_HOST:-immich.$DOMAIN}"
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

# Replace KEY=value in .env (created 600 if missing)
set_env() {
    touch "$ENV_FILE" && chmod 600 "$ENV_FILE"
    grep -v "^$1=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
    echo "$1=$2" >> "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
}

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

# Remotely-managed ingress (cloudflared runs on the host):
#   ssh host    -> host sshd
#   immich host -> Immich server published on the host's :2283
cf PUT "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" "$(jq -nc --arg s "$SSH_HOST" --arg i "$IMMICH_HOST" '{
    config: { ingress: [
        { hostname: $s, service: "ssh://localhost:22" },
        { hostname: $i, service: "http://localhost:2283" },
        { service: "http_status:404" }
    ] }
}')" >/dev/null
log "Ingress: $SSH_HOST -> ssh://localhost:22, $IMMICH_HOST -> http://localhost:2283"

# DNS CNAMEs
for HOST in "$SSH_HOST" "$IMMICH_HOST"; do
    DNS_BODY=$(jq -nc --arg n "$HOST" --arg c "$TUNNEL_ID.cfargotunnel.com" \
        '{type: "CNAME", name: $n, content: $c, proxied: true, comment: "home-server tunnel"}')
    RECORD_ID=$(cf GET "/zones/$ZONE_ID/dns_records?name=$HOST" | jq -r '.result[0].id // empty')
    if [ -n "$RECORD_ID" ]; then
        cf PUT "/zones/$ZONE_ID/dns_records/$RECORD_ID" "$DNS_BODY" >/dev/null
    else
        cf POST "/zones/$ZONE_ID/dns_records" "$DNS_BODY" >/dev/null
    fi
    log "DNS: $HOST CNAME $TUNNEL_ID.cfargotunnel.com"
done

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

# Access: service token for the Immich mobile app, which can't do the email login.
# The app sends it as custom proxy headers. The secret is only returned on create/rotate,
# so it's kept in .env; if it's missing there the token is rotated to get a new one.
IMMICH_TOKEN_NAME="immich-app"
IMMICH_TOKEN_ID=$(cf GET "/accounts/$ACCOUNT_ID/access/service_tokens" | jq -r --arg n "$IMMICH_TOKEN_NAME" '.result[] | select(.name == $n) | .id' | head -1)
if [ -z "$IMMICH_TOKEN_ID" ]; then
    TOKEN=$(cf POST "/accounts/$ACCOUNT_ID/access/service_tokens" "$(jq -nc --arg n "$IMMICH_TOKEN_NAME" '{name: $n, duration: "forever"}')")
elif ! grep -q '^IMMICH_ACCESS_CLIENT_SECRET=.' "$ENV_FILE" 2>/dev/null; then
    TOKEN=$(cf POST "/accounts/$ACCOUNT_ID/access/service_tokens/$IMMICH_TOKEN_ID/rotate")
fi
if [ -n "${TOKEN:-}" ]; then
    IMMICH_TOKEN_ID=$(jq -r '.result.id' <<<"$TOKEN")
    set_env IMMICH_ACCESS_CLIENT_ID "$(jq -r '.result.client_id' <<<"$TOKEN")"
    set_env IMMICH_ACCESS_CLIENT_SECRET "$(jq -r '.result.client_secret' <<<"$TOKEN")"
    log "Wrote IMMICH_ACCESS_CLIENT_ID/SECRET to $ENV_FILE"
fi

IMMICH_POLICY_NAME="$TUNNEL_NAME immich app"
IMMICH_POLICY_BODY=$(jq -nc --arg n "$IMMICH_POLICY_NAME" --arg t "$IMMICH_TOKEN_ID" '{
    name: $n, decision: "non_identity", include: [ { service_token: { token_id: $t } } ]
}')
IMMICH_POLICY_ID=$(cf GET "/accounts/$ACCOUNT_ID/access/policies" | jq -r --arg n "$IMMICH_POLICY_NAME" '.result[] | select(.name == $n) | .id' | head -1)
if [ -n "$IMMICH_POLICY_ID" ]; then
    cf PUT "/accounts/$ACCOUNT_ID/access/policies/$IMMICH_POLICY_ID" "$IMMICH_POLICY_BODY" >/dev/null
else
    IMMICH_POLICY_ID=$(cf POST "/accounts/$ACCOUNT_ID/access/policies" "$IMMICH_POLICY_BODY" | jq -r '.result.id')
fi
log "Access policy $IMMICH_POLICY_ID allows service token $IMMICH_TOKEN_NAME"

# Access: one application per hostname, each behind the email policy plus any extra policies
access_app() {
    local name="$1" host="$2" type="$3" body app_id
    shift 3
    body=$(jq -nc --arg n "$name" --arg h "$host" --arg t "$type" --arg s "$SESSION_DURATION" \
        --args '{
        name: $n, domain: $h, type: $t, session_duration: $s,
        app_launcher_visible: true,
        policies: [ $ARGS.positional | to_entries[] | { id: .value, precedence: (.key + 1) } ]
    }' "$POLICY_ID" "$@")
    app_id=$(cf GET "/accounts/$ACCOUNT_ID/access/apps" | jq -r --arg h "$host" '.result[] | select(.domain == $h) | .id' | head -1)
    if [ -n "$app_id" ]; then
        cf PUT "/accounts/$ACCOUNT_ID/access/apps/$app_id" "$body" >/dev/null
    else
        app_id=$(cf POST "/accounts/$ACCOUNT_ID/access/apps" "$body" | jq -r '.result.id')
    fi
    log "Access app $app_id protects $host"
}
# type "ssh" also enables the browser-rendered terminal
access_app "Home Server SSH" "$SSH_HOST" ssh
access_app "Immich" "$IMMICH_HOST" self_hosted "$IMMICH_POLICY_ID"

# Connector token -> .env
TUNNEL_TOKEN=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | jq -r '.result')
set_env TUNNEL_TOKEN "$TUNNEL_TOKEN"
log "Wrote TUNNEL_TOKEN to $ENV_FILE"
