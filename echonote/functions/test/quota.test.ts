import { test } from "node:test";
import assert from "node:assert/strict";
import { decideQuota, quotaDayKey } from "../src/quota";

test("allows calls below the limit and counts them", () => {
  assert.deepEqual(decideQuota(0, 50), { allowed: true, next: 1 });
  assert.deepEqual(decideQuota(49, 50), { allowed: true, next: 50 });
});

test("rejects at the limit without counting", () => {
  assert.deepEqual(decideQuota(50, 50), { allowed: false, next: 50 });
  assert.deepEqual(decideQuota(51, 50), { allowed: false, next: 51 });
});

test("the day key follows Asia/Taipei, not UTC", () => {
  // 2026-10-30 16:30 UTC is already 10-31 00:30 in Taipei.
  assert.equal(quotaDayKey(new Date("2026-10-30T16:30:00Z")), "2026-10-31");
  assert.equal(quotaDayKey(new Date("2026-10-30T15:59:59Z")), "2026-10-30");
});
