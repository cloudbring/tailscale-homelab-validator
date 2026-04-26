# Known Issues & Future Work

## Resolved

### Subnet routing through `wormhole` doesn't forward TCP

**Discovered:** 2026-04-25 during initial validator dry runs.
**Resolved:** 2026-04-26.

**Root cause:** Not a forwarding issue at all. A parallel investigation traced the symptom to **`pox` and `silverstone` both having `RouteAll: true`** and accepting `wormhole`'s `192.168.1.0/24` advertisement. The Linux kernel on `pox` then routed return traffic for any LAN client through `tailscale0` instead of `vmbr0`, dropping packets that Tailscale couldn't deliver. Same root cause as the gitea push hang documented in the openclaw repo at `docs/gitea/push-hang-investigation-2026-04-25.md`.

**Fix:** `tailscale set --accept-routes=false` on both `pox` (Proxmox) and `silverstone` (Mac). Both peers are LAN-resident and don't need `192.168.1.0/24` tunnelled. `wormhole` continues to advertise the route — the validator and any genuinely off-LAN client (e.g. Mac on cellular) still get subnet routing through it.

**Verification:** `ip route get 192.168.1.110` on `pox` now resolves via `vmbr0` (was `tailscale0`). LAN clients reach all `192.168.1.x` services. Validator's subnet-route probes pass.

## Open

(none currently)
