// Pure request handling for analyzeMeeting: validation, prompt and schema.
// Kept free of Firebase and Anthropic imports so it can be exercised
// directly (see the spec's T7 notes).

export interface TranscriptSegment {
  start_ms: number;
  end_ms: number;
  text: string;
}

/** A user note, already resolved by the app to the segment it falls in. */
export interface Highlight {
  note_index: number;
  segment_index: number;
  /** null for a ★ with no text. */
  text: string | null;
}

export interface AnalyzeMeetingRequest {
  segments: TranscriptSegment[];
  language?: string;
  glossary?: string[];
  highlights?: Highlight[];
}

export const GLOSSARY_MAX_TERMS = 200;
export const GLOSSARY_TERM_MAX_CHARS = 20;

const isIndex = (value: unknown): value is number => Number.isInteger(value) && (value as number) >= 0;

/** Returns why [data] is not a valid request, or null when it is. */
export function validateRequest(data: unknown): string | null {
  const req = data as Partial<AnalyzeMeetingRequest> | null | undefined;
  if (!req?.segments || !Array.isArray(req.segments) || req.segments.length === 0) {
    return "segments must be a non-empty array";
  }

  if (req.glossary != null) {
    if (!Array.isArray(req.glossary) || req.glossary.some((t) => typeof t !== "string")) {
      return "glossary must be an array of strings";
    }
    if (req.glossary.length > GLOSSARY_MAX_TERMS) {
      return `glossary must have at most ${GLOSSARY_MAX_TERMS} terms`;
    }
    // Code points, so a CJK character counts as one (matches the app).
    const tooLong = req.glossary.find((t) => [...t.trim()].length > GLOSSARY_TERM_MAX_CHARS);
    if (tooLong !== undefined) {
      return `glossary term exceeds ${GLOSSARY_TERM_MAX_CHARS} characters: ${tooLong}`;
    }
  }

  if (req.highlights != null) {
    if (!Array.isArray(req.highlights)) return "highlights must be an array";
    const seen = new Set<number>();
    for (const h of req.highlights) {
      if (!isIndex(h?.note_index)) return "highlights[].note_index must be a non-negative integer";
      if (seen.has(h.note_index)) return `highlights[].note_index ${h.note_index} is duplicated`;
      seen.add(h.note_index);
      if (!isIndex(h.segment_index) || h.segment_index >= req.segments.length) {
        return `highlights[].segment_index ${h.segment_index} is out of range`;
      }
      if (h.text !== null && typeof h.text !== "string") {
        return "highlights[].text must be a string or null";
      }
    }
  }

  return null;
}

/**
 * The user message: the transcript, plus the glossary and the user's
 * highlights when given, each in its own tagged section so the model
 * doesn't mix them up.
 */
export function buildUserMessage(req: AnalyzeMeetingRequest): string {
  const sections = [
    `<transcript>\n${req.segments.map((s, index) => `[${index}] ${s.text.trim()}`).join("\n")}\n</transcript>`,
  ];

  const glossary = (req.glossary ?? []).map((t) => t.trim()).filter((t) => t.length > 0);
  if (glossary.length > 0) {
    sections.push(`<glossary>\n${glossary.join("\n")}\n</glossary>`);
  }

  const highlights = req.highlights ?? [];
  if (highlights.length > 0) {
    const lines = highlights.map((h) => {
      const text = h.text?.trim() ? h.text.trim() : "（★ 標記，沒有文字）";
      return `[重點 ${h.note_index}] 位於逐字稿 [${h.segment_index}]：${text}`;
    });
    sections.push(`<user_highlights>\n${lines.join("\n")}\n</user_highlights>`);
  }

  return sections.join("\n\n");
}

export const SYSTEM_PROMPT = `你是會議記錄整理助手。使用者會提供以下內容，各自放在標籤裡：
- <transcript>：中文會議逐字稿，每一句前面標有這句在逐字稿中的序號（從 0 開始，例如 [0]、[1]、[2]...），序號不是時間。
- <glossary>（可能沒有）：使用者提供的人名、公司名、專有名詞的正確寫法，一行一個。
- <user_highlights>（可能沒有）：使用者在會議中親自標記的重點，每筆標有重點序號和它所在的逐字稿序號。

請根據逐字稿內容產出摘要、待辦事項清單、結構化會議紀錄。

規則：
- 所有輸出文字必須是繁體中文（zh-Hant），不可使用簡體字。
- todos 和 agenda_items 的 source_segment_index 必須填「輸入逐字稿中實際出現過的序號」，該序號來自你要引用那句話前面的 [數字]，不可超出範圍、不可自行編造。
- 逐字稿可能包含轉錄錯誤或多人交叉發言導致的破碎片段，遇到讀不通的內容時盡量根據上下文推斷語意，不要編造逐字稿中沒有的資訊。
- attendees 和數值類欄位如果無法從逐字稿判斷，回傳空陣列或 null，不要猜測。
- <glossary> 裡的詞是正確寫法。逐字稿中發音或字形相近的錯字（例如「太基電」應為「台積電」），在所有輸出中一律改用詞庫的寫法。但不可把逐字稿沒有提到的詞庫詞寫進輸出。
- <user_highlights> 是使用者認為重要的內容，summary.key_points 必須涵蓋每一筆重點。
- highlight_contexts：為 <user_highlights> 的每一筆重點，用一兩句話（50 字以內）說明該處前後在討論什麼，note_index 填該筆的重點序號。沒有 <user_highlights> 時回傳空陣列。`;

export const outputSchema = {
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
    highlight_contexts: {
      type: "array",
      description: "每一筆使用者重點的前後脈絡；沒有 <user_highlights> 時為空陣列",
      items: {
        type: "object",
        properties: {
          note_index: { type: "integer", description: "<user_highlights> 中的重點序號" },
          context: { type: "string", description: "該處在討論什麼，50 字以內" },
        },
        required: ["note_index", "context"],
        additionalProperties: false,
      },
    },
  },
  required: ["summary", "todos", "structured_minutes", "highlight_contexts"],
  additionalProperties: false,
} as const;
