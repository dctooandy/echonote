import { test } from "node:test";
import assert from "node:assert/strict";
import {
  PREVIOUS_MEETINGS_MAX,
  PREVIOUS_OVERVIEW_MAX_CHARS,
  PREVIOUS_DECISIONS_MAX,
  PREVIOUS_TODOS_MAX,
  PREVIOUS_ITEM_MAX_CHARS,
  PreviousMeeting,
  SYSTEM_PROMPT,
  buildAnalysisParams,
  buildUserMessage,
  promptHash,
  promptVersion,
  outputSchema,
  validateRequest,
} from "../src/analyze";

const segments = [
  { start_ms: 0, end_ms: 1000, text: "開始" },
  { start_ms: 1000, end_ms: 2000, text: "報告上週進度" },
];

const meeting = (over: Partial<PreviousMeeting> = {}): PreviousMeeting => ({
  title: "週會",
  date: "2026-10-24",
  overview: "討論上線時程",
  decisions: ["11 月上線"],
  todos: [{ task: "寫測試", owner: "小明", done: false }],
  ...over,
});

test("previous_meetings is optional and accepts valid entries", () => {
  assert.equal(validateRequest({ segments }), null);
  assert.equal(validateRequest({ segments, previous_meetings: [] }), null);
  assert.equal(validateRequest({ segments, previous_meetings: [meeting(), meeting({ todos: [] })] }), null);
  assert.equal(
    validateRequest({ segments, previous_meetings: [meeting({ todos: [{ task: "x", owner: null, done: true }] })] }),
    null
  );
});

test(`previous_meetings allows at most ${PREVIOUS_MEETINGS_MAX} entries`, () => {
  const four = Array.from({ length: PREVIOUS_MEETINGS_MAX + 1 }, () => meeting());
  assert.match(validateRequest({ segments, previous_meetings: four }) ?? "", /at most/);
});

test("previous_meetings rejects wrong types", () => {
  const bad: unknown[] = [
    "not an array",
    [null],
    [{ ...meeting(), title: 1 }],
    [{ ...meeting(), date: "10/24" }],
    [{ ...meeting(), overview: null }],
    [{ ...meeting(), decisions: "11 月上線" }],
    [{ ...meeting(), decisions: [1] }],
    [{ ...meeting(), todos: [{ task: "x", owner: 1, done: false }] }],
    [{ ...meeting(), todos: [{ task: "x", owner: null, done: "no" }] }],
    [{ ...meeting(), todos: [{ owner: null, done: false }] }],
  ];
  for (const previous_meetings of bad) {
    assert.notEqual(validateRequest({ segments, previous_meetings }), null, JSON.stringify(previous_meetings));
  }
});

test("previous_meetings enforces the length limits (code points, like the app)", () => {
  const long = (n: number) => "字".repeat(n);
  assert.equal(validateRequest({ segments, previous_meetings: [meeting({ overview: long(PREVIOUS_OVERVIEW_MAX_CHARS) })] }), null);
  const tooLong: Partial<PreviousMeeting>[] = [
    { overview: long(PREVIOUS_OVERVIEW_MAX_CHARS + 1) },
    { title: long(PREVIOUS_ITEM_MAX_CHARS + 1) },
    { decisions: [long(PREVIOUS_ITEM_MAX_CHARS + 1)] },
    { decisions: Array.from({ length: PREVIOUS_DECISIONS_MAX + 1 }, () => "d") },
    { todos: Array.from({ length: PREVIOUS_TODOS_MAX + 1 }, () => ({ task: "t", owner: null, done: false })) },
    { todos: [{ task: long(PREVIOUS_ITEM_MAX_CHARS + 1), owner: null, done: false }] },
    { todos: [{ task: "t", owner: long(PREVIOUS_ITEM_MAX_CHARS + 1), done: false }] },
  ];
  for (const over of tooLong) {
    assert.notEqual(validateRequest({ segments, previous_meetings: [meeting(over)] }), null, JSON.stringify(Object.keys(over)));
  }
});

test("without previous meetings the message has no <previous_meetings> section", () => {
  assert.doesNotMatch(buildUserMessage({ segments }), /<previous_meetings>/);
  assert.doesNotMatch(buildUserMessage({ segments, previous_meetings: [] }), /<previous_meetings>/);
});

test("previous meetings are numbered and only the latest one's todos are indexed", () => {
  const message = buildUserMessage({
    segments,
    previous_meetings: [
      meeting({ title: "第一次", todos: [{ task: "舊待辦", owner: null, done: true }] }),
      meeting({
        title: "第二次",
        todos: [
          { task: "寫測試", owner: "小明", done: false },
          { task: "訂場地", owner: null, done: true },
        ],
      }),
    ],
  });
  const section = message.match(/<previous_meetings>\n([\s\S]*)\n<\/previous_meetings>/)?.[1] ?? "";
  assert.match(section, /前一場 1（2026-10-24）：第一次/);
  assert.match(section, /前一場 2（2026-10-24）：第二次/);
  assert.match(section, /\[上次待辦 0\] 寫測試（負責人：小明；未完成）/);
  assert.match(section, /\[上次待辦 1\] 訂場地（已完成）/);
  // Older meetings are background only: their todos carry no index.
  assert.match(section, /- 舊待辦（已完成）/);
  assert.doesNotMatch(section, /\[上次待辦 \d+\] 舊待辦/);
  assert.match(section, /決議：\n- 11 月上線/);
  // The transcript still comes first.
  assert.ok(message.indexOf("<transcript>") < message.indexOf("<previous_meetings>"));
});

