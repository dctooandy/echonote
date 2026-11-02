// Grades one analysis output against a case's expect.json (spec
// feature-analysis-eval-set). Pure: no API calls, so every check is unit
// tested with hand-written outputs.

import { AnalyzeMeetingRequest } from "../src/analyze";

/** Which part of the output a text check looks in. */
export type FieldKey = "summary" | "todos" | "structured_minutes" | "follow_up" | "highlight_contexts";

export interface Expect {
  description?: string;
  must_include?: { id: string; in: FieldKey[]; any_of: string[] }[];
  must_not_include?: { id: string; in: FieldKey[]; terms: string[] }[];
  todos?: { id: string; any_of: string[]; owner_any_of?: string[]; owner_none_of?: string[] }[];
  todo_progress?: { id: string; previous_todo_index: number; status: "done" | "in_progress" | "not_mentioned" }[];
  decision_changes?: { id: string; previous_any_of: string[]; change: "continued" | "revised" | "reversed" }[];
  new_topics?: { id: string; any_of: string[] }[];
  highlight_contexts?: { count: number };
}

export interface CheckResult {
  /** Stable across runs, so reports can line results up: `<kind>:<id>`. */
  key: string;
  pass: boolean;
  /** Why it failed, in the report's words. */
  detail?: string;
}

/**
 * Characters that only exist in simplified Chinese. Kept short on purpose
 * (spec decision 11): 后、台 and the like are valid traditional too.
 */
/** More todos than this from one meeting probably means remarks were listed too. */
export const TODOS_MAX = 15;

export const SIMPLIFIED_ONLY = [..."这们会说时国为来对进过还发经与两样实现问题议决动项预"];

// The output is model JSON; read it loosely and let the schema check
// report what's missing.
/* eslint-disable @typescript-eslint/no-explicit-any */
type Json = any;

const list = (value: Json): Json[] => (Array.isArray(value) ? value : []);
const str = (value: Json): string => (typeof value === "string" ? value : "");

/** All the text of one field, joined. */
export function fieldText(output: Json, field: FieldKey): string {
  switch (field) {
    case "summary":
      return [str(output?.summary?.overview), ...list(output?.summary?.key_points).map(str)].join("\n");
    case "todos":
      return list(output?.todos)
        .map((t) => [str(t?.task), str(t?.owner), str(t?.due_date)].join(" "))
        .join("\n");
    case "structured_minutes": {
      const m = output?.structured_minutes;
      return [
        str(m?.title),
        ...list(m?.attendees).map(str),
        ...list(m?.agenda_items).map((a) => [str(a?.topic), str(a?.discussion), ...list(a?.decisions).map(str)].join(" ")),
      ].join("\n");
    }
    case "follow_up": {
      const f = output?.follow_up;
      return [
        ...list(f?.todo_progress).map((t) => str(t?.note)),
        ...list(f?.decision_changes).map((d) => [str(d?.previous_decision), str(d?.current)].join(" ")),
        ...list(f?.new_topics).map(str),
      ].join("\n");
    }
    case "highlight_contexts":
      return list(output?.highlight_contexts).map((h) => str(h?.context)).join("\n");
  }
}

/** Case- and space-insensitive, so "11 月 22" matches "11月22". */
const normalize = (text: string) => text.toLowerCase().replace(/\s+/g, "");
const contains = (text: string, term: string) => normalize(text).includes(normalize(term));
const containsAny = (text: string, terms: string[]) => terms.some((t) => contains(text, t));

function schemaProblems(output: Json): string[] {
  const problems: string[] = [];
  const need = (ok: boolean, what: string) => {
    if (!ok) problems.push(what);
  };
  need(typeof output === "object" && output !== null, "輸出不是物件");
  need(typeof output?.summary?.overview === "string", "summary.overview");
  need(Array.isArray(output?.summary?.key_points), "summary.key_points");
  need(Array.isArray(output?.todos), "todos");
  need(typeof output?.structured_minutes?.title === "string", "structured_minutes.title");
  need(Array.isArray(output?.structured_minutes?.attendees), "structured_minutes.attendees");
  need(Array.isArray(output?.structured_minutes?.agenda_items), "structured_minutes.agenda_items");
  need(Array.isArray(output?.highlight_contexts), "highlight_contexts");
  need(Array.isArray(output?.follow_up?.todo_progress), "follow_up.todo_progress");
  need(Array.isArray(output?.follow_up?.decision_changes), "follow_up.decision_changes");
  need(Array.isArray(output?.follow_up?.new_topics), "follow_up.new_topics");
  return problems;
}

