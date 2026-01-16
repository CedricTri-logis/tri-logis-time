import { z } from 'zod';

/**
 * Date range validation for shift history queries
 */
export const dateRangeSchema = z
  .object({
    startDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Invalid date format (YYYY-MM-DD)'),
    endDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Invalid date format (YYYY-MM-DD)'),
  })
  .refine((data) => new Date(data.startDate) <= new Date(data.endDate), {
    message: 'Start date must be before or equal to end date',
  })
  .refine(
    (data) => {
      const start = new Date(data.startDate);
      const end = new Date(data.endDate);
      const diffDays = (end.getTime() - start.getTime()) / (1000 * 60 * 60 * 24);
      return diffDays <= 7;
    },
    { message: 'Date range cannot exceed 7 days' }
  )
  .refine(
    (data) => {
      const now = new Date();
      const start = new Date(data.startDate);
      const diffDays = (now.getTime() - start.getTime()) / (1000 * 60 * 60 * 24);
      return diffDays <= 90;
    },
    { message: 'Cannot query data older than 90 days' }
  );

export type DateRange = z.infer<typeof dateRangeSchema>;

/**
 * Export options validation
 */
export const exportOptionsSchema = z.object({
  format: z.enum(['csv', 'geojson']),
  includeMetadata: z.boolean().default(true),
  dateRange: dateRangeSchema.optional(),
});

export type ExportOptions = z.infer<typeof exportOptionsSchema>;

/**
 * Playback speed validation
 */
export const playbackSpeedSchema = z.union([
  z.literal(0.5),
  z.literal(1),
  z.literal(2),
  z.literal(4),
]);

export type PlaybackSpeedValue = z.infer<typeof playbackSpeedSchema>;

/**
 * Shift ID array validation (for multi-shift queries)
 */
export const shiftIdsSchema = z.array(z.string().uuid()).min(1).max(10);

export type ShiftIds = z.infer<typeof shiftIdsSchema>;

/**
 * Employee ID validation
 */
export const employeeIdSchema = z.string().uuid('Invalid employee ID');

/**
 * Shift ID validation
 */
export const shiftIdSchema = z.string().uuid('Invalid shift ID');

/**
 * Shift history filters validation
 */
export const shiftHistoryFiltersSchema = z.object({
  employeeId: z.string().uuid().optional(),
  startDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  endDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
});

export type ShiftHistoryFilters = z.infer<typeof shiftHistoryFiltersSchema>;
