"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.analyzeMeeting = void 0;
const https_1 = require("firebase-functions/v2/https");
const params_1 = require("firebase-functions/params");
const sdk_1 = __importDefault(require("@anthropic-ai/sdk"));
const anthropicApiKey = (0, params_1.defineSecret)("ANTHROPIC_API_KEY");
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
                    source_segment_index: {
                        type: ["integer", "null"],
                        description: "對應逐字稿片段的序號（輸入每句前面的 [數字]，從 0 開始，不是時間）",
                    },
                },
                required: ["task", "owner", "due_date", "source_segment_index"],
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
                            source_segment_index: {
                                type: ["integer", "null"],
                                description: "對應逐字稿片段的序號（輸入每句前面的 [數字]，從 0 開始，不是時間）",
                            },
                        },
                        required: ["topic", "discussion", "decisions", "source_segment_index"],
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
};
const SYSTEM_PROMPT = `你是會議記錄整理助手。使用者會提供一份中文會議逐字稿，每一句前面標有這句在逐字稿中的序號（從 0 開始，例如 [0]、[1]、[2]...），序號不是時間。
請根據逐字稿內容產出摘要、待辦事項清單、結構化會議紀錄。

規則：
- 所有輸出文字必須是繁體中文（zh-Hant），不可使用簡體字。
- todos 和 agenda_items 的 source_segment_index 必須填「輸入逐字稿中實際出現過的序號」，該序號來自你要引用那句話前面的 [數字]，不可超出範圍、不可自行編造。
- 逐字稿可能包含轉錄錯誤或多人交叉發言導致的破碎片段，遇到讀不通的內容時盡量根據上下文推斷語意，不要編造逐字稿中沒有的資訊。
- attendees 和數值類欄位如果無法從逐字稿判斷，回傳空陣列或 null，不要猜測。`;
function buildTranscriptText(segments) {
    return segments.map((s, index) => `[${index}] ${s.text.trim()}`).join("\n");
}
exports.analyzeMeeting = (0, https_1.onCall)({ secrets: [anthropicApiKey], timeoutSeconds: 120, memory: "256MiB" }, async (request) => {
    const data = request.data;
    if (!data?.segments || !Array.isArray(data.segments) || data.segments.length === 0) {
        throw new https_1.HttpsError("invalid-argument", "segments must be a non-empty array");
    }
    const client = new sdk_1.default({ apiKey: anthropicApiKey.value() });
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
    const textBlock = response.content.find((block) => block.type === "text");
    if (!textBlock) {
        throw new https_1.HttpsError("internal", "Claude API did not return a text block");
    }
    return JSON.parse(textBlock.text);
});
//# sourceMappingURL=index.js.map