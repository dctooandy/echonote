import { test } from "node:test";
import assert from "node:assert/strict";
import { AnalyzeMeetingRequest } from "../src/analyze";
import { CheckResult, Expect, fieldText, gradeOutput } from "../eval/grade";

const request: AnalyzeMeetingRequest = {
  segments: [
    { start_ms: 0, end_ms: 1000, text: "a" },
    { start_ms: 1000, end_ms: 2000, text: "b" },
    { start_ms: 2000, end_ms: 3000, text: "c" },
  ],
  previous_meetings: [
    {
      title: "週會",
      date: "2026-10-24",
      overview: "o",
      decisions: ["11 月 15 上線", "主色用藍色"],
      todos: [
        { task: "寫首頁文案", owner: "小明", done: false },
        { task: "申請新網域", owner: "阿傑", done: false },
      ],
    },
  ],
};

/** A well-formed output; tests override the parts they care about. */
const output = (over: Record<string, unknown> = {}) => ({
  summary: { overview: "上線延到 11月22日，主色改成綠色。", key_points: ["預算上限 15 萬"] },
  todos: [{ task: "寫 FAQ 草稿", owner: "小華", due_date: "下週", source_segment_index: 2 }],
  structured_minutes: {
    title: "官網改版週會",
    attendees: ["小明", "小華"],
    agenda_items: [{ topic: "時程", discussion: "延期", decisions: ["11/22 上線"], source_segment_index: 0 }],
  },
  highlight_contexts: [{ note_index: 0, context: "討論預算" }],
  follow_up: {
    todo_progress: [
      { previous_todo_index: 0, status: "done", note: "已完成", source_segment_index: 1 },
      { previous_todo_index: 1, status: "not_mentioned", note: "沒提到", source_segment_index: null },
    ],
    decision_changes: [
      { change: "revised", previous_decision: "11 月 15 上線", current: "11/22", source_segment_index: 0 },
      { change: "reversed", previous_decision: "主色用藍色", current: "綠色", source_segment_index: 1 },
    ],
    new_topics: ["FAQ 頁面", "預算"],
  },
  ...over,
});

const byKey = (results: CheckResult[], key: string) => {
  const found = results.find((r) => r.key === key);
  assert.ok(found, `no check ${key}`);
  return found;
};

test("a good output passes every universal check", () => {
  const results = gradeOutput(output(), request, {}, "end_turn");
  assert.deepEqual(
    results.filter((r) => !r.pass),
    []
  );
  assert.deepEqual(
    results.map((r) => r.key),
    ["通用:schema", "通用:未截斷", "通用:逐字稿序號", "通用:上次待辦序號", "通用:簡體字"]
  );
});

test("universal checks catch missing fields, truncation, bad indices and simplified characters", () => {
  assert.equal(byKey(gradeOutput(null, request, {}, null), "通用:schema").pass, false);
  const noFollowUp = gradeOutput(output({ follow_up: undefined }), request, {}, null);
  assert.match(byKey(noFollowUp, "通用:schema").detail ?? "", /follow_up\.todo_progress/);

  assert.equal(byKey(gradeOutput(output(), request, {}, "max_tokens"), "通用:未截斷").pass, false);

  const badIndex = output({ todos: [{ task: "x", owner: null, due_date: null, source_segment_index: 3 }] });
  assert.match(byKey(gradeOutput(badIndex, request, {}, null), "通用:逐字稿序號").detail ?? "", /3/);

  const badTodo = output({
    follow_up: { todo_progress: [{ previous_todo_index: 2, status: "done", note: "", source_segment_index: null }], decision_changes: [], new_topics: [] },
  });
  assert.equal(byKey(gradeOutput(badTodo, request, {}, null), "通用:上次待辦序號").pass, false);
  // Without previous meetings, any todo_progress entry is out of range.
  assert.equal(byKey(gradeOutput(output(), { segments: request.segments }, {}, null), "通用:上次待辦序號").pass, false);

  const simplified = output({ summary: { overview: "这次会议", key_points: [] } });
  assert.match(byKey(gradeOutput(simplified, request, {}, null), "通用:簡體字").detail ?? "", /这/);
});

