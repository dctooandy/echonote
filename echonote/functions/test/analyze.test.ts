import { test } from "node:test";
import assert from "node:assert/strict";
import {
  PREVIOUS_MEETINGS_MAX,
  PREVIOUS_OVERVIEW_MAX_CHARS,
  PREVIOUS_DECISIONS_MAX,
  PREVIOUS_TODOS_MAX,
  PREVIOUS_ITEM_MAX_CHARS,
  PreviousMeeting,
  buildUserMessage,
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
