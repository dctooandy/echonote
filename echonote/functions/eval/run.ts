// npm run eval -- [--model <id>] [--cases a,b] [--runs 3] [--budget 0.5]
//                 [--baseline <run folder>] [--label <text>] [--evals <dir>] [--yes]
//
// Runs the analysis eval set against the Anthropic API with the same
// parameters production uses (spec feature-analysis-eval-set). Reads the
// key from functions/.env.local (EVAL_ANTHROPIC_API_KEY). Estimates the
// cost first and only sends requests when it fits the budget; without
// --yes it stops after the estimate so a person can confirm.

import Anthropic from "@anthropic-ai/sdk";
import { execSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { ANALYSIS_MAX_TOKENS, ANALYSIS_MODEL, buildAnalysisParams, promptVersion } from "../src/analyze";
import { EvalCase, loadCases } from "./cases";
import { gradeOutput } from "./grade";
import { TYPICAL_OUTPUT_TOKENS, callCost, estimateCaseCost } from "./pricing";
import { CallRecord, RunRecord, renderReport } from "./report";

function option(args: string[], name: string): string | undefined {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined;
}

/**
 * Production's params, with the user message marked for caching: the N
 * calls of one case share it, so calls 2..N read it back.
 */
function cachedParams(c: EvalCase, model: string) {
  const params = buildAnalysisParams(c.request, { model });
  return {
    ...params,
    messages: params.messages.map((m) => ({
      role: m.role,
      content: [{ type: "text" as const, text: m.content, cache_control: { type: "ephemeral" as const } }],
    })),
  };
}

function latestRun(runsDir: string, except: string): string | undefined {
  if (!existsSync(runsDir)) return undefined;
  return readdirSync(runsDir)
    .filter((d) => d !== except && existsSync(join(runsDir, d, "run.json")))
    .sort()
    .pop();
}

async function main() {
  const args = process.argv.slice(2);
  const model = option(args, "--model") ?? ANALYSIS_MODEL;
  const runs = Number(option(args, "--runs") ?? 3);
  const budget = Number(option(args, "--budget") ?? 0.5);
  const label = option(args, "--label") ?? "";
  const evalsRoot = resolve(option(args, "--evals") ?? join(process.cwd(), "..", "evals"));
  const names = option(args, "--cases")?.split(",").map((s) => s.trim()).filter(Boolean);
  const confirmed = args.includes("--yes");

  const apiKey = process.env.EVAL_ANTHROPIC_API_KEY;
  if (!apiKey) throw new Error("沒有 EVAL_ANTHROPIC_API_KEY：請寫進 functions/.env.local");
  if (!Number.isInteger(runs) || runs < 1) throw new Error("--runs 要是正整數");

  const cases = loadCases(evalsRoot, names);
  if (cases.length === 0) throw new Error(`${evalsRoot} 底下沒有案例`);
  if (!existsSync(join(evalsRoot, "private"))) console.log("（沒有 evals/private/，只跑照稿案例）");

  const client = new Anthropic({ apiKey });

  // Estimate before spending anything.
  let estimated = 0;
  let worstCase = 0;
  console.log(`模型 ${model}，prompt ${promptVersion()}，每筆 ${runs} 次：`);
  for (const c of cases) {
    const params = buildAnalysisParams(c.request, { model });
    // With output_config: the schema adds ~2,600 tokens of input, which
    // also lifts the short cases past Haiku 4.5's 4,096-token cache minimum.
    const { input_tokens } = await client.messages.countTokens({
      model: params.model,
      system: params.system,
      messages: params.messages,
      output_config: params.output_config,
    });
    const cost = estimateCaseCost(model, input_tokens, runs, TYPICAL_OUTPUT_TOKENS);
    estimated += cost;
    worstCase += estimateCaseCost(model, input_tokens, runs, ANALYSIS_MAX_TOKENS);
    console.log(`  ${c.name}${c.private ? "（私人）" : ""}：輸入 ${input_tokens} token，估 US$${cost.toFixed(4)}`);
  }
  console.log(`估算 US$${estimated.toFixed(4)}（每次都寫滿 max_tokens 的最壞情況 US$${worstCase.toFixed(4)}），上限 US$${budget}`);
  if (estimated > budget) {
    console.log("估算超過上限，沒有送出任何請求。");
    process.exitCode = 2;
    return;
  }
  if (!confirmed) {
    console.log("確認後加上 --yes 再執行一次。");
    return;
  }

  const now = new Date();
  const two = (n: number) => String(n).padStart(2, "0");
  // Local time, so the folder name matches the clock the person running it sees.
  const id = `${now.getFullYear()}${two(now.getMonth() + 1)}${two(now.getDate())}-${two(now.getHours())}${two(now.getMinutes())}_${model}`;
  const runsDir = join(evalsRoot, "runs");
  const record: RunRecord = {
    id,
    startedAt: new Date().toISOString(),
    model,
    promptVersion: promptVersion(),
    gitCommit: execSync("git rev-parse --short HEAD").toString().trim(),
    label,
    runsPerCase: runs,
    budgetUsd: budget,
    estimatedUsd: estimated,
    totalCostUsd: 0,
    completed: true,
    cases: [],
  };

  // Sequential on purpose: the N calls of a case read each other's cache.
  outer: for (const c of cases) {
    const caseRecord = { name: c.name, private: c.private, expectHash: c.expectHash, calls: [] as CallRecord[] };
    record.cases.push(caseRecord);
    for (let i = 0; i < runs; i++) {
      if (record.totalCostUsd >= budget) {
        record.completed = false;
        console.log(`已花 US$${record.totalCostUsd.toFixed(4)}，達到上限，停止。`);
        break outer;
      }
      const started = Date.now();
      let call: CallRecord;
      try {
        const response = await client.messages.create(cachedParams(c, model));
        const text = response.content.find((b): b is Anthropic.TextBlock => b.type === "text")?.text;
        let output: unknown = null;
        try {
          output = text ? JSON.parse(text) : null;
        } catch {
          // Graded as a schema failure below.
        }
        call = {
          ok: true,
          stopReason: response.stop_reason,
          usage: { ...response.usage } as unknown as Record<string, number | null>,
          costUsd: callCost(model, response.usage),
          ms: Date.now() - started,
          output,
          checks: gradeOutput(output, c.request, c.expect, response.stop_reason),
        };
      } catch (err) {
        call = {
          ok: false,
          error: err instanceof Error ? err.message : String(err),
          stopReason: null,
          costUsd: 0,
          ms: Date.now() - started,
          output: null,
          checks: [],
        };
      }
      record.totalCostUsd += call.costUsd;
      caseRecord.calls.push(call);
      const failed = call.checks.filter((r) => !r.pass).length;
      console.log(`  ${c.name} #${i + 1}：${call.ok ? `${call.checks.length - failed}/${call.checks.length} 通過` : `失敗：${call.error}`}，US$${call.costUsd.toFixed(4)}`);
    }
  }

  const baselineId = option(args, "--baseline") ?? latestRun(runsDir, id);
  const baselinePath = baselineId ? join(runsDir, baselineId, "run.json") : undefined;
  if (baselineId && (!baselinePath || !existsSync(baselinePath))) throw new Error(`找不到基準輪 ${baselineId}`);
  const baseline = baselinePath ? (JSON.parse(readFileSync(baselinePath, "utf8")) as RunRecord) : undefined;

  const out = join(runsDir, id);
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, "run.json"), JSON.stringify(record, null, 2));
  writeFileSync(join(out, "report.md"), renderReport(record, baseline));
  console.log(`花費 US$${record.totalCostUsd.toFixed(4)}；報告：${join(out, "report.md")}`);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exitCode = 1;
});
