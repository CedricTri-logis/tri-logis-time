import { z } from 'zod';

export const CLEANING_SESSION_STATUSES = [
  'in_progress',
  'completed',
  'auto_closed',
  'manually_closed',
] as const;

export const cleaningFiltersSchema = z.object({
  buildingId: z.string().uuid().optional(),
  employeeId: z.string().uuid().optional(),
  dateFrom: z.date(),
  dateTo: z.date(),
  status: z.enum(CLEANING_SESSION_STATUSES).optional(),
});

export type CleaningFiltersInput = z.infer<typeof cleaningFiltersSchema>;

export const manualCloseSchema = z.object({
  sessionId: z.string().uuid(),
  reason: z.string().max(500).optional(),
});

export type ManualCloseInput = z.infer<typeof manualCloseSchema>;
