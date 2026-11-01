// The run record and its Markdown report, including the comparison with a
// baseline run (spec feature-analysis-eval-set).

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { CheckResult } from "./grade";

export interface CallRecord {
  ok: boolean;
  error?: string;
  stopReason: string | null;
  usage?: Record<string, number | null>;
  costUsd: number;
  ms: number;
  /** Parsed model JSON; null when the call failed or didn't parse. */
  output: unknown;
  checks: CheckResult[];
}

export interface CaseRecord {
  name: string;
  private: boolean;
  expectHash: string;
  calls: CallRecord[];
}

export interface RunRecord {
  id: string;
  startedAt: string;
  model: string;
  promptVersion: string;
  gitCommit: string;
  label: string;
  runsPerCase: number;
  budgetUsd: number;
  estimatedUsd: number;
  totalCostUsd: number;
  /** False when the budget stopped the run early. */
  completed: boolean;
  /** Things the reader should know about this run, e.g. no private cases. */
  notes?: string[];
  cases: CaseRecord[];
}

/** For each check of a case: how many calls passed it, out of how many ran. */
export function passCounts(c: CaseRecord): Map<string, { pass: number; total: number; lastDetail?: string }> {
  const counts = new Map<string, { pass: number; total: number; lastDetail?: string }>();
  for (const call of c.calls) {
    if (!call.ok) continue;
    for (const check of call.checks) {
      const entry = counts.get(check.key) ?? { pass: 0, total: 0 };
      entry.total++;
      if (check.pass) entry.pass++;
      else entry.lastDetail = check.detail;
      counts.set(check.key, entry);
    }
  }
  return counts;
}

export interface Change {
  caseName: string;
  key: string;
  before: number;
  after: number;
  /** The case's expect.json changed between the runs: not like for like. */
  expectChanged: boolean;
}

export interface CheckRef {
  caseName: string;
  key: string;
}

/**
 * Pass-rate changes per check, for the cases and checks both runs have;
 * cases and checks only one run has are listed as added or removed.
 */
export function compareRuns(current: RunRecord, baseline: RunRecord): {
  changes: Change[];
  added: string[];
  removed: string[];
  addedChecks: CheckRef[];
  removedChecks: CheckRef[];
} {
  const changes: Change[] = [];
  const addedChecks: CheckRef[] = [];
  const removedChecks: CheckRef[] = [];
  const baseCases = new Map(baseline.cases.map((c) => [c.name, c]));
  for (const c of current.cases) {
    const base = baseCases.get(c.name);
    if (!base) continue;
    const now = passCounts(c);
    const before = passCounts(base);
    for (const key of now.keys()) if (!before.has(key)) addedChecks.push({ caseName: c.name, key });
    for (const key of before.keys()) if (!now.has(key)) removedChecks.push({ caseName: c.name, key });
    for (const [key, counts] of now) {
      const old = before.get(key);
      if (!old || counts.total === 0 || old.total === 0) continue;
      const rateNow = counts.pass / counts.total;
      const rateBefore = old.pass / old.total;
      if (rateNow !== rateBefore || c.expectHash !== base.expectHash) {
        changes.push({ caseName: c.name, key, before: rateBefore, after: rateNow, expectChanged: c.expectHash !== base.expectHash });
      }
    }
  }
  const currentNames = new Set(current.cases.map((c) => c.name));
  return {
    changes,
    added: current.cases.filter((c) => !baseCases.has(c.name)).map((c) => c.name),
    removed: baseline.cases.filter((c) => !currentNames.has(c.name)).map((c) => c.name),
    addedChecks,
    removedChecks,
  };
}

/**
 * The run to compare against: [named] when given (an error when it's
 * missing), otherwise the latest run in [runsDir] other than [except].
 * Called before any API call, so a typo can't throw away a paid run.
 */
export function loadBaseline(runsDir: string, named: string | undefined, except: string): RunRecord | undefined {
  const id =
    named ??
    (existsSync(runsDir)
      ? readdirSync(runsDir)
          .filter((d) => d !== except && existsSync(join(runsDir, d, "run.json")))
          .sort()
          .pop()
      : undefined);
  if (!id) return undefined;
  const path = join(runsDir, id, "run.json");
  if (!existsSync(path)) throw new Error(`找不到基準輪 ${id}（${path}）`);
  return JSON.parse(readFileSync(path, "utf8")) as RunRecord;
}

