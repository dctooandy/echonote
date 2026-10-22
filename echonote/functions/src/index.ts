import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import Anthropic from "@anthropic-ai/sdk";
import {
  AnalyzeMeetingRequest,
  SYSTEM_PROMPT,
  buildUserMessage,
  outputSchema,
  validateRequest,
} from "./analyze";

const anthropicApiKey = defineSecret("ANTHROPIC_API_KEY");

export const analyzeMeeting = onCall(
  { secrets: [anthropicApiKey], timeoutSeconds: 120, memory: "256MiB" },
  async (request) => {
    const invalid = validateRequest(request.data);
    if (invalid) throw new HttpsError("invalid-argument", invalid);
    const data = request.data as AnalyzeMeetingRequest;

    const client = new Anthropic({ apiKey: anthropicApiKey.value() });

    let response;
    try {
      response = await client.messages.create({
        model: "claude-haiku-4-5",
        max_tokens: 4096,
        system: SYSTEM_PROMPT,
        messages: [{ role: "user", content: buildUserMessage(data) }],
        output_config: {
          format: { type: "json_schema", schema: outputSchema },
        },
      });
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
