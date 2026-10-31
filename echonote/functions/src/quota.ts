// Pure daily-quota rules for analyzeMeeting (spec feature-app-check).
// Kept free of Firebase imports so it can be tested directly; the Firestore
// transaction that applies them lives in index.ts.

/** Calls allowed per day across all devices (decisions 2, 3). */
export const DAILY_LIMIT = 50;

/** Counter documents are deleted by a Firestore TTL policy after this. */
export const QUOTA_RETENTION_DAYS = 30;

/** The counter document id: the date in Asia/Taipei (decision 4). */
export function quotaDayKey(now: Date): string {
  // en-CA formats as YYYY-MM-DD.
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Taipei",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}

/** Whether one more call fits under [limit], given [current] calls so far. */
export function decideQuota(current: number, limit: number): { allowed: boolean; next: number } {
  return current < limit ? { allowed: true, next: current + 1 } : { allowed: false, next: current };
}