test("follow_up is a required part of the output", () => {
  assert.ok((outputSchema.required as readonly string[]).includes("follow_up"));
  const followUp = outputSchema.properties.follow_up;
  assert.deepEqual([...followUp.required], ["todo_progress", "decision_changes", "new_topics"]);
  assert.deepEqual(
    [...followUp.properties.todo_progress.items.properties.status.enum],
    ["done", "in_progress", "not_mentioned"]
  );
  assert.deepEqual(
    [...followUp.properties.decision_changes.items.properties.change.enum],
    ["continued", "revised", "reversed"]
  );
});

test("analysis params match what production has always sent", () => {
  const params = buildAnalysisParams({ segments });
  assert.equal(params.model, "claude-haiku-4-5");
  assert.equal(params.max_tokens, 6000);
  assert.equal(params.system, SYSTEM_PROMPT);
  assert.deepEqual(params.messages, [{ role: "user", content: buildUserMessage({ segments }) }]);
  assert.deepEqual(params.output_config, { format: { type: "json_schema", schema: outputSchema } });
});

test("the eval set can swap the model, and nothing else", () => {
  const params = buildAnalysisParams({ segments }, { model: "claude-haiku-5-5" });
  assert.equal(params.model, "claude-haiku-5-5");
  assert.deepEqual({ ...params, model: "x" }, { ...buildAnalysisParams({ segments }), model: "x" });
});

test("the eval set can set effort, thinking and max tokens; unset, nothing extra is sent", () => {
  const plain = buildAnalysisParams({ segments }, { model: "claude-haiku-5-5" });
  assert.equal("thinking" in plain, false);
  assert.equal("effort" in plain.output_config, false);

  const tuned = buildAnalysisParams(
    { segments },
    { model: "claude-haiku-5-5", effort: "low", thinking: "adaptive", maxTokens: 16000 }
  );
  assert.equal(tuned.max_tokens, 16000);
  assert.deepEqual(tuned.thinking, { type: "adaptive" });
  assert.deepEqual(tuned.output_config, {
    format: { type: "json_schema", schema: outputSchema },
    effort: "low",
  });
});

test("Haiku 4.5 rejects effort and adaptive thinking before any call", () => {
  assert.throws(() => buildAnalysisParams({ segments }, { effort: "low" }), /不支援 effort/);
  assert.throws(() => buildAnalysisParams({ segments }, { thinking: "adaptive" }), /不支援 effort/);
  assert.equal(buildAnalysisParams({ segments }, { thinking: "disabled" }).thinking?.type, "disabled");
});

test("prompt version is a stable short hash", () => {
  assert.match(promptVersion(), /^[0-9a-f]{8}$/);
  assert.equal(promptVersion(), promptHash(SYSTEM_PROMPT, outputSchema));
  assert.notEqual(promptHash(SYSTEM_PROMPT + "。", outputSchema), promptVersion());
  assert.notEqual(promptHash(SYSTEM_PROMPT, { ...outputSchema, required: [] }), promptVersion());
});

test("user notes are sent as the user's private notes, not as highlights of the meeting", () => {
  const message = buildUserMessage({
    segments,
    highlights: [
      { note_index: 0, segment_index: 1, text: " 要問含不含稅 " },
      { note_index: 1, segment_index: 0, text: null },
    ],
  });
  const section = message.match(/<user_notes>\n([\s\S]*)\n<\/user_notes>/)?.[1] ?? "";
  assert.match(section, /^\[筆記 0\] 標在逐字稿 \[1\]：要問含不含稅$/m);
  assert.match(section, /^\[筆記 1\] 標在逐字稿 \[0\]：（★ 標記，沒有文字）$/m);
  assert.doesNotMatch(message, /user_highlights|\[重點/);
  assert.doesNotMatch(buildUserMessage({ segments, highlights: [] }), /<user_notes>/);
});

test("the prompt keeps note text out of the output and asks for one context per note", () => {
  assert.doesNotMatch(SYSTEM_PROMPT, /user_highlights/);
  assert.match(SYSTEM_PROMPT, /不是會議發言/);
  // The leak case: a note that reads like an add-on to a todo.
  assert.match(SYSTEM_PROMPT, /看起來像.*補充時也一樣/);
  // key_points cover the transcript at the note, not the note.
  assert.match(SYSTEM_PROMPT, /逐字稿那句的內容，不是筆記文字/);
  assert.match(SYSTEM_PROMPT, /筆數必須等於筆記數/);
  const contexts = outputSchema.properties.highlight_contexts;
  assert.match(contexts.description, /<user_notes>/);
  assert.match(contexts.items.properties.note_index.description, /<user_notes>/);
});
