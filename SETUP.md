# Setup

This is the same content as the openclaw `docs/tailscale-validator/getting-started.md` — kept in sync so the public repo is self-contained.

## Prerequisites you must do (3 admin-console actions, ~5 min total)

### 1. Create the Tailscale OAuth client

1. Open https://login.tailscale.com/admin/settings/oauth
2. Click **Generate OAuth client**
3. Description: `homelab-validator`
4. Scopes — enable **`auth_keys` Write**
5. Tags — add `tag:ci-validator`
6. Click **Generate**
7. Copy the **client ID** and **client secret** (the secret is only shown once)

### 2. Add the validator tag and ACL rule

1. Open https://login.tailscale.com/admin/acls
2. In `tagOwners`, add:
   ```jsonc
   "tagOwners": {
     // ...existing entries...
     "tag:ci-validator": ["autogroup:admin"]
   }
   ```
3. In `acls`, add:
   ```jsonc
   {
     "action": "accept",
     "src":    ["tag:ci-validator"],
     "dst":    ["192.168.1.0/24:*"]
   }
   ```
4. Click **Save**. Tailscale validates the policy before saving — if it errors, fix syntax and resave.

### 3. Populate the GitHub Actions secrets

Pick **one** of the two paths.

**Path A — via `gh secret set` (you have this CLI):**

```bash
cd ~/dev/tailscale-homelab-validator   # or wherever this repo lives locally

gh secret set TS_OAUTH_CLIENT_ID  --body "<client-id-from-step-1>"
gh secret set TS_OAUTH_SECRET     --body "<client-secret-from-step-1>"
gh secret set NTFY_TOPIC          --body "<your-ntfy-topic>"
```

**Path B — via the GitHub UI:**

1. Open https://github.com/cloudbring/tailscale-homelab-validator/settings/secrets/actions
2. Click **New repository secret**
3. Add each secret in turn

## Trigger a dry run

```bash
gh workflow run probe.yml --repo cloudbring/tailscale-homelab-validator
gh run watch --repo cloudbring/tailscale-homelab-validator
```

Or via UI: **Actions → Tailscale Probe → Run workflow**.

## Cron behavior

The cron starts firing every 15 minutes once the workflow is on `main`. GitHub may delay scheduled runs by a few minutes under load — that's normal, not a probe failure.

## Cost

$0/month for as long as the repo stays public and `runs-on: ubuntu-latest`. The previously-announced GitHub Actions control-plane platform fee was postponed indefinitely on 2025-12-17 and is not in effect as of 2026-04-25.

## Fallback to Blacksmith.sh

If GitHub-hosted runners ever cause false-positive failures (rare in practice), swap the workflow to Blacksmith ARM:

```diff
-     runs-on: ubuntu-latest
+     runs-on: blacksmith-2vcpu-ubuntu-2404-arm
```

Cost: ~$3.30/month at 15-min cadence (3,000 min free + $0.0025/min overage).

## Tuning

- **Cadence**: change `cron: '*/15 * * * *'` in `.github/workflows/probe.yml`. GHA cron min granularity is 5 minutes.
- **Expected peers / probes**: edit the configuration block at the top of `scripts/probe.sh`.
- **Stale-peer tolerance**: change `STALE_PEER_SECONDS` in `scripts/probe.sh`. Default 86,400s (24h).
- **Consecutive-failure dampening**: not enabled in v1. If the probe gets noisy, gate the `ntfy` call on the previous run's status via `gh run list` from inside the workflow.
