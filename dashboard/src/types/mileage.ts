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
  activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out';
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
}

export interface ActivityClockEvent extends ActivityItemBase {
  activity_type: 'clock_in' | 'clock_out';
  clock_latitude: number | null;
  clock_longitude: number | null;
  clock_accuracy: number | null;
  matched_location_id: string | null;
  matched_location_name: string | null;
}

export type ActivityItem = ActivityTrip | ActivityStop | ActivityClockEvent;
