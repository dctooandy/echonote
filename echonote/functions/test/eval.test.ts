import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadCases } from "../eval/cases";
import { callCost, estimateCaseCost, priceOf } from "../eval/pricing";
import { CaseRecord, RunRecord, compareRuns, loadBaseline, passCounts, renderReport } from "../eval/report";

const close = (a: number, b: number) => assert.ok(Math.abs(a - b) < 1e-9, `${a} != ${b}`);

test("call cost adds input, cache writes, cache reads and output", () => {
  // Haiku 4.5: $1 in, $5 out, writes 1.25x, reads 0.1x (per million).
  close(
    callCost("claude-haiku-4-5", {
      input_tokens: 1_000_000,
      output_tokens: 1_000_000,
      cache_creation_input_tokens: 1_000_000,
      cache_read_input_tokens: 1_000_000,
    }),
    1 + 5 + 1.25 + 0.1
  );
  close(callCost("claude-haiku-4-5", { input_tokens: 2000, output_tokens: 1000, cache_read_input_tokens: null }), 0.007);
  assert.throws(() => priceOf("claude-unknown"), /沒有 claude-unknown 的價格/);
});

test("the estimate caches only prompts long enough to cache", () => {
  // Below Haiku 4.5's 4096-token minimum: every call pays full input.
  close(estimateCaseCost("claude-haiku-4-5", 3000, 3, 1000), (3000 * 3 + 1000 * 5 * 3) / 1e6);
  // Above it: one write, then reads.
  close(estimateCaseCost("claude-haiku-4-5", 10_000, 3, 1000), (10_000 * 1.25 + 10_000 * 0.1 * 2 + 1000 * 5 * 3) / 1e6);
});

function writeCase(root: string, folder: string, name: string, request: unknown, expect: unknown = {}) {
  const dir = join(root, folder, name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "request.json"), JSON.stringify(request));
  writeFileSync(join(dir, "expect.json"), JSON.stringify(expect));
}

const goodRequest = { segments: [{ start_ms: 0, end_ms: 1, text: "a" }] };

test("cases load from cases/ and private/, and can be picked by name", () => {
  const root = mkdtempSync(join(tmpdir(), "evals-"));
  writeCase(root, "cases", "c1", goodRequest);
  writeCase(root, "private", "c5", goodRequest, { description: "長會議" });
  const all = loadCases(root);
  assert.deepEqual(all.map((c) => [c.name, c.private]), [["c1", false], ["c5", true]]);
  assert.match(all[0].expectHash, /^[0-9a-f]{8}$/);
  assert.deepEqual(loadCases(root, ["c5"]).map((c) => c.name), ["c5"]);
  assert.throws(() => loadCases(root, ["c9"]), /找不到案例：c9/);
});

test("bad cases fail before any API call", () => {
  const root = mkdtempSync(join(tmpdir(), "evals-"));
  writeCase(root, "cases", "empty", { segments: [] });
  assert.throws(() => loadCases(root), /empty 的 request 沒通過驗證/);

  const root2 = mkdtempSync(join(tmpdir(), "evals-"));
  mkdirSync(join(root2, "cases", "half"), { recursive: true });
  writeFileSync(join(root2, "cases", "half", "request.json"), JSON.stringify(goodRequest));
  assert.throws(() => loadCases(root2), /half 缺少 expect.json/);

  const root3 = mkdtempSync(join(tmpdir(), "evals-"));
  writeCase(root3, "cases", "broken", goodRequest);
  writeFileSync(join(root3, "cases", "broken", "expect.json"), "{");
  assert.throws(() => loadCases(root3), /broken 的 JSON 格式錯誤/);
});

const call = (checks: [string, boolean][], ok = true) => ({
  ok,
  stopReason: ok ? "end_turn" : null,
  costUsd: 0.01,
  ms: 1000,
  output: {},
  checks: checks.map(([key, pass]) => ({ key, pass, detail: pass ? undefined : `${key} 沒過` })),
});