/** Checks every case gets, whatever its expect.json says. */
function universalChecks(output: Json, request: AnalyzeMeetingRequest, stopReason: string | null): CheckResult[] {
  const problems = schemaProblems(output);
  const results: CheckResult[] = [
    { key: "通用:schema", pass: problems.length === 0, detail: problems.length ? `缺少 ${problems.join("、")}` : undefined },
    {
      key: "通用:未截斷",
      pass: stopReason !== "max_tokens",
      detail: stopReason === "max_tokens" ? "輸出達到 max_tokens 被截斷" : undefined,
    },
  ];

  const segments = request.segments.length;
  const indices = [
    ...list(output?.todos).map((t) => t?.source_segment_index),
    ...list(output?.structured_minutes?.agenda_items).map((a) => a?.source_segment_index),
    ...list(output?.follow_up?.todo_progress).map((t) => t?.source_segment_index),
    ...list(output?.follow_up?.decision_changes).map((d) => d?.source_segment_index),
  ];
  const badSegments = indices.filter((i) => i !== null && !(Number.isInteger(i) && i >= 0 && i < segments));
  results.push({
    key: "通用:逐字稿序號",
    pass: badSegments.length === 0,
    detail: badSegments.length ? `超出 0～${segments - 1}：${badSegments.join("、")}` : undefined,
  });

  const previous = request.previous_meetings ?? [];
  const previousTodos = previous.length ? previous[previous.length - 1].todos.length : 0;
  const badTodos = list(output?.follow_up?.todo_progress)
    .map((t) => t?.previous_todo_index)
    .filter((i) => !(Number.isInteger(i) && i >= 0 && i < previousTodos));
  results.push({
    key: "通用:上次待辦序號",
    pass: badTodos.length === 0,
    detail: badTodos.length ? `上次只有 ${previousTodos} 筆待辦：${badTodos.join("、")}` : undefined,
  });

  // Guards against listing every remark as a todo (spec fix-todo-recall,
  // decision 3); the longest case so far has 13.
  const todoCount = list(output?.todos).length;
  results.push({
    key: "通用:待辦筆數",
    pass: todoCount <= TODOS_MAX,
    detail: todoCount > TODOS_MAX ? `${todoCount} 筆，超過 ${TODOS_MAX} 筆` : undefined,
  });

  const text = JSON.stringify(output ?? "");
  const simplified = SIMPLIFIED_ONLY.filter((c) => text.includes(c));
  results.push({
    key: "通用:簡體字",
    pass: simplified.length === 0,
    detail: simplified.length ? `出現 ${simplified.join("")}` : undefined,
  });
  return results;
}

/**
 * Grades [output] (the parsed model JSON, or null when it didn't parse)
 * for the case's [request] and [expect]. [stopReason] is the API's.
 */
export function gradeOutput(
  output: Json,
  request: AnalyzeMeetingRequest,
  expect: Expect,
  stopReason: string | null
): CheckResult[] {
  const results = universalChecks(output, request, stopReason);
  const textOf = (fields: FieldKey[]) => fields.map((f) => fieldText(output, f)).join("\n");

  for (const c of expect.must_include ?? []) {
    const pass = containsAny(textOf(c.in), c.any_of);
    results.push({ key: `必須出現:${c.id}`, pass, detail: pass ? undefined : `${c.in.join("、")} 裡沒有 ${c.any_of.join("／")}` });
  }

  for (const c of expect.must_not_include ?? []) {
    const found = c.terms.filter((t) => contains(textOf(c.in), t));
    results.push({
      key: `不可出現:${c.id}`,
      pass: found.length === 0,
      detail: found.length ? `${c.in.join("、")} 出現 ${found.join("、")}` : undefined,
    });
  }

  const todos = list(output?.todos);
  for (const c of expect.todos ?? []) {
    const matches = todos.filter((t) => containsAny(str(t?.task), c.any_of));
    const withOwner = matches.filter(
      (t) =>
        (!c.owner_any_of || containsAny(str(t?.owner), c.owner_any_of)) &&
        !(c.owner_none_of && containsAny(str(t?.owner), c.owner_none_of))
    );
    const expected = [
      c.owner_any_of ? `預期 ${c.owner_any_of.join("／")}` : "",
      c.owner_none_of ? `不可是 ${c.owner_none_of.join("／")}` : "",
    ].filter(Boolean).join("，");
    let detail: string | undefined;
    if (matches.length === 0) detail = `沒有待辦包含 ${c.any_of.join("／")}`;
    else if (withOwner.length === 0) detail = `負責人是 ${matches.map((t) => str(t?.owner) || "（空）").join("、")}，${expected}`;
    results.push({ key: `待辦:${c.id}`, pass: withOwner.length > 0, detail });
  }

  const progress = list(output?.follow_up?.todo_progress);
  for (const c of expect.todo_progress ?? []) {
    const entry = progress.find((p) => p?.previous_todo_index === c.previous_todo_index);
    const pass = entry?.status === c.status;
    results.push({
      key: `上次待辦:${c.id}`,
      pass,
      detail: pass ? undefined : entry ? `判成 ${str(entry.status)}，預期 ${c.status}` : `沒有列出上次待辦 ${c.previous_todo_index}`,
    });
  }

  const changes = list(output?.follow_up?.decision_changes);
  for (const c of expect.decision_changes ?? []) {
    const matches = changes.filter((d) => containsAny(str(d?.previous_decision), c.previous_any_of));
    const pass = matches.some((d) => d?.change === c.change);
    results.push({
      key: `決議變化:${c.id}`,
      pass,
      detail: pass
        ? undefined
        : matches.length
          ? `判成 ${matches.map((d) => str(d?.change)).join("、")}，預期 ${c.change}`
          : `沒有列出包含 ${c.previous_any_of.join("／")} 的決議`,
    });
  }

  const topics = list(output?.follow_up?.new_topics).map(str);
  for (const c of expect.new_topics ?? []) {
    const pass = topics.some((t) => containsAny(t, c.any_of));
    results.push({ key: `新主題:${c.id}`, pass, detail: pass ? undefined : `新主題是 ${topics.join("、") || "（無）"}` });
  }

  if (expect.highlight_contexts) {
    const count = list(output?.highlight_contexts).length;
    const pass = count === expect.highlight_contexts.count;
    results.push({
      key: "重點說明:筆數",
      pass,
      detail: pass ? undefined : `${count} 筆，預期 ${expect.highlight_contexts.count} 筆`,
    });
  }

  return results;
}
