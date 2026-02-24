import { z } from 'zod';

// Shift status filter values
export const ShiftStatusFilter = {
  ALL: 'all',
  ON_SHIFT: 'on-shift',
  OFF_SHIFT: 'off-shift',
  NEVER_INSTALLED: 'never-installed',
} as const;

export type ShiftStatusFilterValue = (typeof ShiftStatusFilter)[keyof typeof ShiftStatusFilter];

// Schema for monitoring filters (search and status)
export const monitoringFilterSchema = z.object({
  search: z.string().max(100, 'Search must be 100 characters or less').optional(),
  shiftStatus: z.enum(['all', 'on-shift', 'off-shift', 'never-installed']).default('all'),
});

export type MonitoringFilterInput = z.infer<typeof monitoringFilterSchema>;

// Schema for employee ID path parameter
export const employeeIdParamSchema = z.string().uuid('Invalid employee ID');

// Schema for shift ID path parameter
export const shiftIdParamSchema = z.string().uuid('Invalid shift ID');

// Validation for latitude/longitude values
export const coordinateSchema = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
});

// RPC parameter schemas (for type-safe RPC calls)
export const getMonitoredTeamParamsSchema = z.object({
  p_search: z.string().nullable().optional(),
  p_shift_status: z.enum(['all', 'on-shift', 'off-shift', 'never-installed']).default('all'),
});

export type GetMonitoredTeamParams = z.infer<typeof getMonitoredTeamParamsSchema>;

export const getShiftDetailParamsSchema = z.object({
  p_shift_id: z.string().uuid(),
});

export type GetShiftDetailParams = z.infer<typeof getShiftDetailParamsSchema>;

export const getShiftGpsTrailParamsSchema = z.object({
  p_shift_id: z.string().uuid(),
});

export type GetShiftGpsTrailParams = z.infer<typeof getShiftGpsTrailParamsSchema>;

export const getEmployeeCurrentShiftParamsSchema = z.object({
  p_employee_id: z.string().uuid(),
});

export type GetEmployeeCurrentShiftParams = z.infer<typeof getEmployeeCurrentShiftParamsSchema>;
