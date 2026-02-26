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
