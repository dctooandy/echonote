import { test } from "node:test";
import assert from "node:assert/strict";
import { HOMOPHONE_VARIANTS_MAX, findHomophones } from "../src/homophones";
import { buildUserMessage } from "../src/analyze";

const seg = (text: string) => ({ start_ms: 0, end_ms: 1000, text });

test("a same-sounding spelling of a glossary term is found", () => {
  const found = findHomophones(["小美", "網域"], ["小美說好。小眉,我來整理", "阿傑,新網欲我來申請"]);
  assert.deepEqual(found.get("小美"), ["小眉"]);
  assert.deepEqual(found.get("網域"), ["網欲"]);
});

test("the term spelled correctly is not a variant", () => {
  assert.equal(findHomophones(["小美"], ["小美說好,小美再說一次"]).size, 0);
});

test("a three-character name also matches by its given name", () => {
  const found = findHomophones(["蔡宜蓁"], ["出席的有蔡醫真。一針你下午做範例"]);
  assert.deepEqual(found.get("蔡宜蓁"), ["蔡醫真", "一針"]);
});

test("the given name inside the full name is not counted twice", () => {
  assert.deepEqual(findHomophones(["蔡宜蓁"], ["蔡醫真說好"]).get("蔡宜蓁"), ["蔡醫真"]);
});

test("one-character and non-Chinese terms are skipped", () => {
  assert.equal(findHomophones(["美", "Meetup", "A棟"], ["眉 Mid-Up A動"]).size, 0);
});

test("another glossary term is not a variant", () => {
  assert.equal(findHomophones(["小花", "小華"], ["小花說,小華說"]).size, 0);
});

test("spellings are ordered by count and capped", () => {
  const found = findHomophones(["小美"], ["小眉小眉小妹小枚小梅小梅小梅"]);
  assert.equal(found.get("小美")!.length, HOMOPHONE_VARIANTS_MAX);
  assert.deepEqual(found.get("小美"), ["小梅", "小眉", "小妹"]);
});

test("spellings across punctuation are not matched", () => {
  assert.equal(findHomophones(["小美"], ["小,眉"]).size, 0);
});

test("the glossary line notes the homophones", () => {
  const message = buildUserMessage({ segments: [seg("小眉,我來整理")], glossary: ["小美", "Meetup"] });
  assert.match(message, /<glossary>\n小美（逐字稿裡也寫成：小眉）\nMeetup\n<\/glossary>/);
});

test("without homophones the message is unchanged", () => {
  const message = buildUserMessage({ segments: [seg("小美,我來整理")], glossary: ["小美"] });
  assert.match(message, /<glossary>\n小美\n<\/glossary>/);
});
