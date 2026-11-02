import { createHash } from "node:crypto";
import { findHomophones } from "./homophones";

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

/** An earlier meeting this one follows up on: its conclusions, never its transcript. */
export interface PreviousMeeting {
  title: string;
  /** YYYY-MM-DD, the device's local date. */
  date: string;
  overview: string;
  /** Every agenda item's decisions, flattened. */
  decisions: string[];
  todos: { task: string; owner: string | null; done: boolean }[];
}

export interface AnalyzeMeetingRequest {
  segments: TranscriptSegment[];
  language?: string;
  glossary?: string[];
  highlights?: Highlight[];
  /** Oldest first; the last one is the meeting this one directly follows. */
  previous_meetings?: PreviousMeeting[];
  /** The user's own name, sent only when they took part (spec feature-my-name). */
  my_name?: string;
}

export const GLOSSARY_MAX_TERMS = 200;
export const GLOSSARY_TERM_MAX_CHARS = 20;
export const MY_NAME_MAX_CHARS = 20;

// The app trims to these same numbers before sending (spec decision 4).
export const PREVIOUS_MEETINGS_MAX = 3;
export const PREVIOUS_OVERVIEW_MAX_CHARS = 500;
export const PREVIOUS_DECISIONS_MAX = 20;
export const PREVIOUS_TODOS_MAX = 30;
export const PREVIOUS_ITEM_MAX_CHARS = 200;

const isIndex = (value: unknown): value is number => Number.isInteger(value) && (value as number) >= 0;

// Code points, so a CJK character counts as one (matches the app).
const charCount = (text: string) => [...text].length;
const isShortText = (value: unknown, max: number): value is string =>
  typeof value === "string" && charCount(value) <= max;

function validatePreviousMeeting(m: unknown): string | null {
  const meeting = m as Partial<PreviousMeeting> | null;
  if (meeting == null || typeof meeting !== "object") return "previous_meetings[] must be an object";
  if (!isShortText(meeting.title, PREVIOUS_ITEM_MAX_CHARS)) {
    return `previous_meetings[].title must be a string of at most ${PREVIOUS_ITEM_MAX_CHARS} characters`;
  }
  if (typeof meeting.date !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(meeting.date)) {
    return "previous_meetings[].date must be YYYY-MM-DD";
  }
  if (!isShortText(meeting.overview, PREVIOUS_OVERVIEW_MAX_CHARS)) {
    return `previous_meetings[].overview must be a string of at most ${PREVIOUS_OVERVIEW_MAX_CHARS} characters`;
  }
  if (!Array.isArray(meeting.decisions) || meeting.decisions.length > PREVIOUS_DECISIONS_MAX) {
    return `previous_meetings[].decisions must be an array of at most ${PREVIOUS_DECISIONS_MAX}`;
  }
  if (meeting.decisions.some((d) => !isShortText(d, PREVIOUS_ITEM_MAX_CHARS))) {
    return `previous_meetings[].decisions[] must be strings of at most ${PREVIOUS_ITEM_MAX_CHARS} characters`;
  }
  if (!Array.isArray(meeting.todos) || meeting.todos.length > PREVIOUS_TODOS_MAX) {
    return `previous_meetings[].todos must be an array of at most ${PREVIOUS_TODOS_MAX}`;
  }
  for (const todo of meeting.todos) {
    if (!isShortText(todo?.task, PREVIOUS_ITEM_MAX_CHARS)) {
      return `previous_meetings[].todos[].task must be a string of at most ${PREVIOUS_ITEM_MAX_CHARS} characters`;
    }
    if (todo.owner !== null && !isShortText(todo.owner, PREVIOUS_ITEM_MAX_CHARS)) {
      return `previous_meetings[].todos[].owner must be null or a string of at most ${PREVIOUS_ITEM_MAX_CHARS} characters`;
    }
    if (typeof todo.done !== "boolean") return "previous_meetings[].todos[].done must be a boolean";
  }
  return null;
}

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

  if (req.previous_meetings != null) {
    if (!Array.isArray(req.previous_meetings)) return "previous_meetings must be an array";
    if (req.previous_meetings.length > PREVIOUS_MEETINGS_MAX) {
      return `previous_meetings must have at most ${PREVIOUS_MEETINGS_MAX} entries`;
    }
    for (const meeting of req.previous_meetings) {
      const error = validatePreviousMeeting(meeting);
      if (error) return error;
    }
  }

  if (req.my_name != null) {
    if (typeof req.my_name !== "string" || req.my_name.trim().length === 0) {
      return "my_name must be a non-empty string";
    }
    if (charCount(req.my_name.trim()) > MY_NAME_MAX_CHARS) {
      return `my_name must be at most ${MY_NAME_MAX_CHARS} characters`;
    }
  }

  return null;
}