const pct = (rate: number) => `${Math.round(rate * 100)}%`;
const usd = (n: number) => `US$${n.toFixed(4)}`;

export function renderReport(run: RunRecord, baseline?: RunRecord): string {
  const lines: string[] = [];
  let pass = 0;
  let total = 0;
  for (const c of run.cases) {
    for (const counts of passCounts(c).values()) {
      pass += counts.pass;
      total += counts.total;
    }
  }
  lines.push(
    `# 分析評測報告 ${run.id}`,
    "",
    `- 模型：\`${run.model}\`　prompt 版本：\`${run.promptVersion}\`　commit：\`${run.gitCommit}\``,
    run.label ? `- 標籤：${run.label}` : "",
    `- 每筆 ${run.runsPerCase} 次；花費 ${usd(run.totalCostUsd)}（估算 ${usd(run.estimatedUsd)}，上限 ${usd(run.budgetUsd)}）`,
    run.completed ? "" : "- ⚠️ **未跑完**：達到費用上限，後面的呼叫沒有送出",
    ...(run.notes ?? []).map((n) => `- ${n}`),
    `- 整體通過率：${total ? pct(pass / total) : "—"}（${pass}/${total} 項次）`,
    ""
  );

  if (baseline) {
    const { changes, added, removed, addedChecks, removedChecks } = compareRuns(run, baseline);
    lines.push(`## 跟基準輪 ${baseline.id} 比較`, "");
    lines.push(`基準：\`${baseline.model}\`、prompt \`${baseline.promptVersion}\`、commit \`${baseline.gitCommit}\``, "");
    if (changes.length === 0) lines.push("通過率沒有變化。");
    else {
      lines.push("| 案例 | 檢查 | 之前 | 現在 | |", "|---|---|---|---|---|");
      for (const ch of changes) {
        const mark = ch.after > ch.before ? "變好" : ch.after < ch.before ? "變差" : "";
        lines.push(`| ${ch.caseName} | ${ch.key} | ${pct(ch.before)} | ${pct(ch.after)} | ${mark}${ch.expectChanged ? "（檢查本身被修改過）" : ""} |`);
      }
    }
    if (added.length) lines.push("", `新增的案例：${added.join("、")}`);
    if (removed.length) lines.push("", `已移除的案例：${removed.join("、")}`);
    const refs = (list: CheckRef[]) => list.map((r) => `${r.caseName}：${r.key}`).join("、");
    if (addedChecks.length) lines.push("", `新增的檢查：${refs(addedChecks)}`);
    if (removedChecks.length) lines.push("", `已移除的檢查：${refs(removedChecks)}`);
    lines.push("");
  }

  lines.push("## 各案例", "");
  for (const c of run.cases) {
    const failed = c.calls.filter((call) => !call.ok);
    lines.push(`### ${c.name}${c.private ? "（私人）" : ""}`, "");
    if (failed.length) lines.push(`- ⚠️ ${failed.length} 次呼叫失敗：${failed.map((f) => f.error).join("；")}`, "");
    lines.push("| 檢查 | 通過 | 最近一次失敗的原因 |", "|---|---|---|");
    for (const [key, counts] of passCounts(c)) {
      lines.push(`| ${key} | ${counts.pass}/${counts.total}${counts.pass < counts.total ? " ⚠️" : ""} | ${counts.lastDetail ?? ""} |`);
    }
    lines.push("");
  }

  lines.push("## 附錄：每次的輸出", "");
  for (const c of run.cases) {
    c.calls.forEach((call, i) => {
      lines.push(`### ${c.name} 第 ${i + 1} 次（${call.stopReason ?? "失敗"}，${(call.ms / 1000).toFixed(1)} 秒，${usd(call.costUsd)}）`, "");
      lines.push("```json", JSON.stringify(call.output ?? call.error ?? null, null, 2), "```", "");
    });
  }
  return lines.filter((l, i, all) => !(l === "" && all[i - 1] === "")).join("\n");
}
