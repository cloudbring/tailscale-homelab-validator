#!/usr/bin/env bash
# Tailscale homelab validator probe.
#
# Runs from a GitHub Actions runner that has already joined the tailnet
# as an ephemeral node tagged tag:ci-validator. Performs connectivity
# and DNS checks against the homelab and reports failures via ntfy.
#
# Exits non-zero on any failed check, which fails the workflow run and
# surfaces in GitHub's UI.

set -uo pipefail

# ────────────────────────────────────────────────────────────────────
# Configuration
# ────────────────────────────────────────────────────────────────────

# Tailnet domain (DNS suffix) — visible in `tailscale status` output.
TAILNET_DOMAIN="tail095fb2.ts.net"

# Expected peers (HostName from tailscale status --json).
# An expected peer is FAIL if absent or offline > 24h.
EXPECTED_PEERS=(pox wormhole silverstone iphone-13-pro-max)

# Subnet router(s) — at least one must be advertising the LAN route.
EXPECTED_SUBNET_ROUTERS=(pox wormhole)
SUBNET_CIDR="192.168.1.0/24"

# TCP probe targets reachable via subnet routing (host:port:label).
TCP_PROBES=(
  "192.168.1.50:8006:proxmox-ui"
  "192.168.1.60:443:truenas-https"
  "192.168.1.50:53:pihole-dns-tcp"
  "192.168.1.60:18789:openclaw"
  "192.168.1.60:32400:plex"
)

# Pi-hole DNS server (must answer queries for lab.mwangi.us).
PIHOLE_IP="192.168.1.50"
PIHOLE_DNS_NAMES=("lab.mwangi.us" "cloud.lab.mwangi.us")

# Maximum age before a peer is considered stale, in seconds.
STALE_PEER_SECONDS=$((24 * 3600))

# ────────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────────

FAILURES=()

fail() {
  local check="$1"
  local detail="$2"
  echo "::error title=Probe failed (${check})::${detail}"
  FAILURES+=("${check}: ${detail}")
}

ok() {
  echo "✓ $1"
}

# ────────────────────────────────────────────────────────────────────
# Tailscale state
# ────────────────────────────────────────────────────────────────────

echo "── Capturing tailscale status..."
STATUS_JSON="$(tailscale status --json 2>/dev/null)" || {
  fail "tailscale-status" "tailscale status --json exited non-zero"
  STATUS_JSON='{}'
}

# ────────────────────────────────────────────────────────────────────
# Check 1: Peer health
# ────────────────────────────────────────────────────────────────────

echo "── Checking expected peers..."
NOW_EPOCH="$(date +%s)"
for peer in "${EXPECTED_PEERS[@]}"; do
  PEER_INFO="$(echo "$STATUS_JSON" | jq -r --arg h "$peer" '
    .Peer | to_entries[] | select(.value.HostName == $h) |
    {online: .value.Online, lastSeen: .value.LastSeen}
  ')"
  if [ -z "$PEER_INFO" ] || [ "$PEER_INFO" = "null" ]; then
    fail "peer-missing" "$peer not found in tailnet"
    continue
  fi
  ONLINE="$(echo "$PEER_INFO" | jq -r '.online')"
  LAST_SEEN="$(echo "$PEER_INFO" | jq -r '.lastSeen')"
  if [ "$ONLINE" = "true" ]; then
    ok "$peer online"
    continue
  fi
  # Offline — check whether last-seen is recent enough to tolerate.
  LAST_SEEN_EPOCH="$(date -d "$LAST_SEEN" +%s 2>/dev/null || echo 0)"
  AGE=$((NOW_EPOCH - LAST_SEEN_EPOCH))
  if [ "$LAST_SEEN_EPOCH" -eq 0 ] || [ "$AGE" -gt "$STALE_PEER_SECONDS" ]; then
    fail "peer-offline" "$peer offline since $LAST_SEEN (${AGE}s ago)"
  else
    echo "  $peer offline but recent ($((AGE / 60))m ago) — tolerated"
  fi
done

# ────────────────────────────────────────────────────────────────────
# Check 2: MagicDNS resolution
# ────────────────────────────────────────────────────────────────────

