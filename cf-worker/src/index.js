/**
 * validator-deadman — Cloudflare Worker cron that watches the GitHub Actions
 * probe in this repo and screams over ntfy when the watcher itself dies.
 *
 * Why this exists: GitHub silently disables scheduled workflows after 60 days
 * of repo inactivity (it happened 2026-06-25 and nobody noticed for 15 days).
 * CF cron triggers have no such policy, and the free tier covers this at
 * ~1,500 invocations/month.
 *
 * Alerts (every 30 min while the condition holds — a dead monitor should nag):
 *   - newest probe run older than STALE_HOURS
 *   - the 3 most recent completed runs all non-success
 *   - the GitHub API itself unreachable (fails open, loudly)
 */

const REPO = "cloudbring/tailscale-homelab-validator";
const RUNS_URL = `https://api.github.com/repos/${REPO}/actions/runs?per_page=10`;
const STALE_HOURS = 2;

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
  },
};
