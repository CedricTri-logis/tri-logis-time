/**
 * Zod Validation Schemas for Reports
 * Spec: 013-reports-export
 */

import { z } from 'zod';

// Date range preset enum
export const DateRangePresetEnum = z.enum(['this_week', 'last_week', 'this_month', 'last_month']);

// ISO date pattern
const isoDatePattern = /^\d{4}-\d{2}-\d{2}$/;

// Time pattern (HH:MM)
const timePattern = /^([01]\d|2[0-3]):([0-5]\d)$/;

/**
 * Date range schema for report configuration
 * Either preset OR both start and end dates required
 */
export const dateRangeSchema = z.object({
  preset: DateRangePresetEnum.optional(),
  start: z.string().regex(isoDatePattern, 'Invalid date format (YYYY-MM-DD)').optional(),
  end: z.string().regex(isoDatePattern, 'Invalid date format (YYYY-MM-DD)').optional(),
}).refine(
  (data) => data.preset || (data.start && data.end),
  { message: 'Either preset or both start and end dates required' }
).refine(
  (data) => {
    if (data.start && data.end) {
      return new Date(data.start) <= new Date(data.end);
    }
    return true;
  },
  { message: 'Start date must be before or equal to end date' }
);

export type DateRangeInput = z.infer<typeof dateRangeSchema>;

/**
 * Employee filter schema
 * Can be 'all', 'team:{id}', 'employee:{id}', or array of UUIDs
 */
export const employeeFilterSchema = z.union([
  z.literal('all'),
  z.string().startsWith('team:'),
  z.string().startsWith('employee:'),
  z.array(z.string().uuid('Invalid employee ID')),
]);

export type EmployeeFilterInput = z.infer<typeof employeeFilterSchema>;

/**
 * Report format enum
 */
export const ReportFormatEnum = z.enum(['pdf', 'csv']);

export type ReportFormatInput = z.infer<typeof ReportFormatEnum>;

/**
 * Report type enum
 */
export const ReportTypeEnum = z.enum(['timesheet', 'activity_summary', 'attendance', 'shift_history']);

export type ReportTypeInput = z.infer<typeof ReportTypeEnum>;

/**
 * Report options schema
 */
export const reportOptionsSchema = z.object({
  include_incomplete_shifts: z.boolean().optional().default(false),
  include_gps_summary: z.boolean().optional().default(false),
  group_by: z.enum(['employee', 'date']).optional(),
});

export type ReportOptionsInput = z.infer<typeof reportOptionsSchema>;

/**
 * Full report configuration schema
 */
export const reportConfigSchema = z.object({
  date_range: dateRangeSchema,
  employee_filter: employeeFilterSchema.default('all'),
  format: ReportFormatEnum.default('pdf'),
  options: reportOptionsSchema.optional(),
});

export type ReportConfigInput = z.infer<typeof reportConfigSchema>;
export type ReportConfigFormInput = z.input<typeof reportConfigSchema>;

/**
 * Generate report request schema
 */
export const generateReportSchema = z.object({
  report_type: ReportTypeEnum,
  config: reportConfigSchema,
});

export type GenerateReportInput = z.infer<typeof generateReportSchema>;

/**
 * Schedule frequency enum
 */
export const ScheduleFrequencyEnum = z.enum(['weekly', 'bi_weekly', 'monthly']);

export type ScheduleFrequencyInput = z.infer<typeof ScheduleFrequencyEnum>;

/**
 * Schedule status enum
 */
export const ScheduleStatusEnum = z.enum(['active', 'paused', 'deleted']);

export type ScheduleStatusInput = z.infer<typeof ScheduleStatusEnum>;

/**
 * Schedule configuration schema
 */
export const scheduleConfigSchema = z.object({
  day_of_week: z.number().min(0).max(6).optional(),
  day_of_month: z.number().min(1).max(28).optional(),
  time: z.string().regex(timePattern, 'Invalid time format (HH:MM)'),
  week_parity: z.enum(['odd', 'even']).optional(),
  timezone: z.string().min(1, 'Timezone is required'),
}).refine(
  (data) => data.day_of_week !== undefined || data.day_of_month !== undefined,
  { message: 'Either day_of_week or day_of_month required' }
);

export type ScheduleConfigInput = z.infer<typeof scheduleConfigSchema>;

/**
 * Create report schedule schema
 */
export const createScheduleSchema = z.object({
  name: z.string().min(1, 'Name is required').max(100, 'Name too long'),
  report_type: z.enum(['timesheet', 'activity_summary', 'attendance']), // shift_history not schedulable
  config: reportConfigSchema,
  frequency: ScheduleFrequencyEnum,
  schedule_config: scheduleConfigSchema,
});

export type CreateScheduleInput = z.infer<typeof createScheduleSchema>;

/**
 * Update report schedule schema
 */
export const updateScheduleSchema = z.object({
  schedule_id: z.string().uuid('Invalid schedule ID'),
  name: z.string().min(1).max(100).optional(),
  status: ScheduleStatusEnum.optional(),
  config: reportConfigSchema.optional(),
  schedule_config: scheduleConfigSchema.optional(),
});

export type UpdateScheduleInput = z.infer<typeof updateScheduleSchema>;

/**
 * Report history filter schema
 */
export const reportHistoryFilterSchema = z.object({
  limit: z.number().min(1).max(100).default(20),
  offset: z.number().min(0).default(0),
  report_type: ReportTypeEnum.optional(),
});

export type ReportHistoryFilterInput = z.infer<typeof reportHistoryFilterSchema>;

/**
 * Helper function to resolve date range to actual dates
 */
import { toLocalDateString, addDays, getWeekStart } from '@/lib/utils/date-utils';

export function resolveDateRange(dateRange: DateRangeInput): { start: string; end: string } {
  if (dateRange.start && dateRange.end) {
    return { start: dateRange.start, end: dateRange.end };
  }

  const now = new Date();
  const today = toLocalDateString(now);

  switch (dateRange.preset) {
    case 'this_week':
      return { start: getWeekStart(today), end: today };
    case 'last_week': {
      const lastMonday = addDays(getWeekStart(today), -7);
      return { start: lastMonday, end: addDays(lastMonday, 6) };
    }
    case 'this_month':
      return { start: toLocalDateString(new Date(now.getFullYear(), now.getMonth(), 1)), end: today };
    case 'last_month': {
      const firstLastMonth = new Date(now.getFullYear(), now.getMonth() - 1, 1);
      const lastLastMonth = new Date(now.getFullYear(), now.getMonth(), 0);
      return { start: toLocalDateString(firstLastMonth), end: toLocalDateString(lastLastMonth) };
    }
    default:
      return { start: toLocalDateString(new Date(now.getFullYear(), now.getMonth(), 1)), end: today };
  }
}

/**
 * Helper to format bytes to human readable
 */
export function formatBytes(bytes: number): string {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(2))} ${sizes[i]}`;
}

/**
 * Helper to check if async processing is needed
 */
export const ASYNC_THRESHOLD = 1000;

export function requiresAsyncProcessing(recordCount: number): boolean {
  return recordCount > ASYNC_THRESHOLD;
}
