import { z } from 'zod';

// Role enum values
export const EmployeeRole = {
  EMPLOYEE: 'employee',
  MANAGER: 'manager',
  ADMIN: 'admin',
  SUPER_ADMIN: 'super_admin',
} as const;

export type EmployeeRoleType = typeof EmployeeRole[keyof typeof EmployeeRole];

// Status enum values
export const EmployeeStatus = {
  ACTIVE: 'active',
  INACTIVE: 'inactive',
  SUSPENDED: 'suspended',
} as const;

export type EmployeeStatusType = typeof EmployeeStatus[keyof typeof EmployeeStatus];

// Supervision type enum values
export const SupervisionType = {
  DIRECT: 'direct',
  MATRIX: 'matrix',
  TEMPORARY: 'temporary',
} as const;

export type SupervisionTypeValue = typeof SupervisionType[keyof typeof SupervisionType];

// Schema for editing employee profile (name and employee_id)
export const employeeEditSchema = z.object({
  full_name: z
    .string()
    .max(100, 'Name must be 100 characters or less')
    .nullable()
    .optional(),
  employee_id: z
    .string()
    .max(50, 'Employee ID must be 50 characters or less')
    .regex(/^[a-zA-Z0-9-]*$/, 'Only letters, numbers, and dashes allowed')
    .nullable()
    .optional(),
});

export type EmployeeEditInput = z.infer<typeof employeeEditSchema>;

// Schema for role change
export const roleChangeSchema = z.object({
  role: z.enum(['employee', 'manager', 'admin', 'super_admin']),
});

export type RoleChangeInput = z.infer<typeof roleChangeSchema>;

// Schema for status change
export const statusChangeSchema = z.object({
  status: z.enum(['active', 'inactive', 'suspended']),
});

export type StatusChangeInput = z.infer<typeof statusChangeSchema>;

// Schema for supervisor assignment
export const supervisorAssignmentSchema = z.object({
  manager_id: z.string().uuid('Invalid manager ID'),
  supervision_type: z.enum(['direct', 'matrix', 'temporary']).default('direct'),
});

export type SupervisorAssignmentInput = z.infer<typeof supervisorAssignmentSchema>;

// Schema for search/filter params
export const employeeFilterSchema = z.object({
  search: z.string().optional(),
  role: z.enum(['employee', 'manager', 'admin', 'super_admin']).optional(),
  status: z.enum(['active', 'inactive', 'suspended']).optional(),
});

export type EmployeeFilterInput = z.infer<typeof employeeFilterSchema>;

// Schema for editing employee profile (extended with phone and email)
export const employeeEditExtendedSchema = z.object({
  full_name: z
    .string()
    .max(100, 'Name must be 100 characters or less')
    .nullable()
    .optional(),
  employee_id: z
    .string()
    .max(50, 'Employee ID must be 50 characters or less')
    .regex(/^[a-zA-Z0-9-]*$/, 'Only letters, numbers, and dashes allowed')
    .nullable()
    .optional(),
  phone_number: z
    .string()
    .max(20)
    .nullable()
    .optional(),
  email: z
    .string()
    .email('Invalid email address')
    .max(255)
    .optional(),
});

export type EmployeeEditExtendedInput = z.infer<typeof employeeEditExtendedSchema>;

// Schema for creating an employee
export const createEmployeeSchema = z.object({
  email: z.string().email('Invalid email address').max(255),
  full_name: z.string().max(100).optional(),
  role: z.enum(['employee', 'manager', 'admin', 'super_admin']),
  supervisor_id: z.string().uuid().optional(),
});

export type CreateEmployeeInput = z.infer<typeof createEmployeeSchema>;
