export interface Trip {
  id: string;
  shift_id: string;
  employee_id: string;
  started_at: string;
  ended_at: string;
  start_latitude: number;
  start_longitude: number;
  start_address: string | null;
  start_location_id: string | null;
  end_latitude: number;
  end_longitude: number;
  end_address: string | null;
  end_location_id: string | null;
  distance_km: number;
  duration_minutes: number;
  classification: "business" | "personal";
  confidence_score: number;
  gps_point_count: number;
  low_accuracy_segments: number;
  detection_method: "auto" | "manual";
  created_at: string;
  updated_at: string;

  // Route matching fields
  route_geometry: string | null;
  road_distance_km: number | null;
  match_status: "pending" | "processing" | "matched" | "failed" | "anomalous";
  match_confidence: number | null;
  match_error: string | null;
  matched_at: string | null;
  match_attempts: number;

  // Location match methods
  start_location_match_method: 'auto' | 'manual';
  end_location_match_method: 'auto' | 'manual';

  // Transport mode
  transport_mode: "driving" | "walking" | "unknown";

  // Joined fields (optional, from expanded queries)
  employee?: {
    id: string;
    name: string;
  };
  start_location?: {
    id: string;
    name: string;
  };
  end_location?: {
    id: string;
    name: string;
  };
}

export interface TripGpsPoint {
  sequence_order: number;
  latitude: number;
  longitude: number;
  accuracy: number;
  speed: number | null;
  heading: number | null;
  altitude: number | null;
  captured_at: string;
}

export interface MileageSummary {
  total_distance_km: number;
  business_distance_km: number;
  personal_distance_km: number;
  trip_count: number;
  business_trip_count: number;
  personal_trip_count: number;
  estimated_reimbursement: number;
  rate_per_km_used: number;
  rate_source: string;
  ytd_business_km: number;
}

export interface TeamMileageSummary {
  employee_id: string;
  employee_name: string;
  total_distance_km: number;
  business_distance_km: number;
  trip_count: number;
  estimated_reimbursement: number;
  avg_daily_km: number;
}

export interface ReimbursementRate {
  id: string;
  rate_per_km: number;
  threshold_km: number | null;
  rate_after_threshold: number | null;
  effective_from: string;
  effective_to: string | null;
  rate_source: "cra" | "custom";
  notes: string | null;
  created_by: string | null;
  created_at: string;
}

export interface MileageReport {
  id: string;
  employee_id: string;
  period_start: string;
  period_end: string;
  total_distance_km: number;
  business_distance_km: number;
  personal_distance_km: number;
  trip_count: number;
  business_trip_count: number;
  total_reimbursement: number;
  rate_per_km_used: number;
  rate_source_used: string;
  file_path: string | null;
  file_format: "pdf" | "csv";
  generated_at: string;
  created_at: string;
}

export interface EmployeeVehiclePeriod {
  id: string;
  employee_id: string;
  vehicle_type: "personal" | "company";
  started_at: string;
  ended_at: string | null;
  notes: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
  // Joined
  employee?: { id: string; name: string };
}

export interface CarpoolGroup {
  id: string;
  trip_date: string;
  status: "auto_detected" | "confirmed" | "dismissed";
  driver_employee_id: string | null;
  review_needed: boolean;
  review_note: string | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  created_at: string;
  // Joined
  members?: CarpoolMember[];
  driver?: { id: string; name: string };
}

export interface CarpoolMember {
  id: string;
  carpool_group_id: string;
  trip_id: string;
  employee_id: string;
  role: "driver" | "passenger" | "unassigned";
  // Joined
  employee?: { id: string; name: string };
  trip?: Trip;
}

// Activity timeline types (unified trips + stops + clock events)
export interface ActivityItemBase {
  activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap' | 'lunch';
  id: string;
  shift_id: string;
  started_at: string;
  ended_at: string;
}