const run = (id: string, cases: CaseRecord[]): RunRecord => ({
  id,
  startedAt: "",
  model: "claude-haiku-4-5",
  promptVersion: "abcd1234",
  gitCommit: "e4a463b",
  label: "",
  runsPerCase: 3,
  budgetUsd: 0.5,
  estimatedUsd: 0.1,
  totalCostUsd: 0.09,
  completed: true,
  cases,
});

test("pass counts skip failed calls", () => {
  const counts = passCounts({
    name: "c1",
    private: false,
    expectHash: "h",
    calls: [call([["a", true]]), call([["a", false]]), { ...call([], false), error: "boom" }],
  });
  assert.deepEqual(counts.get("a"), { pass: 1, total: 2, lastDetail: "a 沒過" });
});

test("comparison lists rate changes, edited checks, and added or removed cases", () => {
  const before = run("1", [
    { name: "c1", private: false, expectHash: "h1", calls: [call([["a", true], ["b", false]])] },
    { name: "old", private: false, expectHash: "x", calls: [call([["a", true]])] },
  ]);
  const after = run("2", [
    { name: "c1", private: false, expectHash: "h2", calls: [call([["a", true], ["b", true]])] },
    { name: "new", private: false, expectHash: "y", calls: [call([["a", true]])] },
  ]);
  const { changes, added, removed } = compareRuns(after, before);
  assert.deepEqual(changes, [
    { caseName: "c1", key: "a", before: 1, after: 1, expectChanged: true },
    { caseName: "c1", key: "b", before: 0, after: 1, expectChanged: true },
  ]);
  assert.deepEqual(added, ["new"]);
  assert.deepEqual(removed, ["old"]);

  const report = renderReport(after, before);
  assert.match(report, /\| c1 \| b \| 0% \| 100% \| 變好（檢查本身被修改過） \|/);
  assert.match(report, /新增的案例：new/);
  assert.match(report, /整體通過率：100%/);
});

test("the report says when the budget cut the run short, and marks shaky checks", () => {
  const report = renderReport({
    ...run("1", [{ name: "c1", private: true, expectHash: "h", calls: [call([["a", true]]), call([["a", false]])] }]),
    completed: false,
  });
  assert.match(report, /未跑完/);
  assert.match(report, /### c1（私人）/);
  assert.match(report, /\| a \| 1\/2 ⚠️ \| a 沒過 \|/);
});

test("comparison lists checks that were added, renamed or removed in a shared case", () => {
  const before = run("1", [{ name: "c5", private: true, expectHash: "h1", calls: [call([["光電", false], ["安全性", true]])] }]);
  const after = run("2", [{ name: "c5", private: true, expectHash: "h2", calls: [call([["光電或太陽能", true], ["安全性", true]])] }]);
  const { addedChecks, removedChecks } = compareRuns(after, before);
  assert.deepEqual(addedChecks, [{ caseName: "c5", key: "光電或太陽能" }]);
  assert.deepEqual(removedChecks, [{ caseName: "c5", key: "光電" }]);

  const report = renderReport(after, before);
  assert.match(report, /新增的檢查：c5：光電或太陽能/);
  assert.match(report, /已移除的檢查：c5：光電/);
});

test("the report carries notes about the run", () => {
  const report = renderReport({ ...run("1", []), notes: ["沒有 evals/private/，只跑照稿案例"] });
  assert.match(report, /- 沒有 evals\/private\/，只跑照稿案例/);
});

test("the baseline is resolved before any call: latest run by default, error when the named one is missing", () => {
  const runsDir = join(mkdtempSync(join(tmpdir(), "runs-")), "runs");
  assert.equal(loadBaseline(runsDir, undefined, "now"), undefined);
  for (const id of ["20261101-0554_a", "20261101-1430_a", "now"]) {
    mkdirSync(join(runsDir, id), { recursive: true });
    writeFileSync(join(runsDir, id, "run.json"), JSON.stringify(run(id, [])));
  }
  mkdirSync(join(runsDir, "zz-no-record"));
  assert.equal(loadBaseline(runsDir, undefined, "now")?.id, "20261101-1430_a");
  assert.equal(loadBaseline(runsDir, "20261101-0554_a", "now")?.id, "20261101-0554_a");
  assert.throws(() => loadBaseline(runsDir, "typo", "now"), /找不到基準輪 typo/);
});
