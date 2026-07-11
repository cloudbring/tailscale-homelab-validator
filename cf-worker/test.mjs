import { test } from "node:test";
import assert from "node:assert/strict";
import { evaluateRuns } from "./src/index.js";

const NOW = Date.parse("2026-07-11T12:00:00Z");
const run = (minAgo, status = "completed", conclusion = "success") => ({
  created_at: new Date(NOW - minAgo * 60000).toISOString(),
  status,
  conclusion,
});

test("healthy: recent successful runs", () => {
  const v = evaluateRuns([run(10), run(25), run(40)], NOW);
  assert.equal(v.alert, false);
});

test("alerts when newest run older than 2h", () => {
  const v = evaluateRuns([run(150), run(165)], NOW);
  assert.equal(v.alert, true);
  assert.match(v.reason, /2\.5h old/);
});

test("alerts on 3 consecutive completed failures", () => {
  const v = evaluateRuns(
    [run(10, "completed", "failure"), run(25, "completed", "failure"), run(40, "completed", "failure")],
    NOW,
  );
  assert.equal(v.alert, true);
  assert.match(v.reason, /last 3 completed runs/);
});

test("no failure alert when an in-progress run is newest and older completed are green", () => {
  const v = evaluateRuns(
    [run(5, "in_progress", null), run(20), run(35), run(50)],
    NOW,
  );
  assert.equal(v.alert, false);
});

test("2 failures then success does not alert", () => {
  const v = evaluateRuns(
    [run(10, "completed", "failure"), run(25, "completed", "failure"), run(40)],
    NOW,
  );
  assert.equal(v.alert, false);
});

test("alerts on empty run list", () => {
  assert.equal(evaluateRuns([], NOW).alert, true);
});

test("boundary: exactly at 2h does not alert", () => {
  const v = evaluateRuns([run(120)], NOW);
  assert.equal(v.alert, false);
});

// --- edge probe evaluation ---
import { evaluateEdge } from "./src/index.js";

test("edge healthy: all endpoints ok", () => {
  const v = evaluateEdge([
    { url: "https://a", ok: true, detail: "HTTP 200" },
    { url: "https://b", ok: true, detail: "HTTP 302" },
  ]);
  assert.equal(v.alert, false);
});

test("edge down: one endpoint failing lists it", () => {
  const v = evaluateEdge([
    { url: "https://a", ok: true, detail: "HTTP 200" },
    { url: "https://b", ok: false, detail: "HTTP 530" },
  ]);
  assert.equal(v.alert, true);
  assert.match(v.reason, /https:\/\/b: HTTP 530/);
});

test("edge down: network error detail propagates", () => {
  const v = evaluateEdge([{ url: "https://a", ok: false, detail: "timeout" }]);
  assert.equal(v.alert, true);
  assert.match(v.reason, /timeout/);
});
