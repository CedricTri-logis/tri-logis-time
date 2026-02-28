import { z } from 'zod';

export const approvalFilterSchema = z.object({
  status: z.enum(['all', 'pending', 'needs_review', 'approved']).default('all'),
  employee_search: z.string().optional(),
});

export type ApprovalFilterInput = z.infer<typeof approvalFilterSchema>;

export const overrideSchema = z.object({
  employee_id: z.string().uuid(),
  date: z.string(),
  activity_type: z.enum(['trip', 'stop', 'clock_in', 'clock_out']),
  activity_id: z.string().uuid(),
  status: z.enum(['approved', 'rejected']),
  reason: z.string().max(500).optional(),
});

export type OverrideInput = z.infer<typeof overrideSchema>;
