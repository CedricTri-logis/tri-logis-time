import { workforceClient } from '@/lib/supabase/client';
import type {
  MileageApprovalSummaryRow,
  MileageApprovalDetail,
  MileageApproval,
} from '@/types/mileage';

export async function getMileageApprovalSummary(
  periodStart: string,
  periodEnd: string
): Promise<MileageApprovalSummaryRow[]> {
  const { data, error } = await workforceClient().rpc('get_mileage_approval_summary', {
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });
  if (error) throw error;
  return data ?? [];
}

export async function getMileageApprovalDetail(
  employeeId: string,
  periodStart: string,
  periodEnd: string
): Promise<MileageApprovalDetail> {
  const { data, error } = await workforceClient().rpc('get_mileage_approval_detail', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });
  if (error) throw error;
  return data;
}

export async function prefillMileageDefaults(
  employeeId: string,
  periodStart: string,
  periodEnd: string
): Promise<{ prefilled_count: number; needs_review_count: number }> {
  const { data, error } = await workforceClient().rpc('prefill_mileage_defaults', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });
  if (error) throw error;
  return data;
}

export async function updateTripVehicle(
  tripId: string,
  vehicleType: string | null,
  role: string | null
): Promise<any> {
  const { data, error } = await workforceClient().rpc('update_trip_vehicle', {
    p_trip_id: tripId,
    p_vehicle_type: vehicleType,
    p_role: role,
  });
  if (error) throw error;
  return data;
}

export async function batchUpdateTripVehicles(
  tripIds: string[],
  vehicleType: string | null,
  role: string | null
): Promise<{ updated_count: number }> {
  const { data, error } = await workforceClient().rpc('batch_update_trip_vehicles', {
    p_trip_ids: tripIds,
    p_vehicle_type: vehicleType,
    p_role: role,
  });
  if (error) throw error;
  return data;
}

export async function approveMileage(
  employeeId: string,
  periodStart: string,
  periodEnd: string,
  notes?: string
): Promise<MileageApproval> {
  const { data, error } = await workforceClient().rpc('approve_mileage', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
    p_notes: notes || null,
  });
  if (error) throw error;
  return data;
}

export async function reopenMileageApproval(
  employeeId: string,
  periodStart: string,
  periodEnd: string
): Promise<MileageApproval> {
  const { data, error } = await workforceClient().rpc('reopen_mileage_approval', {
    p_employee_id: employeeId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  });
  if (error) throw error;
  return data;
}