/**
 * One earlier meeting as text. Only the latest one ([indexTodos]) numbers
 * its todos, because only those are tracked in follow_up.todo_progress;
 * older meetings are background (spec decision 3).
 */
function formatPreviousMeeting(meeting: PreviousMeeting, number: number, indexTodos: boolean): string {
  const lines = [`前一場 ${number}（${meeting.date}）：${meeting.title.trim()}`, `摘要：${meeting.overview.trim()}`];
  if (meeting.decisions.length > 0) {
    lines.push("決議：", ...meeting.decisions.map((d) => `- ${d.trim()}`));
  }
  if (meeting.todos.length > 0) {
    lines.push("待辦：");
    meeting.todos.forEach((todo, i) => {
      const status = todo.done ? "已完成" : "未完成";
      const detail = todo.owner?.trim() ? `負責人：${todo.owner.trim()}；${status}` : status;
      lines.push(`${indexTodos ? `[上次待辦 ${i}]` : "-"} ${todo.task.trim()}（${detail}）`);
    });
  }
  return lines.join("\n");
}

/** Homophone spellings to note in the glossary; none if the lookup fails. */
function glossaryHomophones(glossary: string[], segments: TranscriptSegment[]): Map<string, string[]> {
  try {
    return findHomophones(glossary, segments.map((s) => s.text));
  } catch {
    return new Map();
  }
}

/**
 * The user message: the transcript, plus the glossary and the user's
 * notes when given, each in its own tagged section so the model doesn't
 * mix them up. The request field is still `highlights`; the prompt calls
 * them notes so the model doesn't read their text as meeting content.
 */
export function buildUserMessage(req: AnalyzeMeetingRequest): string {
  const sections = [
    `<transcript>\n${req.segments.map((s, index) => `[${index}] ${s.text.trim()}`).join("\n")}\n</transcript>`,
  ];

  const myName = req.my_name?.trim() || null;
  const terms = (req.glossary ?? []).map((t) => t.trim()).filter((t) => t.length > 0);
  // The user's name is a glossary term too, so a misheard 安迪 maps back to
  // Andy (decision 5).
  const glossary = myName && !terms.includes(myName) ? [...terms, myName] : terms;
  if (glossary.length > 0) {
    const variants = glossaryHomophones(glossary, req.segments);
    const lines = glossary.map((t) => {
      const spellings = variants.get(t);
      return spellings ? `${t}（逐字稿裡也寫成：${spellings.join("、")}）` : t;
    });
    sections.push(`<glossary>\n${lines.join("\n")}\n</glossary>`);
  }

  const highlights = req.highlights ?? [];
  if (highlights.length > 0) {
    const lines = highlights.map((h) => {
      const text = h.text?.trim() ? h.text.trim() : "（★ 標記，沒有文字）";
      return `[筆記 ${h.note_index}] 標在逐字稿 [${h.segment_index}]：${text}`;
    });
    sections.push(`<user_notes>\n${lines.join("\n")}\n</user_notes>`);
  }

  if (myName) {
    sections.push(`<my_name>${myName}</my_name>`);
  }

  const previous = req.previous_meetings ?? [];
  if (previous.length > 0) {
    const blocks = previous.map((m, i) => formatPreviousMeeting(m, i + 1, i === previous.length - 1));
    sections.push(`<previous_meetings>\n${blocks.join("\n\n")}\n</previous_meetings>`);
  }

  return sections.join("\n\n");
}

