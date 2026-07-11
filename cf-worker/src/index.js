/**
 * validator-deadman — Cloudflare Worker cron with two duties:
 *
 * 1. Dead-man's-switch for the GitHub Actions probe in this repo. GitHub
 *    silently disables scheduled workflows after 60 days of repo inactivity
 *    (it happened 2026-06-25 and nobody noticed for 15 days). CF cron
 *    triggers have no such policy.
 * 2. Off-prem edge probe of the homelab's Cloudflare-Tunnel-exposed
 *    services — the detector role the 2026-04 external-monitoring research
 *    assigned to an Oracle-hosted Kuma that was never deployed. Any HTTP
 *    status below 520 proves tunnel + origin are alive (302/401 auth
 *    redirects are proof of life); 52x/530 or a network error means the
 *    public edge path is down.
 *
 * Alerts (every 30 min while a condition holds — a dead monitor should nag):
 *   - newest probe run older than STALE_HOURS
 *   - the 3 most recent completed runs all non-success
 *   - the GitHub API itself unreachable (fails open, loudly)
 *   - any lab edge endpoint down (after one in-tick retry)
 */

const REPO = "cloudbring/tailscale-homelab-validator";
const RUNS_URL = `https://api.github.com/repos/${REPO}/actions/runs?per_page=10`;
const STALE_HOURS = 2;

const LAB_ENDPOINTS = [
  "https://git.mwangi.us",
  "https://auth.mwangi.us",
  "https://audiobookshelf.mwangi.us",
];
const EDGE_DOWN_STATUS = 520; // >= this (or fetch error) counts as down

export function evaluateEdge(results) {
  const down = results.filter((r) => !r.ok);
  if (down.length === 0) return { alert: false, reason: "edge healthy" };
  return {
    alert: true,
    reason: down.map((r) => `${r.url}: ${r.detail}`).join("; "),
  };
}

async function probeEndpoint(url) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const res = await fetch(url, {
        method: "HEAD",
        redirect: "manual",
        signal: AbortSignal.timeout(10000),
      });
      if (res.status < EDGE_DOWN_STATUS) return { url, ok: true, detail: `HTTP ${res.status}` };
      if (attempt === 1) return { url, ok: false, detail: `HTTP ${res.status}` };
    } catch (err) {
      if (attempt === 1) return { url, ok: false, detail: err.message };
    }
    await new Promise((r) => setTimeout(r, 5000));
  }
}

export function evaluateRuns(runs, nowMs) {
  if (!runs || runs.length === 0) {
    return { alert: true, reason: "no workflow runs found at all" };
  }
  const newest = runs[0];
  const ageHours = (nowMs - Date.parse(newest.created_at)) / 3.6e6;
  if (ageHours > STALE_HOURS) {
    return {
      alert: true,
      reason: `newest probe run is ${ageHours.toFixed(1)}h old (limit ${STALE_HOURS}h) — schedule likely disabled or failing to trigger`,
    };
  }
  const completed = runs.filter((r) => r.status === "completed").slice(0, 3);
  if (completed.length === 3 && completed.every((r) => r.conclusion !== "success")) {
    return {
      alert: true,
      reason: `last 3 completed runs all ${completed.map((r) => r.conclusion).join("/")}`,
    };
  }
  return { alert: false, reason: "healthy" };
}

async function notify(env, title, body) {
  await fetch(`https://ntfy.sh/${env.NTFY_TOPIC}`, {
    method: "POST",
    headers: {
      Title: title,
      Priority: "urgent",
      Tags: "rotating_light,tailscale",
      Click: `https://github.com/${REPO}/actions`,
    },
    body,
  });
}

export default {
  async scheduled(_event, env, _ctx) {
    let runs;
    try {
      const res = await fetch(RUNS_URL, {
        headers: {
          "User-Agent": "validator-deadman-worker",
          Accept: "application/vnd.github+json",
        },
      });
      if (!res.ok) throw new Error(`GitHub API ${res.status}`);
      runs = (await res.json()).workflow_runs;
    } catch (err) {
      await notify(
        env,
        "Validator dead-man's-switch: GitHub API unreachable",
        `Could not read probe runs: ${err.message}. The probe may be fine, but the watcher is blind.`,
      );
      return;
    }
    const verdict = evaluateRuns(runs, Date.now());
    if (verdict.alert) {
      await notify(env, "Tailscale probe is DEAD", verdict.reason);
    }

    // Duty 2: homelab public edge, probed from outside the lab
    const results = await Promise.all(LAB_ENDPOINTS.map(probeEndpoint));
    const edge = evaluateEdge(results);
    if (edge.alert) {
      await notify(env, "Homelab edge is DOWN", edge.reason);
    }
  },
};
