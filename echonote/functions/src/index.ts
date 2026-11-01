import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import Anthropic from "@anthropic-ai/sdk";
import { initializeApp } from "firebase-admin/app";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";
import { AnalyzeMeetingRequest, buildAnalysisParams, validateRequest } from "./analyze";
import { DAILY_LIMIT, QUOTA_RETENTION_DAYS, decideQuota, quotaDayKey } from "./quota";

initializeApp();

const anthropicApiKey = defineSecret("ANTHROPIC_API_KEY");

/**
 * Counts one call against today's global quota in a transaction, so
 * concurrent calls can't both slip under the limit. Returns false when the
 * day is used up. A call that later fails at Claude is not refunded
 * (decision 11).
 */
async function consumeDailyQuota(now: Date): Promise<boolean> {
  const db = getFirestore();
  const ref = db.collection("usage_daily").doc(quotaDayKey(now));
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = (snap.get("count") as number | undefined) ?? 0;
    const { allowed, next } = decideQuota(current, DAILY_LIMIT);
    if (!allowed) return false;
    tx.set(
      ref,
      {
        count: next,
        updatedAt: FieldValue.serverTimestamp(),
        expireAt: Timestamp.fromMillis(now.getTime() + QUOTA_RETENTION_DAYS * 24 * 60 * 60 * 1000),
      },
      { merge: true }
    );
    return true;
  });
}

export const analyzeMeeting = onCall(
  {
    secrets: [anthropicApiKey],
    timeoutSeconds: 120,
    memory: "256MiB",
    maxInstances: 3,
    // Reject calls that don't come from the app (spec feature-app-check).
    enforceAppCheck: true,
  },
  async (request) => {
    const invalid = validateRequest(request.data);
    if (invalid) throw new HttpsError("invalid-argument", invalid);
    const data = request.data as AnalyzeMeetingRequest;

    // After validation, so malformed calls don't use up the day (decision 8).
    let allowed;
    try {
      allowed = await consumeDailyQuota(new Date());
    } catch (err) {
      // Fail closed: without a working counter there is no limit (decision 5).
      console.error("Daily quota check failed", err);
      throw new HttpsError("unavailable", "暫時無法確認今天的分析次數，請稍後再試");
    }
    if (!allowed) {
      throw new HttpsError("resource-exhausted", "今天的分析次數已用完，明天再試", {
        reason: "daily_quota",
      });
    }

    const client = new Anthropic({ apiKey: anthropicApiKey.value() });

    let response;
    try {
      response = await client.messages.create(buildAnalysisParams(data));
    } catch (err) {
      console.error("Anthropic API call failed", err);
      if (err instanceof Anthropic.AuthenticationError) {
        throw new HttpsError("internal", "Claude API 金鑰無效或已過期，請檢查 Secret Manager 設定");
      }
      if (err instanceof Anthropic.RateLimitError) {
        throw new HttpsError("resource-exhausted", "Claude API 額度已達上限，請稍後再試");
      }
      if (err instanceof Anthropic.APIError) {
        throw new HttpsError("internal", `Claude API 呼叫失敗（狀態碼 ${err.status}）：${err.message}`);
      }
      throw new HttpsError(
        "internal",
        `Claude API 呼叫失敗：${err instanceof Error ? err.message : String(err)}`
      );
    }

    const textBlock = response.content.find(
      (block): block is Anthropic.TextBlock => block.type === "text"
    );
    if (!textBlock) {
      throw new HttpsError("internal", "Claude API 沒有回傳文字內容");
    }

    try {
      return JSON.parse(textBlock.text);
    } catch (err) {
      console.error("Failed to parse Claude response as JSON", textBlock.text);
      throw new HttpsError("internal", "Claude API 回傳的內容不是合法 JSON，可能是輸出被截斷");
    }
  }
);