export const SYSTEM_PROMPT = `你是會議記錄整理助手。使用者會提供以下內容，各自放在標籤裡：
- <transcript>：中文會議逐字稿，每一句前面標有這句在逐字稿中的序號（從 0 開始，例如 [0]、[1]、[2]...），序號不是時間。
- <glossary>（可能沒有）：使用者提供的人名、公司名、專有名詞的正確寫法，一行一個。有些詞後面會註明「（逐字稿裡也寫成：…）」，列的是逐字稿裡跟這個詞讀音相同的寫法，由程式依讀音找出。
- <user_notes>（可能沒有）：使用者在會議中或回放時私下寫的備忘或 ★ 標記，每筆標有筆記序號和它標在哪一句逐字稿。筆記是使用者自己的想法、提醒或待查事項，不是會議發言，會議裡沒有人這樣說。
- <previous_meetings>（可能沒有）：這場會議接續的前幾場會議的紀錄，由舊到新排列；最後一場是這場直接接續的會議，它的待辦標有 [上次待辦 數字]。
- <my_name>（可能沒有）：錄音的使用者本人的名字。有這一段代表使用者參加了這場會議，逐字稿裡有些「我」是使用者說的；沒有這一段代表使用者可能沒參加。

請根據逐字稿內容產出摘要、待辦事項清單、結構化會議紀錄；有 <previous_meetings> 時，另外產出與上次相比的 follow_up。

規則：
- 所有輸出文字必須是繁體中文（zh-Hant），不可使用簡體字。
- todos 和 agenda_items 的 source_segment_index 必須填「輸入逐字稿中實際出現過的序號」，該序號來自你要引用那句話前面的 [數字]，不可超出範圍、不可自行編造。
- 逐字稿可能包含轉錄錯誤或多人交叉發言導致的破碎片段，遇到讀不通的內容時盡量根據上下文推斷語意，不要編造逐字稿中沒有的資訊。讀不通的詞如果跟某個常見詞發音或字形相近、而且上下文明顯指的是那個詞，就直接寫成那個詞（例如在講主機的段落裡，「申請伺服氣」應為「申請伺服器」）；真的推斷不出來才照逐字稿原字寫，不要寫「內容不清楚」這類說明。
- attendees 和數值類欄位如果無法從逐字稿判斷，回傳空陣列或 null，不要猜測。
- 待辦的負責人（owner）：逐字稿沒有標出是誰在說話，要依上下文判斷「我」是誰。只有能確定是誰要做時才填，判斷不出來就填 null，不要猜。被叫到名字的人不等於負責人：例如「陳經理，我週三前修好」是說話的人要做，不是陳經理；只有逐字稿明確說那個人要做（例如「陳經理你負責報價」「我請陳經理處理」）才寫他。
- 逐字稿在發言前點出說話的人時（例如「小明說，……」「阿傑，新網域我來申請」「小華：我去找報價」），那句的「我」就是那個人。
- 有 <my_name> 時：<my_name> 只代表使用者可能在場，不代表逐字稿裡的「我」都是使用者。先把能歸給其他說話者的「我」歸給他們；剩下的「我」，只有在明顯是使用者時才寫成 <my_name> 的名字，例如整場只有兩個人對話、使用者向被稱為「您」「醫師」「經理」的對方報告進度或請對方決定。硬性規則：使用者的名字在逐字稿裡從沒出現、而且有兩個以上其他人被點名發言或被叫到名字時（例如小明、小華、阿傑都有出現），這場很可能是別人的會議，不可以把任何「我」寫成使用者，負責人、attendees、摘要都不可以出現使用者的名字；歸不出說話者的「我」填 null。其他情況不確定也填 null。attendees 只有在逐字稿裡有人叫到使用者的名字，或明顯有一方是使用者時，才列出使用者。
- 沒有 <my_name> 時，「我」不對到使用者，只能歸給逐字稿裡點出的說話者。
- <glossary> 裡的詞是正確寫法。逐字稿中發音或字形相近的錯字（例如「太基電」應為「台積電」），在所有輸出中一律改用詞庫的寫法：摘要、待辦的內容和負責人、會議紀錄的出席者／議題／討論／決議、follow_up、highlight_contexts 都一樣，負責人和出席者也不例外。人名在逐字稿裡只叫名字或被聽錯時，也要對應到詞庫裡的人（例如詞庫有「陳怡君」，逐字稿叫她「宜君」或聽錯成「一軍」，負責人就寫「陳怡君」）。讀音相同或相近的名字，即使逐字稿寫成不同的字（例如詞庫有「怡君」，逐字稿有時寫「怡君」有時寫「宜君」），也視為詞庫裡的同一個人，只列一次、一律用詞庫的寫法。詞庫的詞註明了「逐字稿裡也寫成」時，逐字稿裡那些寫法指的就是這個詞（例如「小美（逐字稿裡也寫成：小眉）」，逐字稿的「小眉」就是小美，是同一個人），一律改用詞庫的寫法；只有上下文明顯在講別的事時才不改。但不可把逐字稿沒有提到的詞庫詞寫進輸出。
- <user_notes> 只用來判斷使用者覺得哪些位置重要。summary.key_points 必須涵蓋每一筆筆記標的那句逐字稿的會議內容（是逐字稿那句的內容，不是筆記文字）。
- 筆記文字的內容不可以出現在 summary、todos、structured_minutes、highlight_contexts 的任何地方，改寫、摘要或合併進其他句子也不行。筆記看起來像某句待辦或決議的補充時也一樣，只寫逐字稿裡實際說的部分。例如筆記「記得問含不含稅」標在「小王負責詢價」那句：待辦只能寫「小王負責詢價」，不可寫成「小王負責詢價並確認是否含稅」。
- <previous_meetings> 是之前會議的紀錄，不是這次的發言。summary、todos、structured_minutes、highlight_contexts 都只能根據這次的逐字稿；不可把只在前幾場出現的內容寫成這次有人說過、決議過或要求過的內容。follow_up 是唯一可以引用前幾場的欄位。
- follow_up：沒有 <previous_meetings> 時，三個欄位都回傳空陣列。有的時候：
  - todo_progress：最後一場的每一筆 [上次待辦 數字] 都要列一筆，previous_todo_index 填那個數字。這次逐字稿提到已完成填 done，提到還在進行填 in_progress，沒提到填 not_mentioned（排在最後）。note 用一句話（50 字以內）說明根據；source_segment_index 填提到它的逐字稿序號，not_mentioned 填 null。
  - decision_changes：前幾場的每一條決議，只要這次逐字稿有提到，就列一筆，change 依下面的定義三選一：
    - continued（延續）：這次重申或確認維持原本的決議，內容沒有變。例如「維持原本的決定」「還是一樣」。重申過的決議也一定要列。
    - revised（修改）：方向不變，只調整細節，例如日期延後、數量或範圍變動。例如「上線從 15 號延到 22 號」。
    - reversed（推翻）：取消原本的決議，或改成另一個不同的選項。例如「不用藍色了，改成綠色」「不贊助了」。
    previous_decision 寫之前的決議，current 寫這次的說法，source_segment_index 填這次逐字稿的序號。這次沒提到的決議不用列。
  - new_topics：這次討論、但前幾場紀錄都沒有出現過的主題，每筆一個簡短名詞片語。
- highlight_contexts：<user_notes> 的每一筆都要回傳一筆，筆數必須等於筆記數，note_index 填筆記序號；★ 標記、跟逐字稿無關或矛盾的筆記也一樣要回傳。context 根據逐字稿用一兩句話（50 字以內）說明筆記標的那句前後在討論什麼，只描述會議，不提筆記寫了什麼、也不評論筆記。沒有 <user_notes> 時回傳空陣列。`;

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
      description: "每一筆使用者筆記所在位置的會議脈絡，筆數等於 <user_notes> 的筆數；沒有 <user_notes> 時為空陣列",
      items: {
        type: "object",
        properties: {
          note_index: { type: "integer", description: "<user_notes> 中的筆記序號" },
          context: { type: "string", description: "該處在討論什麼，50 字以內" },
        },
        required: ["note_index", "context"],
        additionalProperties: false,
      },
    },
    follow_up: {
      type: "object",
      description: "與 <previous_meetings> 相比的變化；沒有 <previous_meetings> 時三個欄位都是空陣列",
      properties: {
        todo_progress: {
          type: "array",
          items: {
            type: "object",
            properties: {
              previous_todo_index: { type: "integer", description: "[上次待辦 數字] 的數字" },
              status: { type: "string", enum: ["done", "in_progress", "not_mentioned"] },
              note: { type: "string", description: "一句話說明根據，50 字以內" },
              source_segment_index: {
                type: ["integer", "null"],
                description: "這次逐字稿提到它的序號；not_mentioned 時為 null",
              },
            },
            required: ["previous_todo_index", "status", "note", "source_segment_index"],
            additionalProperties: false,
          },
        },
        decision_changes: {
          type: "array",
          items: {
            type: "object",
            properties: {
              change: { type: "string", enum: ["continued", "revised", "reversed"] },
              previous_decision: { type: "string" },
              current: { type: "string" },
              source_segment_index: {
                type: ["integer", "null"],
                description: "這次逐字稿的序號（輸入每句前面的 [數字]，從 0 開始，不是時間）",
              },
            },
            required: ["change", "previous_decision", "current", "source_segment_index"],
            additionalProperties: false,
          },
        },
        new_topics: { type: "array", items: { type: "string" } },
      },
      required: ["todo_progress", "decision_changes", "new_topics"],
      additionalProperties: false,
    },
  },
  required: ["summary", "todos", "structured_minutes", "highlight_contexts", "follow_up"],
  additionalProperties: false,
} as const;

