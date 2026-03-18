import type { EmployeeRoleType, EmployeeStatusType, SupervisionTypeValue } from '@/lib/validations/employee';

// Employee profile from database
export interface EmployeeProfile {
  id: string;
  email: string;
  full_name: string | null;
  employee_id: string | null;
  phone_number: string | null;
  role: EmployeeRoleType;
  status: EmployeeStatusType;
  privacy_consent_at: string | null;
  created_at: string;
  updated_at: string;
}

// Employee list item from get_employees_paginated RPC
export interface EmployeeListItem {
  id: string;
  email: string;
  full_name: string | null;
  employee_id: string | null;
  role: EmployeeRoleType;
  status: EmployeeStatusType;
  created_at: string;
  updated_at: string;
  current_supervisor_id: string | null;
  current_supervisor_name: string | null;
  current_supervisor_email: string | null;
  total_count: number;
}

// Supervisor info for detail view
export interface SupervisorInfo {
  id: string;
  full_name: string | null;
  email: string;
}

// Supervision history entry
export interface SupervisionHistoryEntry {
  id: string;
  manager_id: string;
  manager_name: string | null;
  manager_email: string;
  supervision_type: SupervisionTypeValue;
  effective_from: string;
  effective_to: string | null;
}

// Employee detail from get_employee_detail RPC
export interface EmployeeDetail extends EmployeeProfile {
  current_supervisor: SupervisorInfo | null;
  supervision_history: SupervisionHistoryEntry[];
  has_active_shift: boolean;
}

// Manager list item for assignment dropdown
export interface ManagerListItem {
  id: string;
  email: string;
  full_name: string | null;
  role: EmployeeRoleType;
  supervised_count: number;
}

// Audit log entry
export interface AuditLogEntry {
  id: string;
  operation: 'INSERT' | 'UPDATE' | 'DELETE';
  user_id: string | null;
  user_email: string | null;
  changed_at: string;
  old_values: Record<string, unknown> | null;
  new_values: Record<string, unknown> | null;
  change_reason: string | null;
  total_count: number;
}

// RPC request parameters
export interface GetEmployeesPaginatedParams {
  p_search?: string;
  p_role?: EmployeeRoleType;
  p_status?: EmployeeStatusType;
  p_sort_field?: string;
  p_sort_order?: 'ASC' | 'DESC';
  p_limit?: number;
  p_offset?: number;
}

export interface UpdateEmployeeProfileParams {
  p_employee_id: string;
  p_full_name?: string | null;
  p_employee_id_value?: string | null;
}

export interface UpdateEmployeeStatusParams {
  p_employee_id: string;
  p_new_status: EmployeeStatusType;
  p_force?: boolean;
}

export interface AssignSupervisorParams {
  p_employee_id: string;
  p_manager_id: string;
  p_supervision_type?: SupervisionTypeValue;
}

// RPC response types
export interface UpdateEmployeeResponse {
  success: boolean;
  employee?: EmployeeProfile;
  error?: {
    code: string;
    message: string;
  };
}

export interface UpdateStatusResponse {
  success: boolean;
  warning?: string;
  requires_confirmation?: boolean;
  employee?: EmployeeProfile;
  error?: {
    code: string;
    message: string;
  };
}

export interface AssignSupervisorResponse {
  success: boolean;
  assignment?: {
    id: string;
    manager_id: string;
    employee_id: string;
    effective_from: string;
    supervision_type: SupervisionTypeValue;
  };
  previous_assignment_ended?: boolean;
  error?: {
    code: string;
    message: string;
  };
}

export interface RemoveSupervisorResponse {
  success: boolean;
  ended_assignment?: {
    id: string;
    manager_id: string;
    employee_id: string;
    effective_to: string;
  };
  error?: {
    code: string;
    message: string;
  };
}

// Request/response for phone update
export interface UpdatePhoneParams {
  p_user_id: string;
  p_phone: string | null;
}

// Request for email update (API route)
export interface UpdateEmailRequest {
  employee_id: string;
  email: string;
}

// Request for employee creation (API route)
export interface CreateEmployeeRequest {
  email: string;
  full_name?: string;
  role?: EmployeeRoleType;
  supervisor_id?: string;
}

// Generic API response
export interface ApiResponse {
  success: boolean;
  error?: string;
  employee_id?: string;
}
