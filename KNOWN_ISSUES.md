# Known Issues & Future Work

## Open

### Subnet routing through `wormhole` (TrueNAS) doesn't forward TCP

**Discovered:** 2026-04-25 during initial validator dry runs.

**Symptom:** When the validator routes via wormhole's advertised `192.168.1.0/24` subnet route, TCP connections to LAN-side hosts (e.g. `192.168.1.50:8006` Proxmox UI, `192.168.1.50:53` Pi-hole DNS) time out. TCP to wormhole's own LAN IP (`192.168.1.60:443`) works because no forwarding is required.

**What was verified:**
- IPv4 forwarding is enabled on the TrueNAS host (`/proc/sys/net/ipv4/ip_forward = 1`)
- The Tailscale Apps container has `NET_ADMIN`, `NET_RAW`, `SYS_MODULE` capabilities
- `tailscale ping --tsmp 192.168.1.50` succeeds — Tailscale considers the route valid
- pox's subnet route advertisement appears suppressed in the validator's netmap once wormhole became primary

**Likely causes (untested):**
- Tailscale Docker container in TrueNAS Apps may not have set up SNAT/iptables rules correctly for forwarding
- pox's subnet-route approval may have been displaced when wormhole was authorized

**Workaround for v1:** the probe uses direct tailnet IPs (`100.82.79.26`, `100.96.34.98`) instead of LAN IPs. This bypasses subnet routing entirely while still validating that the homelab tailnet endpoints are reachable from outside.

**Next steps:**
1. SSH to TrueNAS, exec into the Tailscale container, run `tailscale debug netmap` and `iptables -L -t nat`
2. Check whether wormhole's `tailscale up --advertise-routes=192.168.1.0/24` actually applied (try `tailscale set --advertise-routes=192.168.1.0/24` to ensure)
3. Verify pox's subnet route is still approved in the admin console
4. Once subnet routing is working: re-add LAN-IP probes and Pi-hole DNS check to `scripts/probe.sh`

## Resolved

(none yet)