export interface ActivityTrip extends ActivityItemBase {
  activity_type: 'trip';
  start_latitude: number;
  start_longitude: number;
  start_address: string | null;
  start_location_id: string | null;
  start_location_name: string | null;
  end_latitude: number;
  end_longitude: number;
  end_address: string | null;
  end_location_id: string | null;
  end_location_name: string | null;
  distance_km: number;
  road_distance_km: number | null;
  duration_minutes: number;
  transport_mode: 'driving' | 'walking' | 'unknown';
  match_status: 'pending' | 'processing' | 'matched' | 'failed' | 'anomalous';
  match_confidence: number | null;
  route_geometry: string | null;
  start_cluster_id: string | null;
  end_cluster_id: string | null;
  classification: 'business' | 'personal';
  gps_point_count: number;
  has_gps_gap: boolean;
}

export interface ActivityStop extends ActivityItemBase {
  activity_type: 'stop';
  centroid_latitude: number;
  centroid_longitude: number;
  centroid_accuracy: number | null;
  duration_seconds: number;
  cluster_gps_point_count: number;
  matched_location_id: string | null;
  matched_location_name: string | null;
  gps_gap_seconds: number;
  gps_gap_count: number;
  effective_location_type: string | null;
}

export interface ActivityClockEvent extends ActivityItemBase {
  activity_type: 'clock_in' | 'clock_out';
  clock_latitude: number | null;
  clock_longitude: number | null;
  clock_accuracy: number | null;
  matched_location_id: string | null;
  matched_location_name: string | null;
}

export interface ActivityGap extends ActivityItemBase {
  activity_type: 'gap';
  start_latitude: number;
  start_longitude: number;
  start_location_id: string | null;
  start_location_name: string | null;
  end_latitude: number;
  end_longitude: number;
  end_location_id: string | null;
  end_location_name: string | null;
  distance_km: number;
  duration_minutes: number;
  has_gps_gap: boolean;
  start_cluster_id: string | null;
  end_cluster_id: string | null;
  clock_latitude: number | null;
  clock_longitude: number | null;
  clock_accuracy: number | null;
}

export type ActivityItem = ActivityTrip | ActivityStop | ActivityClockEvent | ActivityGap;

// ============================================================
// Hours Approval types
// ============================================================

export type ApprovalAutoStatus = 'approved' | 'rejected' | 'needs_review';
export type DayApprovalStatus = 'no_shift' | 'active' | 'pending' | 'needs_review' | 'approved';

export interface ApprovalActivity {
  activity_type: 'trip' | 'stop' | 'stop_segment' | 'trip_segment' | 'gap_segment' | 'lunch_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch' | 'manual_time';
  activity_id: string;
  shift_id: string;
  started_at: string;
  ended_at: string;
  duration_minutes: number;
  is_edited?: boolean;
  original_value?: string;
  auto_status: ApprovalAutoStatus;
  auto_reason: string;
  override_status: 'approved' | 'rejected' | null;
  override_reason: string | null;
  final_status: ApprovalAutoStatus;
  matched_location_id: string | null;
  location_name: string | null;
  location_type: string | null;
  latitude: number | null;
  longitude: number | null;
  distance_km: number | null;
  road_distance_km: number | null;
  transport_mode: string | null;
  has_gps_gap: boolean | null;
  start_location_id: string | null;
  start_location_name: string | null;
  start_location_type: string | null;
  end_location_id: string | null;
  end_location_name: string | null;
  end_location_type: string | null;
  gps_gap_seconds: number | null;
  gps_gap_count: number | null;
  shift_type: 'regular' | 'call' | null;
  shift_type_source: 'auto' | 'manual' | null;
  manual_reason?: string;
  is_standalone_shift?: boolean;
  manual_created_by?: string;
  manual_created_at?: string;
  children?: ApprovalActivity[];
}