test("fieldText reads the right parts", () => {
  assert.match(fieldText(output(), "summary"), /11月22日[\s\S]*預算上限/);
  assert.match(fieldText(output(), "todos"), /FAQ 草稿 小華 下週/);
  assert.match(fieldText(output(), "structured_minutes"), /官網改版週會[\s\S]*小華[\s\S]*11\/22 上線/);
  assert.match(fieldText(output(), "follow_up"), /主色用藍色[\s\S]*FAQ 頁面/);
  assert.equal(fieldText(output(), "highlight_contexts"), "討論預算");
  assert.equal(fieldText(null, "summary"), "");
});

test("must_include and must_not_include ignore spaces and case", () => {
  const expect: Expect = {
    must_include: [
      { id: "延期", in: ["summary"], any_of: ["11 月 22"] },
      { id: "faq", in: ["todos"], any_of: ["faq"] },
      { id: "沒有", in: ["summary"], any_of: ["花蓮"] },
    ],
    must_not_include: [
      { id: "花蓮", in: ["summary", "todos", "structured_minutes"], terms: ["花蓮", "寵物"] },
      { id: "綠色", in: ["summary"], terms: ["綠色"] },
    ],
  };
  const results = gradeOutput(output(), request, expect, null);
  assert.equal(byKey(results, "必須出現:延期").pass, true);
  assert.equal(byKey(results, "必須出現:faq").pass, true);
  assert.equal(byKey(results, "必須出現:沒有").pass, false);
  assert.equal(byKey(results, "不可出現:花蓮").pass, true);
  assert.match(byKey(results, "不可出現:綠色").detail ?? "", /綠色/);
});

test("todos match the task and, when given, the owner", () => {
  const results = gradeOutput(
    output(),
    request,
    {
      todos: [
        { id: "faq", any_of: ["FAQ"], owner_any_of: ["小華"] },
        { id: "faq 錯人", any_of: ["FAQ"], owner_any_of: ["阿傑"] },
        { id: "沒有", any_of: ["遊覽車"] },
      ],
    },
    null
  );
  assert.equal(byKey(results, "待辦:faq").pass, true);
  assert.match(byKey(results, "待辦:faq 錯人").detail ?? "", /負責人是 小華/);
  assert.match(byKey(results, "待辦:沒有").detail ?? "", /沒有待辦/);
});

test("owner_none_of fails only when the owner is one of the names", () => {
  const results = gradeOutput(
    output(),
    request,
    {
      todos: [
        { id: "不是阿傑", any_of: ["FAQ"], owner_none_of: ["阿傑"] },
        { id: "不是小華", any_of: ["FAQ"], owner_none_of: ["小華"] },
      ],
    },
    null
  );
  assert.equal(byKey(results, "待辦:不是阿傑").pass, true);
  assert.match(byKey(results, "待辦:不是小華").detail ?? "", /不可是 小華/);
});

test("todo_progress, decision_changes, new_topics and highlight count", () => {
  const expect: Expect = {
    todo_progress: [
      { id: "文案", previous_todo_index: 0, status: "done" },
      { id: "網域", previous_todo_index: 1, status: "in_progress" },
      { id: "不存在", previous_todo_index: 5, status: "done" },
    ],
    decision_changes: [
      { id: "主色", previous_any_of: ["藍"], change: "reversed" },
      { id: "上線", previous_any_of: ["15"], change: "reversed" },
      { id: "中文版", previous_any_of: ["中文"], change: "continued" },
    ],
    new_topics: [
      { id: "faq", any_of: ["FAQ", "常見問題"] },
      { id: "預算", any_of: ["預算"] },
      { id: "沒有", any_of: ["英文版"] },
    ],
    highlight_contexts: { count: 3 },
  };
  const results = gradeOutput(output(), request, expect, null);
  assert.equal(byKey(results, "上次待辦:文案").pass, true);
  assert.match(byKey(results, "上次待辦:網域").detail ?? "", /not_mentioned/);
  assert.match(byKey(results, "上次待辦:不存在").detail ?? "", /沒有列出/);
  assert.equal(byKey(results, "決議變化:主色").pass, true);
  assert.match(byKey(results, "決議變化:上線").detail ?? "", /判成 revised/);
  assert.match(byKey(results, "決議變化:中文版").detail ?? "", /沒有列出/);
  assert.equal(byKey(results, "新主題:faq").pass, true);
  assert.equal(byKey(results, "新主題:預算").pass, true);
  assert.equal(byKey(results, "新主題:沒有").pass, false);
  assert.match(byKey(results, "重點說明:筆數").detail ?? "", /1 筆，預期 3 筆/);
});