echo "── Checking MagicDNS..."
for peer in "${EXPECTED_PEERS[@]}"; do
  EXPECTED_IP="$(echo "$STATUS_JSON" | jq -r --arg h "$peer" '
    .Peer | to_entries[] | select(.value.HostName == $h) |
    .value.TailscaleIPs[0] // empty
  ')"
  [ -z "$EXPECTED_IP" ] && continue
  RESOLVED="$(getent hosts "${peer}.${TAILNET_DOMAIN}" 2>/dev/null | awk '{print $1}' | head -1)"
  if [ "$RESOLVED" = "$EXPECTED_IP" ]; then
    ok "MagicDNS ${peer}.${TAILNET_DOMAIN} → ${EXPECTED_IP}"
  else
    fail "magicdns-mismatch" "${peer}.${TAILNET_DOMAIN} resolved to '${RESOLVED:-NXDOMAIN}', expected ${EXPECTED_IP}"
  fi
done

# ────────────────────────────────────────────────────────────────────
# Check 3: Subnet route advertisement
# ────────────────────────────────────────────────────────────────────

echo "── Checking subnet route advertisement..."
ROUTERS_WITH_ROUTE=()
for router in "${EXPECTED_SUBNET_ROUTERS[@]}"; do
  HAS_ROUTE="$(echo "$STATUS_JSON" | jq -r --arg h "$router" --arg cidr "$SUBNET_CIDR" '
    .Peer | to_entries[] | select(.value.HostName == $h) |
    (.value.AllowedIPs // []) | any(. == $cidr)
  ')"
  if [ "$HAS_ROUTE" = "true" ]; then
    ok "$router advertises $SUBNET_CIDR"
    ROUTERS_WITH_ROUTE+=("$router")
  else
    echo "  $router does not currently advertise $SUBNET_CIDR (may be secondary)"
  fi
done
if [ "${#ROUTERS_WITH_ROUTE[@]}" -eq 0 ]; then
  fail "no-subnet-router" "neither ${EXPECTED_SUBNET_ROUTERS[*]} advertise $SUBNET_CIDR"
fi

# ────────────────────────────────────────────────────────────────────
# Check 4: TCP reachability via subnet route
# ────────────────────────────────────────────────────────────────────

echo "── Probing TCP services via subnet route..."
for probe in "${TCP_PROBES[@]}"; do
  IFS=':' read -r host port label <<< "$probe"
  if nc -zw5 "$host" "$port" 2>/dev/null; then
    ok "$label ($host:$port) reachable"
  else
    fail "tcp-unreachable" "$label ($host:$port) not reachable"
  fi
done

# ────────────────────────────────────────────────────────────────────
# Check 5: Pi-hole DNS via subnet route
# ────────────────────────────────────────────────────────────────────

echo "── Querying Pi-hole DNS..."
for name in "${PIHOLE_DNS_NAMES[@]}"; do
  ANSWER="$(dig "@${PIHOLE_IP}" "$name" +short +time=3 +tries=2 2>/dev/null | head -1)"
  if [ -n "$ANSWER" ]; then
    ok "Pi-hole resolves $name → $ANSWER"
  else
    fail "pihole-dns" "$name returned no answer from $PIHOLE_IP"
  fi
done

# ────────────────────────────────────────────────────────────────────
# Report
# ────────────────────────────────────────────────────────────────────

if [ "${#FAILURES[@]}" -eq 0 ]; then
  echo
  echo "✅ All checks passed."
  exit 0
fi

echo
echo "❌ ${#FAILURES[@]} check(s) failed:"
for f in "${FAILURES[@]}"; do
  echo "  - $f"
done

# ────────────────────────────────────────────────────────────────────
# ntfy notification
# ────────────────────────────────────────────────────────────────────

if [ -n "${NTFY_TOPIC:-}" ]; then
  BODY="$(printf 'Failed checks:\n'; printf -- '- %s\n' "${FAILURES[@]}")"
  RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  curl -fsS \
    -H "Title: Tailscale probe FAILED" \
    -H "Priority: high" \
    -H "Tags: warning,tailscale" \
    -H "Click: ${RUN_URL}" \
    -d "$BODY" \
    "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null \
    || echo "::warning::ntfy notification failed to send"
else
  echo "::warning::NTFY_TOPIC not set — skipping notification"
fi

exit 1
