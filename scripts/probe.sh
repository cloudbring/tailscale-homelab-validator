#!/usr/bin/env bash
# Tailscale homelab validator probe.
#
# Runs from a GitHub Actions runner that has already joined the tailnet
# as an ephemeral node tagged tag:ci-validator. Validates infrastructure
# peer health and TCP/DNS reachability via direct tailnet WireGuard mesh.
#
# v1 scope: direct tailnet IPs only. Subnet-route probes (LAN IPs like
# 192.168.1.x via subnet router) are a v2 follow-on once subnet routing
# through wormhole is debugged — see KNOWN_ISSUES.md.

set -uo pipefail

# ────────────────────────────────────────────────────────────────────
# Configuration
# ────────────────────────────────────────────────────────────────────

TAILNET_DOMAIN="tail095fb2.ts.net"

# Infrastructure peers — must be online for the homelab to be reachable.
EXPECTED_PEERS=(pox wormhole)

# Direct tailnet IP TCP probes — exercise the WireGuard mesh directly,
# bypassing subnet routing.
DIRECT_TCP_PROBES=(
  "100.82.79.26:8006:proxmox-ui-direct"
  "100.82.79.26:22:pox-ssh-direct"
  "100.96.34.98:443:wormhole-https-direct"
  "100.96.34.98:22:wormhole-ssh-direct"
)

# Subnet-route TCP probes — exercise wormhole as a subnet router into 192.168.1.0/24.
# These broke during initial dry runs because pox/silverstone's --accept-routes=true
# was hijacking return paths through tailscale0; fixed 2026-04-26 by setting
# --accept-routes=false on both LAN-resident peers.
SUBNET_TCP_PROBES=(
  "192.168.1.50:8006:proxmox-ui-via-subnet"
  "192.168.1.50:22:pox-ssh-via-subnet"
  "192.168.1.50:10022:gitea-ssh-via-subnet"
  "192.168.1.50:443:caddy-via-subnet"
  "192.168.1.60:443:truenas-via-subnet"
)

# Pi-hole DNS check — homelab DNS via subnet route.
PIHOLE_DNS="192.168.1.50"
PIHOLE_NAMES=("git.lab.mwangi.us" "kuma.lab.mwangi.us")

STALE_PEER_SECONDS=$((24 * 3600))

# ────────────────────────────────────────────────────────────────────

FAILURES=()

fail() {
  local check="$1"
  local detail="$2"
  echo "::error title=Probe failed (${check})::${detail}"
  FAILURES+=("${check}: ${detail}")
}

ok() { echo "✓ $1"; }

# ────────────────────────────────────────────────────────────────────
# Tailscale state
# ────────────────────────────────────────────────────────────────────

echo "── Capturing tailscale status..."
STATUS_JSON="$(tailscale status --json 2>/dev/null)" || {
  fail "tailscale-status" "tailscale status --json exited non-zero"
  STATUS_JSON='{}'
}

echo "── Visible tailnet peers (from validator's netmap):"
echo "$STATUS_JSON" | jq -r '.Peer | to_entries[] | "  \(.value.HostName)\t\(.value.TailscaleIPs[0] // "-")\tonline=\(.value.Online)\troutes=\(.value.AllowedIPs // [] | join(","))"' 2>/dev/null || echo "  (jq parse failed)"
echo

# ────────────────────────────────────────────────────────────────────
# Check 1: Peer health
# ────────────────────────────────────────────────────────────────────

echo "── Checking expected infrastructure peers..."
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
# Check 3: TCP reachability via direct tailnet
# ────────────────────────────────────────────────────────────────────

echo "── Probing TCP via direct tailnet IPs..."
for probe in "${DIRECT_TCP_PROBES[@]}"; do
  IFS=':' read -r host port label <<< "$probe"
  if nc -zw5 "$host" "$port" 2>/dev/null; then
    ok "$label ($host:$port) reachable"
  else
    fail "tcp-unreachable" "$label ($host:$port) not reachable"
  fi
done

# ────────────────────────────────────────────────────────────────────
# Check 4: TCP reachability via wormhole subnet route
# ────────────────────────────────────────────────────────────────────

echo "── Probing TCP via wormhole subnet route (192.168.1.0/24)..."
for probe in "${SUBNET_TCP_PROBES[@]}"; do
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

echo "── Querying Pi-hole DNS via subnet route..."
for name in "${PIHOLE_NAMES[@]}"; do
  ANSWER="$(dig "@${PIHOLE_DNS}" "$name" +short +time=3 +tries=2 2>/dev/null | head -1)"
  if [ -n "$ANSWER" ] && [[ "$ANSWER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ok "Pi-hole resolves $name → $ANSWER"
  else
    fail "pihole-dns" "$name returned no answer (or non-IP) from $PIHOLE_DNS"
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
