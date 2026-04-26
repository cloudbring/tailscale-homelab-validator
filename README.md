# Tailscale Homelab Validator

Scheduled GitHub Actions workflow that joins a private tailnet as an ephemeral node and validates connectivity, MagicDNS, subnet routing, and DNS resolution. Catches admin-console drift, expired ACLs, subnet route breakage, and DNS conflicts before they become outages.

## What it checks

Every 15 minutes:

- **Peer health** — expected tailnet peers are online (parsed from `tailscale status --json`)
- **MagicDNS** — `<peer>.<tailnet>.ts.net` resolves to the expected tailnet IP
- **Subnet routing** — TCP reachability to LAN-side services via the homelab's subnet router
- **Pi-hole DNS** — internal `*.lab.mwangi.us` names resolve through Pi-hole over the subnet route
- **Two-router redundancy** — both subnet routers advertise the route

On failure: posts to ntfy with high priority.

## Architecture

```
┌──────────────────┐  GitHub-hosted Linux runner       ┌──────────────────┐
│  GitHub Actions  │  ─────────────────────────────►   │   Public-facing  │
│  cron */15 *    │                                     │   coordination   │
│                  │  ephemeral tailnet node            │   server +       │
└──────────────────┘  via tailscale/github-action@v2    │   DERP relays    │
                              │                          └──────────────────┘
                              │ encrypted WireGuard
                              ▼
                    ┌──────────────────────────┐
                    │  Homelab tailnet         │
                    │  pox / wormhole          │  ← subnet routers
                    │  silverstone, iphone     │  ← clients
                    └──────────────────────────┘
                              │ subnet route 192.168.1.0/24
                              ▼
                    ┌──────────────────────────┐
                    │  192.168.1.0/24 LAN      │
                    │  Proxmox, TrueNAS,       │
                    │  Pi-hole, services       │
                    └──────────────────────────┘
```

## Setup

See [SETUP.md](./SETUP.md).

## Why public

This repo lives in a public GitHub repo so standard runner minutes are unlimited free. No homelab secrets are committed here — Tailscale OAuth credentials and ntfy topic live in GitHub Actions secrets only. The probe script's hardcoded hostnames and RFC 1918 IPs are not sensitive.

## Cost

$0/month on GitHub-hosted standard `ubuntu-latest` runners as long as the repo stays public. See the [companion plan](https://github.com/cloudbring/tailscale-homelab-validator/blob/main/SETUP.md#cost) for the math.

## License

MIT
