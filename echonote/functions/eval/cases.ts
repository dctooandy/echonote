// Loads eval cases: evals/cases/<name>/ (in git) and evals/private/<name>/
// (real meetings, never in git). Each holds request.json and expect.json.

import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { AnalyzeMeetingRequest, validateRequest } from "../src/analyze";
import { Expect } from "./grade";

export interface EvalCase {
  name: string;
  private: boolean;
  request: AnalyzeMeetingRequest;
  expect: Expect;
  /** Changes when expect.json changes, so a report can flag edited checks. */
  expectHash: string;
}

export const hashText = (text: string) => createHash("sha256").update(text).digest("hex").slice(0, 8);

/**
 * Every case under [evalsRoot], or only [names] when given. Throws before
 * any API call when a case is missing, malformed or invalid.
 */
export function loadCases(evalsRoot: string, names?: string[]): EvalCase[] {
  const cases: EvalCase[] = [];
  for (const [folder, isPrivate] of [
    ["cases", false],
    ["private", true],
  ] as const) {
    const dir = join(evalsRoot, folder);
    if (!existsSync(dir)) continue;
    for (const name of readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort()) {
      if (names && !names.includes(name)) continue;
      const read = (file: string) => {
        const path = join(dir, name, file);
        if (!existsSync(path)) throw new Error(`案例 ${name} 缺少 ${file}`);
        return readFileSync(path, "utf8");
      };
      const expectText = read("expect.json");
      let request: AnalyzeMeetingRequest;
      let expect: Expect;
      try {
        request = JSON.parse(read("request.json"));
        expect = JSON.parse(expectText);
      } catch (err) {
        throw new Error(`案例 ${name} 的 JSON 格式錯誤：${err instanceof Error ? err.message : err}`);
      }
      const invalid = validateRequest(request);
      if (invalid) throw new Error(`案例 ${name} 的 request 沒通過驗證：${invalid}`);
      cases.push({ name, private: isPrivate, request, expect, expectHash: hashText(expectText) });
    }
  }
  const missing = (names ?? []).filter((n) => !cases.some((c) => c.name === n));
  if (missing.length) throw new Error(`找不到案例：${missing.join("、")}`);
  return cases;
}