export const ANALYSIS_MODEL = "claude-haiku-4-5";
export const ANALYSIS_MAX_TOKENS = 6000;

export type AnalysisEffort = "low" | "medium" | "high";

export interface AnalysisOptions {
  model?: string;
  /** Thinking depth; only for models that take it (not Haiku 4.5). */
  effort?: AnalysisEffort;
  /** Left unset, the model's default (Haiku 5.5 thinks by default). */
  thinking?: "adaptive" | "disabled";
  maxTokens?: number;
}

/** Models that reject output_config.effort and adaptive thinking. */
const NO_EFFORT_MODELS = new Set(["claude-haiku-4-5"]);

/**
 * Everything messages.create gets, for production and the eval set alike,
 * so the two can't drift apart (spec feature-analysis-eval-set). The
 * options are for the eval set (spec feature-haiku-5-5-eval); unset, they
 * send nothing extra.
 */
export function buildAnalysisParams(req: AnalyzeMeetingRequest, options: AnalysisOptions = {}) {
  const model = options.model ?? ANALYSIS_MODEL;
  if (NO_EFFORT_MODELS.has(model) && (options.effort || options.thinking === "adaptive")) {
    throw new Error(`${model} 不支援 effort 和 adaptive thinking`);
  }
  return {
    model,
    max_tokens: options.maxTokens ?? ANALYSIS_MAX_TOKENS,
    system: SYSTEM_PROMPT,
    messages: [{ role: "user" as const, content: buildUserMessage(req) }],
    ...(options.thinking ? { thinking: { type: options.thinking } } : {}),
    output_config: {
      format: { type: "json_schema" as const, schema: outputSchema },
      ...(options.effort ? { effort: options.effort } : {}),
    },
  };
}

/**
 * Short hash of the prompt and schema, so eval reports say which prompt
 * they ran without anyone bumping a version by hand.
 */
export function promptVersion(): string {
  return promptHash(SYSTEM_PROMPT, outputSchema);
}

export function promptHash(system: string, schema: unknown): string {
  return createHash("sha256").update(system).update(JSON.stringify(schema)).digest("hex").slice(0, 8);
}
