# Known Issues & Future Work

## Resolved

### GitHub silently disabled the scheduled probe (60-day inactivity rule)

**Discovered:** 2026-07-10 during the Project Atlas review — no probe runs since 2026-06-25.
**Resolved:** 2026-07-11.

**Root cause:** GitHub disables `schedule` triggers on any workflow after 60 days
without repo activity (`disabled_inactivity`). Last push was 2026-04-25; the timer
expired 2026-06-25. The monitor died silently — nothing watches the watcher, so the
homelab ran ~15 days with no external monitoring and no alert about the gap.

**Fix (three layers):**
1. Workflow re-enabled + verified green (first run 2026-07-11, all checks passed).
2. `keepalive` job in `probe.yml`: every Monday's 00:0x run calls the
   workflows/enable API with `actions: write`, resetting the 60-day timer indefinitely.
3. Dead-man's-switch moved outside GitHub: the factory's daily health-check routine
   (cloudbring/factory `routines/health-check.md`, signal G1) checks this repo's most
   recent run via the public API and files a Linear issue if the newest run is >2 h old
   or ≥3 consecutive runs failed. A daily `Priority: min` ntfy heartbeat (00:0x run)
   additionally makes silence human-visible.

**Verification:** `gh run list` shows the 2026-07-11 dispatched run `success`;
keepalive/heartbeat conditions reviewed for the 00:00 leading-zero edge case.

### Subnet routing through `wormhole` doesn't forward TCP

**Discovered:** 2026-04-25 during initial validator dry runs.
**Resolved:** 2026-04-26.

**Root cause:** Not a forwarding issue at all. A parallel investigation traced the symptom to **`pox` and `silverstone` both having `RouteAll: true`** and accepting `wormhole`'s `192.168.1.0/24` advertisement. The Linux kernel on `pox` then routed return traffic for any LAN client through `tailscale0` instead of `vmbr0`, dropping packets that Tailscale couldn't deliver. Same root cause as the gitea push hang documented in the openclaw repo at `docs/gitea/push-hang-investigation-2026-04-25.md`.

**Fix:** `tailscale set --accept-routes=false` on both `pox` (Proxmox) and `silverstone` (Mac). Both peers are LAN-resident and don't need `192.168.1.0/24` tunnelled. `wormhole` continues to advertise the route — the validator and any genuinely off-LAN client (e.g. Mac on cellular) still get subnet routing through it.

**Verification:** `ip route get 192.168.1.110` on `pox` now resolves via `vmbr0` (was `tailscale0`). LAN clients reach all `192.168.1.x` services. Validator's subnet-route probes pass.

## Open

(none currently)
