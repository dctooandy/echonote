import { pinyin } from "pinyin-pro";

// Finds transcript spellings that sound exactly like a glossary term
// (tones ignored) but are written differently, so the analysis prompt can
// say "小美 is also written 小眉" instead of hoping the model notices
// (spec feature-glossary-homophones).

/** At most this many spellings are listed per term (decision 4). */
export const HOMOPHONE_VARIANTS_MAX = 3;

const isHan = (text: string) => /^\p{Script=Han}+$/u.test(text);

const toneless = (text: string): string[] => pinyin(text, { type: "array", toneType: "none" });

/**
 * For each glossary term, the transcript spellings that sound the same,
 * most frequent first (ties: first seen first). Only all-Chinese terms of
 * two or more characters are checked (decision 7); a three-character term
 * is also matched by its last two characters, for a person called by their
 * given name (decision 2). Terms with no homophones are left out.
 */
export function findHomophones(glossary: string[], texts: string[]): Map<string, string[]> {
  const terms = [...new Set(glossary.map((t) => t.trim()))].filter((t) => [...t].length >= 2 && isHan(t));
  const result = new Map<string, string[]>();
  if (terms.length === 0) return result;

  // Each segment once: characters and their pinyin, aligned one to one.
  // Pinyin is taken over the whole segment so polyphones follow context.
  const lines = texts
    .map((text) => ({ chars: [...text], sounds: toneless(text) }))
    .filter((l) => l.chars.length === l.sounds.length);

  const known = new Set(terms);
  for (const term of terms) {
    const termChars = [...term];
    const keys = [term];
    if (termChars.length === 3) keys.push(termChars.slice(1).join(""));
    const keySounds = keys.map((key) => ({ key, n: [...key].length, sound: toneless(key).join(" ") }));

    const counts = new Map<string, { count: number; order: number }>();
    let order = 0;
    for (const line of lines) {
      // Positions already matched by the full term, so its last two
      // characters aren't counted a second time.
      const covered = new Set<number>();
      for (const { key, n, sound } of keySounds) {
        for (let i = 0; i + n <= line.chars.length; i++) {
          if (covered.has(i)) continue;
          const spelling = line.chars.slice(i, i + n).join("");
          if (!isHan(spelling) || line.sounds.slice(i, i + n).join(" ") !== sound) continue;
          if (key === term) for (let j = i; j < i + n; j++) covered.add(j);
          if (spelling === key || known.has(spelling)) continue;
          const seen = counts.get(spelling);
          if (seen) seen.count++;
          else counts.set(spelling, { count: 1, order: order++ });
        }
      }
    }

    const spellings = [...counts.entries()]
      .sort(([, a], [, b]) => b.count - a.count || a.order - b.order)
      .slice(0, HOMOPHONE_VARIANTS_MAX)
      .map(([spelling]) => spelling);
    if (spellings.length > 0) result.set(term, spellings);
  }
  return result;
}