export interface ProjectSession {
  session_type: 'cleaning' | 'maintenance';
  session_id: string;
  started_at: string;
  ended_at: string;
  duration_minutes: number;
  building_name: string;
  unit_label: string | null;
  unit_type: string;
  session_status: string;
  location_id: string | null;
}

export interface DayApprovalDetail {
  employee_id: string;
  date: string;
  has_active_shift: boolean;
  has_stale_gps?: boolean;
  approval_status: 'pending' | 'approved';
  approved_by: string | null;
  approved_at: string | null;
  notes: string | null;
  activities: ApprovalActivity[];
  project_sessions: ProjectSession[];
  summary: {
    total_shift_minutes: number;
    approved_minutes: number;
    rejected_minutes: number;
    needs_review_count: number;
    lunch_minutes: number;
    call_count: number;
    call_billed_minutes: number;
    call_bonus_minutes: number;
  };
}

export interface WeeklyDayEntry {
  date: string;
  has_shifts: boolean;
  has_active_shift: boolean;
  status: DayApprovalStatus;
  total_shift_minutes: number;
  approved_minutes: number | null;
  rejected_minutes: number | null;
  needs_review_count: number;
  lunch_minutes: number;
  call_count: number;
  call_billed_minutes: number;
  call_bonus_minutes: number;
  gap_minutes: number;
  added_minutes?: number;
}

export interface WeeklyEmployeeRow {
  employee_id: string;
  employee_name: string;
  days: WeeklyDayEntry[];
}

// ============================================================
// Mileage Approval Types
// ============================================================

export interface MileageApprovalSummaryRow {
  employee_id: string;
  employee_name: string;
  trip_count: number;
  reimbursable_km: number;
  company_km: number;
  needs_review_count: number;
  carpool_group_count: number;
  estimated_amount: number;
  mileage_status: 'pending' | 'approved' | null;
  approved_km: number | null;
  approved_amount: number | null;
  is_forfait: boolean;
}

export interface MileageTripDetail {
  trip_date: string;
  trip_id: string;
  started_at: string;
  ended_at: string;
  start_address: string | null;
  end_address: string | null;
  start_latitude: number | null;
  start_longitude: number | null;
  end_latitude: number | null;
  end_longitude: number | null;
  start_location_id: string | null;
  end_location_id: string | null;
  distance_km: number;
  vehicle_type: 'personal' | 'company' | null;
  role: 'driver' | 'passenger' | null;
  transport_mode: string;
  has_gps_gap: boolean;
  carpool_group_id: string | null;
  carpool_detected_role: string | null;
  carpool_members: CarpoolMemberInfo[] | null;
  trip_status: 'approved' | 'rejected' | 'needs_review';
  start_location_type: string | null;
  end_location_type: string | null;
}

export interface CarpoolMemberInfo {
  employee_id: string;
  employee_name: string;
  role: string;
  trip_id: string;
}

export interface MileageApprovalDetailSummary {
  reimbursable_km: number;
  company_km: number;
  passenger_km: number;
  needs_review_count: number;
  estimated_amount: number;
  ytd_km: number;
  rate_per_km: number;
  rate_after_threshold: number | null;
  threshold_km: number | null;
  is_forfait: boolean;
  forfait_amount: number | null;
}

export interface MileageApproval {
  id: string;
  employee_id: string;
  period_start: string;
  period_end: string;
  status: 'pending' | 'approved';
  reimbursable_km: number | null;
  reimbursement_amount: number | null;
  approved_by: string | null;
  approved_at: string | null;
  unlocked_by: string | null;
  unlocked_at: string | null;
  notes: string | null;
  is_forfait: boolean;
  forfait_amount: number | null;
}

export interface MileageApprovalDetail {
  trips: MileageTripDetail[];
  summary: MileageApprovalDetailSummary;
  approval: MileageApproval | null;
}

export interface EmployeeMileageAllowance {
  id: string;
  employee_id: string;
  amount_per_period: number;
  started_at: string;
  ended_at: string | null;
  notes: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
}
