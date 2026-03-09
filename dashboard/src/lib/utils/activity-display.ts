/**
 * Shared display helpers for activity tables (Activity tab + Approval detail).
 */

/** Format a timestamp to HH:MM in fr-CA locale */
export function formatTime(dateStr: string): string {
  return new Date(dateStr).toLocaleTimeString('fr-CA', {
    hour: '2-digit',
    minute: '2-digit',
  });
}

/** Format seconds to "Xh XXmin" or "XX min" */
export function formatDuration(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes.toString().padStart(2, '0')}min`;
  return `${minutes} min`;
}

/** Format minutes (number or string) to "Xh XXmin" or "XX min" */
export function formatDurationMinutes(minutes: number | string): string {
  const m = Number(minutes) || 0;
  const hours = Math.floor(m / 60);
  const mins = Math.round(m % 60);
  if (hours > 0) return `${hours}h ${mins.toString().padStart(2, '0')}min`;
  return `${mins} min`;
}

/** Format a date string as a localized header (e.g. "lundi 3 mars 2026") */
export function formatDateHeader(dateStr: string): string {
  const date = new Date(dateStr + 'T12:00:00');
  return date.toLocaleDateString('fr-CA', {
    weekday: 'long',
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  });
}

/** Format distance in km or return em-dash */
export function formatDistance(km: number | string | null): string {
  if (km == null) return '—';
  const n = Number(km);
  if (isNaN(n)) return '—';
  return `${n.toFixed(1)} km`;
}
