import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import Anthropic from "@anthropic-ai/sdk";

const anthropicApiKey = defineSecret("ANTHROPIC_API_KEY");

interface TranscriptSegment {
  start_ms: number;
  end_ms: number;
  text: string;
}

interface AnalyzeMeetingRequest {
  segments: TranscriptSegment[];
  language?: string;
}

const outputSchema = {
  type: "object",
  properties: {
    summary: {
      type: "object",
      properties: {
        overview: { type: "string", description: "3-5句整體摘要" },
        key_points: { type: "array", items: { type: "string" } },
      },
      required: ["overview", "key_points"],
      additionalProperties: false,
    },
    todos: {
      type: "array",
      items: {
        type: "object",
        properties: {
          task: { type: "string" },
          owner: {
            type: ["string", "null"],
            description: "逐字稿中提到的負責人，無法判斷則 null",
          },
          due_date: {
            type: ["string", "null"],
            description: "逐字稿中提到的期限，無法判斷則 null",
          },
          source_timestamp_ms: {
            type: ["integer", "null"],
            description: "對應逐字稿片段的起始時間（必須是輸入片段中出現過的 start_ms 值）",
          },
        },
        required: ["task", "owner", "due_date", "source_timestamp_ms"],
        additionalProperties: false,
      },
    },
    structured_minutes: {
      type: "object",
      properties: {
        title: { type: "string" },
        attendees: {
          type: "array",
          items: { type: "string" },
          description: "從逐字稿中判斷出的與會者，無法判斷則回傳空陣列",
        },
        agenda_items: {
          type: "array",
          items: {
            type: "object",
            properties: {
              topic: { type: "string" },
              discussion: { type: "string" },
              decisions: { type: "array", items: { type: "string" } },
              source_timestamp_ms: {
                type: ["integer", "null"],
                description: "對應逐字稿片段的起始時間（必須是輸入片段中出現過的 start_ms 值）",
              },
            },
            required: ["topic", "discussion", "decisions", "source_timestamp_ms"],
            additionalProperties: false,
          },
        },
      },
      required: ["title", "attendees", "agenda_items"],
      additionalProperties: false,
    },
  },
  required: ["summary", "todos", "structured_minutes"],
  additionalProperties: false,
} as const;

const SYSTEM_PROMPT = `你是會議記錄整理助手。使用者會提供一份中文會議逐字稿，每一句都標有起始時間（毫秒）。
請根據逐字稿內容產出摘要、待辦事項清單、結構化會議紀錄。

規則：
- 所有輸出文字必須是繁體中文（zh-Hant），不可使用簡體字。
- todos 和 agenda_items 的 source_timestamp_ms 必須從輸入逐字稿中「已經出現過的」片段起始時間裡挑選，不可自行編造時間。
- 逐字稿可能包含轉錄錯誤或多人交叉發言導致的破碎片段，遇到讀不通的內容時盡量根據上下文推斷語意，不要編造逐字稿中沒有的資訊。
- attendees 和數值類欄位如果無法從逐字稿判斷，回傳空陣列或 null，不要猜測。`;

function buildTranscriptText(segments: TranscriptSegment[]): string {
  return segments.map((s) => `[${s.start_ms}] ${s.text.trim()}`).join("\n");
}

export const analyzeMeeting = onCall(
  { secrets: [anthropicApiKey], timeoutSeconds: 120, memory: "256MiB" },
  async (request) => {
    const data = request.data as AnalyzeMeetingRequest;

    if (!data?.segments || !Array.isArray(data.segments) || data.segments.length === 0) {
      throw new HttpsError("invalid-argument", "segments must be a non-empty array");
    }

    const client = new Anthropic({ apiKey: anthropicApiKey.value() });
    const transcriptText = buildTranscriptText(data.segments);

    const response = await client.messages.create({
      model: "claude-haiku-4-5",
      max_tokens: 4096,
      system: SYSTEM_PROMPT,
      messages: [{ role: "user", content: transcriptText }],
      output_config: {
        format: { type: "json_schema", schema: outputSchema },
      },
    });

    const textBlock = response.content.find(
      (block): block is Anthropic.TextBlock => block.type === "text"
    );
    if (!textBlock) {
      throw new HttpsError("internal", "Claude API did not return a text block");
    }

    return JSON.parse(textBlock.text);
  }
);
