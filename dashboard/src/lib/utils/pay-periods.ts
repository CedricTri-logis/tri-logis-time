import { addDays, subDays, differenceInCalendarDays, format, parseISO } from 'date-fns';
import { fr } from 'date-fns/locale';
import type { PayPeriod } from '@/types/payroll';

const PAY_PERIOD_ANCHOR = '2026-03-08'; // Sunday
const PAY_PERIOD_DAYS = 14;

export function getPayPeriod(dateStr: string): PayPeriod {
  const anchor = parseISO(PAY_PERIOD_ANCHOR);
  const date = parseISO(dateStr);
  const diffDays = differenceInCalendarDays(date, anchor);
  const periodOffset = Math.floor(diffDays / PAY_PERIOD_DAYS);
  const start = addDays(anchor, periodOffset * PAY_PERIOD_DAYS);
  const end = addDays(start, PAY_PERIOD_DAYS - 1);
  return {
    start: format(start, 'yyyy-MM-dd'),
    end: format(end, 'yyyy-MM-dd'),
  };
}

export function getLastCompletedPeriod(todayStr: string): PayPeriod {
  const current = getPayPeriod(todayStr);
  if (todayStr > current.end) return current;
  const prevDate = format(subDays(parseISO(current.start), 1), 'yyyy-MM-dd');
  return getPayPeriod(prevDate);
}

export function getPreviousPeriod(period: PayPeriod): PayPeriod {
  const prevDate = format(subDays(parseISO(period.start), 1), 'yyyy-MM-dd');
  return getPayPeriod(prevDate);
}

export function getNextPeriod(period: PayPeriod): PayPeriod {
  const nextDate = format(addDays(parseISO(period.end), 1), 'yyyy-MM-dd');
  return getPayPeriod(nextDate);
}

export function formatPeriodLabel(period: PayPeriod): string {
  const start = parseISO(period.start);
  const end = parseISO(period.end);
  return `${format(start, 'd MMM', { locale: fr })} – ${format(end, 'd MMM yyyy', { locale: fr })}`;
}

export function getRecentPeriods(count: number, todayStr: string): PayPeriod[] {
  const periods: PayPeriod[] = [];
  let current = getLastCompletedPeriod(todayStr);
  for (let i = 0; i < count; i++) {
    periods.push(current);
    current = getPreviousPeriod(current);
  }
  return periods;
}

export function formatMinutesAsHours(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m > 0 ? `${h}h${m.toString().padStart(2, '0')}` : `${h}h`;
}
