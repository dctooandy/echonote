// Per-model prices for the eval set's budget (spec feature-analysis-eval-set,
// decision 5). Checked 2026-11-01 against the claude-api skill's model table
// (cached 2026-10-06) and its prompt-caching guide: cache writes (5-minute
// TTL) cost 1.25x input, cache reads 0.1x input.

export interface ModelPrice {
  /** US$ per million tokens. */
  input: number;
  output: number;
  cacheWrite: number;
  cacheRead: number;
  /** Shorter prompts silently don't cache. */
  minCacheTokens: number;
}

const priced = (input: number, output: number, minCacheTokens: number): ModelPrice => ({
  input,
  output,
  cacheWrite: input * 1.25,
  cacheRead: input * 0.1,
  minCacheTokens,
});

export const PRICES: Record<string, ModelPrice> = {
  "claude-haiku-4-5": priced(1, 5, 4096),
  // Prompts up to 100K tokens; the analysis input never gets near that.
  "claude-haiku-5-5": priced(0.1, 0.5, 512),
};

export function priceOf(model: string): ModelPrice {
  const price = PRICES[model];
  if (!price) throw new Error(`沒有 ${model} 的價格，請先加進 functions/eval/pricing.ts`);
  return price;
}

/** What one call costs, from the API's usage block. */
export function callCost(
  model: string,
  usage: {
    input_tokens: number;
    output_tokens: number;
    cache_creation_input_tokens?: number | null;
    cache_read_input_tokens?: number | null;
  }
): number {
  const p = priceOf(model);
  return (
    (usage.input_tokens * p.input +
      (usage.cache_creation_input_tokens ?? 0) * p.cacheWrite +
      (usage.cache_read_input_tokens ?? 0) * p.cacheRead +
      usage.output_tokens * p.output) /
    1_000_000
  );
}

/** Typical analysis output; the worst case is max_tokens. */
export const TYPICAL_OUTPUT_TOKENS = 3000;

/**
 * Estimated cost of [runs] calls on one case of [inputTokens]: the first
 * call writes the cache and the rest read it, when the prompt is long
 * enough to cache.
 */
export function estimateCaseCost(
  model: string,
  inputTokens: number,
  runs: number,
  outputTokens: number
): number {
  const p = priceOf(model);
  const input =
    inputTokens >= p.minCacheTokens
      ? inputTokens * p.cacheWrite + inputTokens * p.cacheRead * (runs - 1)
      : inputTokens * p.input * runs;
  return (input + outputTokens * p.output * runs) / 1_000_000;
}
