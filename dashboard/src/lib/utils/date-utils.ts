/**
 * Timezone-safe date utilities for RPC parameters.
 *
 * Uses local Date getters (getFullYear, getMonth, getDate) to produce
 * YYYY-MM-DD strings. This avoids the off-by-one bug caused by
 * .toISOString().split('T')[0] which uses UTC date.
 */

/** Format a Date as YYYY-MM-DD using local timezone */
export function toLocalDateString(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

/** Parse a YYYY-MM-DD string into a Date at noon local (safe for date math) */
export function parseLocalDate(dateStr: string): Date {
  return new Date(dateStr + 'T12:00:00');
}

/** Add days to a YYYY-MM-DD string, returns YYYY-MM-DD */
export function addDays(dateStr: string, days: number): string {
  const d = parseLocalDate(dateStr);
  d.setDate(d.getDate() + days);
  return toLocalDateString(d);
}

/** Get the Monday (ISO week start) of the week containing the given date */
export function getMonday(dateStr?: string): string {
  const d = dateStr ? parseLocalDate(dateStr) : new Date();
  const day = d.getDay();
  d.setDate(d.getDate() - day + (day === 0 ? -6 : 1));
  return toLocalDateString(d);
}
