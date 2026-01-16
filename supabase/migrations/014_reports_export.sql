-- Migration: Reports & Export
-- Spec: 013-reports-export
-- Purpose: Tables, RPC functions, storage bucket, and policies for reporting system

-- =====================================================
-- TABLES
-- =====================================================

-- Table: report_schedules (created first due to FK reference from report_jobs)
CREATE TABLE report_schedules (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  report_type TEXT NOT NULL CHECK (report_type IN ('timesheet', 'activity_summary', 'attendance')),

  -- Report configuration (same structure as report_jobs.config)
  config JSONB NOT NULL,

  -- Schedule configuration
  frequency TEXT NOT NULL CHECK (frequency IN ('weekly', 'bi_weekly', 'monthly')),
  schedule_config JSONB NOT NULL,

  -- Execution tracking
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'deleted')),
  next_run_at TIMESTAMPTZ NOT NULL,
  last_run_at TIMESTAMPTZ,
  last_run_status TEXT CHECK (last_run_status IN ('success', 'failed')),
  run_count INTEGER NOT NULL DEFAULT 0,
  failure_count INTEGER NOT NULL DEFAULT 0,

  -- Metadata
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes for report_schedules
CREATE INDEX idx_report_schedules_user_id ON report_schedules(user_id);
CREATE INDEX idx_report_schedules_next_run ON report_schedules(next_run_at) WHERE status = 'active';
CREATE INDEX idx_report_schedules_status ON report_schedules(status);

-- Table: report_jobs
CREATE TABLE report_jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  report_type TEXT NOT NULL CHECK (report_type IN ('timesheet', 'activity_summary', 'attendance', 'shift_history')),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),

  -- Report configuration
  config JSONB NOT NULL,

  -- Execution details
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  error_message TEXT,

  -- Result
  file_path TEXT,
  file_size_bytes BIGINT,
  record_count INTEGER,

  -- Metadata
  is_async BOOLEAN NOT NULL DEFAULT false,
  schedule_id UUID REFERENCES report_schedules(id) ON DELETE SET NULL,
  notification_seen BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '30 days')
);

-- Indexes for report_jobs
CREATE INDEX idx_report_jobs_user_id ON report_jobs(user_id);
CREATE INDEX idx_report_jobs_status ON report_jobs(status) WHERE status IN ('pending', 'processing');
CREATE INDEX idx_report_jobs_created_at ON report_jobs(created_at DESC);
CREATE INDEX idx_report_jobs_expires_at ON report_jobs(expires_at);
CREATE INDEX idx_report_jobs_notification ON report_jobs(user_id, notification_seen) WHERE status = 'completed' AND notification_seen = false;

-- Table: report_audit_logs
CREATE TABLE report_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id UUID REFERENCES report_jobs(id) ON DELETE SET NULL,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  action TEXT NOT NULL CHECK (action IN ('generated', 'downloaded', 'deleted', 'scheduled')),

  -- Context
  report_type TEXT NOT NULL,
  parameters JSONB NOT NULL,

  -- Result
  status TEXT NOT NULL CHECK (status IN ('success', 'failed')),
  error_message TEXT,
  file_path TEXT,

  -- Metadata
  ip_address INET,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes for report_audit_logs
CREATE INDEX idx_report_audit_logs_user_id ON report_audit_logs(user_id);
CREATE INDEX idx_report_audit_logs_created_at ON report_audit_logs(created_at DESC);
CREATE INDEX idx_report_audit_logs_job_id ON report_audit_logs(job_id);

-- =====================================================
-- ROW LEVEL SECURITY
-- =====================================================

-- Enable RLS on all tables
ALTER TABLE report_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE report_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE report_audit_logs ENABLE ROW LEVEL SECURITY;

-- report_jobs policies
CREATE POLICY "Users view own jobs"
ON report_jobs FOR SELECT
USING (user_id = auth.uid());

CREATE POLICY "Users create own jobs"
ON report_jobs FOR INSERT
WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users update own jobs"
ON report_jobs FOR UPDATE
USING (user_id = auth.uid());

-- report_schedules policies
CREATE POLICY "Users manage own schedules"
ON report_schedules FOR ALL
USING (user_id = auth.uid());

-- report_audit_logs policies
CREATE POLICY "Users view own audit logs"
ON report_audit_logs FOR SELECT
USING (user_id = auth.uid());

CREATE POLICY "Users create audit logs"
ON report_audit_logs FOR INSERT
WITH CHECK (user_id = auth.uid());

-- =====================================================
-- STORAGE BUCKET
-- =====================================================

-- Create reports bucket (private by default)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'reports',
  'reports',
  false,
  52428800, -- 50MB limit
  ARRAY['application/pdf', 'text/csv']
) ON CONFLICT (id) DO NOTHING;

-- Storage policies for reports bucket
CREATE POLICY "Users can upload to own folder"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'reports' AND
  (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "Users can read own reports"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'reports' AND
  (storage.foldername(name))[1] = auth.uid()::text
);

CREATE POLICY "Users can delete own reports"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'reports' AND
  (storage.foldername(name))[1] = auth.uid()::text
);

-- =====================================================
-- RPC FUNCTIONS
-- =====================================================

-- Function: count_report_records
-- Counts records to determine if async processing is needed
CREATE OR REPLACE FUNCTION count_report_records(
  p_report_type TEXT,
  p_start_date DATE,
  p_end_date DATE,
  p_employee_ids UUID[] DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_count INTEGER;
  v_authorized_employees UUID[];
BEGIN
  -- Get caller's role
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE id = v_user_id;

  IF v_user_role IS NULL THEN
    RETURN jsonb_build_object('count', 0, 'error', 'User not found');
  END IF;

  -- Check authorization
  IF v_user_role NOT IN ('admin', 'super_admin', 'manager') THEN
    RETURN jsonb_build_object('count', 0, 'error', 'Unauthorized');
  END IF;

  -- Get authorized employee list
  IF v_user_role IN ('admin', 'super_admin') THEN
    IF p_employee_ids IS NOT NULL THEN
      v_authorized_employees := p_employee_ids;
    ELSE
      SELECT array_agg(id) INTO v_authorized_employees
      FROM employee_profiles
      WHERE status = 'active';
    END IF;
  ELSE
    -- Manager: only supervised employees
    SELECT array_agg(es.employee_id) INTO v_authorized_employees
    FROM employee_supervisors es
    WHERE es.manager_id = v_user_id
      AND es.effective_to IS NULL
      AND (p_employee_ids IS NULL OR es.employee_id = ANY(p_employee_ids));
  END IF;

  IF v_authorized_employees IS NULL THEN
    RETURN jsonb_build_object('count', 0);
  END IF;

  -- Count shifts based on report type
  IF p_report_type IN ('timesheet', 'shift_history') THEN
    SELECT COUNT(*) INTO v_count
    FROM shifts s
    WHERE s.employee_id = ANY(v_authorized_employees)
      AND s.clocked_in_at::DATE >= p_start_date
      AND s.clocked_in_at::DATE <= p_end_date;
  ELSIF p_report_type = 'attendance' THEN
    -- For attendance, count is employee * days
    v_count := array_length(v_authorized_employees, 1) * (p_end_date - p_start_date + 1);
  ELSIF p_report_type = 'activity_summary' THEN
    SELECT COUNT(*) INTO v_count
    FROM shifts s
    WHERE s.employee_id = ANY(v_authorized_employees)
      AND s.clocked_in_at::DATE >= p_start_date
      AND s.clocked_in_at::DATE <= p_end_date;
  ELSE
    v_count := 0;
  END IF;

  RETURN jsonb_build_object('count', COALESCE(v_count, 0));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: generate_report
-- Creates a report job and returns job ID (async) or triggers sync generation
CREATE OR REPLACE FUNCTION generate_report(
  p_report_type TEXT,
  p_config JSONB
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_job_id UUID;
  v_record_count INTEGER;
  v_is_async BOOLEAN;
  v_start_date DATE;
  v_end_date DATE;
  v_employee_ids UUID[];
BEGIN
  -- Get caller's role
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE id = v_user_id;

  IF v_user_role IS NULL THEN
    RETURN jsonb_build_object('error', 'User not found');
  END IF;

  -- Check authorization
  IF v_user_role NOT IN ('admin', 'super_admin', 'manager') THEN
    RETURN jsonb_build_object('error', 'Unauthorized');
  END IF;

  -- Extract date range from config
  v_start_date := (p_config->'date_range'->>'start')::DATE;
  v_end_date := (p_config->'date_range'->>'end')::DATE;

  -- Extract employee filter
  IF p_config->>'employee_filter' != 'all' THEN
    IF jsonb_typeof(p_config->'employee_filter') = 'array' THEN
      SELECT array_agg(x::UUID)
      INTO v_employee_ids
      FROM jsonb_array_elements_text(p_config->'employee_filter') x;
    END IF;
  END IF;

  -- Count records to determine sync/async
  SELECT (count_report_records(p_report_type, v_start_date, v_end_date, v_employee_ids)->>'count')::INTEGER
  INTO v_record_count;

  v_is_async := v_record_count > 1000;

  -- Create job record
  INSERT INTO report_jobs (
    user_id,
    report_type,
    status,
    config,
    is_async
  ) VALUES (
    v_user_id,
    p_report_type,
    CASE WHEN v_is_async THEN 'pending' ELSE 'processing' END,
    p_config,
    v_is_async
  ) RETURNING id INTO v_job_id;

  -- Log the generation request
  INSERT INTO report_audit_logs (
    job_id,
    user_id,
    action,
    report_type,
    parameters,
    status
  ) VALUES (
    v_job_id,
    v_user_id,
    'generated',
    p_report_type,
    p_config,
    'success'
  );

  RETURN jsonb_build_object(
    'job_id', v_job_id,
    'status', CASE WHEN v_is_async THEN 'pending' ELSE 'processing' END,
    'is_async', v_is_async,
    'record_count', v_record_count,
    'estimated_duration_seconds', CASE WHEN v_is_async THEN GREATEST(30, v_record_count / 50) ELSE NULL END
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: get_report_job_status
-- Returns current status of a report job
CREATE OR REPLACE FUNCTION get_report_job_status(
  p_job_id UUID
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_job RECORD;
  v_signed_url TEXT;
BEGIN
  -- Get job details
  SELECT * INTO v_job
  FROM report_jobs
  WHERE id = p_job_id AND user_id = v_user_id;

  IF v_job IS NULL THEN
    RETURN jsonb_build_object('error', 'Job not found');
  END IF;

  -- Build response
  RETURN jsonb_build_object(
    'job_id', v_job.id,
    'status', v_job.status,
    'started_at', v_job.started_at,
    'completed_at', v_job.completed_at,
    'error_message', v_job.error_message,
    'file_path', v_job.file_path,
    'file_size_bytes', v_job.file_size_bytes,
    'record_count', v_job.record_count,
    'is_async', v_job.is_async,
    'expires_at', v_job.expires_at
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: get_report_history
-- Returns paginated list of user's report jobs
CREATE OR REPLACE FUNCTION get_report_history(
  p_limit INTEGER DEFAULT 20,
  p_offset INTEGER DEFAULT 0,
  p_report_type TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_items JSONB;
  v_total_count INTEGER;
BEGIN
  -- Get items
  SELECT jsonb_agg(
    jsonb_build_object(
      'job_id', rj.id,
      'report_type', rj.report_type,
      'status', rj.status,
      'config', rj.config,
      'file_path', rj.file_path,
      'file_size_bytes', rj.file_size_bytes,
      'record_count', rj.record_count,
      'created_at', rj.created_at,
      'expires_at', rj.expires_at,
      'download_available', (rj.status = 'completed' AND rj.file_path IS NOT NULL AND rj.expires_at > NOW())
    ) ORDER BY rj.created_at DESC
  ) INTO v_items
  FROM (
    SELECT *
    FROM report_jobs
    WHERE user_id = v_user_id
      AND (p_report_type IS NULL OR report_type = p_report_type)
    ORDER BY created_at DESC
    LIMIT p_limit
    OFFSET p_offset
  ) rj;

  -- Get total count
  SELECT COUNT(*) INTO v_total_count
  FROM report_jobs
  WHERE user_id = v_user_id
    AND (p_report_type IS NULL OR report_type = p_report_type);

  RETURN jsonb_build_object(
    'items', COALESCE(v_items, '[]'::jsonb),
    'total_count', v_total_count,
    'has_more', (p_offset + p_limit) < v_total_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: get_timesheet_report_data
-- Retrieves timesheet data for report generation
CREATE OR REPLACE FUNCTION get_timesheet_report_data(
  p_start_date DATE,
  p_end_date DATE,
  p_employee_ids UUID[] DEFAULT NULL,
  p_include_incomplete BOOLEAN DEFAULT false
)
RETURNS TABLE (
  employee_id UUID,
  employee_name TEXT,
  employee_identifier TEXT,
  shift_date DATE,
  clocked_in_at TIMESTAMPTZ,
  clocked_out_at TIMESTAMPTZ,
  duration_minutes INTEGER,
  status TEXT,
  notes TEXT
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_authorized_employees UUID[];
BEGIN
  -- Get caller's role
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE employee_profiles.id = v_user_id;

  IF v_user_role NOT IN ('admin', 'super_admin', 'manager') THEN
    RETURN;
  END IF;

  -- Get authorized employees
  IF v_user_role IN ('admin', 'super_admin') THEN
    IF p_employee_ids IS NOT NULL THEN
      v_authorized_employees := p_employee_ids;
    ELSE
      SELECT array_agg(id) INTO v_authorized_employees
      FROM employee_profiles
      WHERE employee_profiles.status = 'active';
    END IF;
  ELSE
    SELECT array_agg(es.employee_id) INTO v_authorized_employees
    FROM employee_supervisors es
    WHERE es.manager_id = v_user_id
      AND es.effective_to IS NULL
      AND (p_employee_ids IS NULL OR es.employee_id = ANY(p_employee_ids));
  END IF;

  IF v_authorized_employees IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    s.employee_id,
    ep.full_name AS employee_name,
    ep.employee_id AS employee_identifier,
    s.clocked_in_at::DATE AS shift_date,
    s.clocked_in_at,
    s.clocked_out_at,
    CASE
      WHEN s.clocked_out_at IS NOT NULL THEN
        EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60
      ELSE
        EXTRACT(EPOCH FROM (NOW() - s.clocked_in_at))::INTEGER / 60
    END AS duration_minutes,
    CASE
      WHEN s.clocked_out_at IS NOT NULL THEN 'complete'
      ELSE 'incomplete'
    END AS status,
    NULL::TEXT AS notes
  FROM shifts s
  JOIN employee_profiles ep ON ep.id = s.employee_id
  WHERE s.employee_id = ANY(v_authorized_employees)
    AND s.clocked_in_at::DATE >= p_start_date
    AND s.clocked_in_at::DATE <= p_end_date
    AND (p_include_incomplete OR s.clocked_out_at IS NOT NULL)
  ORDER BY ep.full_name, s.clocked_in_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: get_shift_history_export_data
-- Retrieves shift history with GPS data for export
CREATE OR REPLACE FUNCTION get_shift_history_export_data(
  p_start_date DATE,
  p_end_date DATE,
  p_employee_ids UUID[] DEFAULT NULL
)
RETURNS TABLE (
  employee_id UUID,
  employee_name TEXT,
  employee_identifier TEXT,
  shift_id UUID,
  clocked_in_at TIMESTAMPTZ,
  clocked_out_at TIMESTAMPTZ,
  duration_minutes INTEGER,
  status TEXT,
  gps_point_count BIGINT,
  clock_in_latitude DECIMAL(10, 8),
  clock_in_longitude DECIMAL(11, 8),
  clock_out_latitude DECIMAL(10, 8),
  clock_out_longitude DECIMAL(11, 8)
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_authorized_employees UUID[];
BEGIN
  -- Get caller's role
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE employee_profiles.id = v_user_id;

  IF v_user_role NOT IN ('admin', 'super_admin', 'manager') THEN
    RETURN;
  END IF;

  -- Check 90-day retention
  IF p_start_date < (CURRENT_DATE - INTERVAL '90 days')::DATE THEN
    RETURN;
  END IF;

  -- Get authorized employees
  IF v_user_role IN ('admin', 'super_admin') THEN
    IF p_employee_ids IS NOT NULL THEN
      v_authorized_employees := p_employee_ids;
    ELSE
      SELECT array_agg(id) INTO v_authorized_employees
      FROM employee_profiles
      WHERE employee_profiles.status = 'active';
    END IF;
  ELSE
    SELECT array_agg(es.employee_id) INTO v_authorized_employees
    FROM employee_supervisors es
    WHERE es.manager_id = v_user_id
      AND es.effective_to IS NULL
      AND (p_employee_ids IS NULL OR es.employee_id = ANY(p_employee_ids));
  END IF;

  IF v_authorized_employees IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    s.employee_id,
    ep.full_name AS employee_name,
    ep.employee_id AS employee_identifier,
    s.id AS shift_id,
    s.clocked_in_at,
    s.clocked_out_at,
    CASE
      WHEN s.clocked_out_at IS NOT NULL THEN
        EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at))::INTEGER / 60
      ELSE NULL
    END AS duration_minutes,
    s.status,
    (SELECT COUNT(*) FROM gps_points gp WHERE gp.shift_id = s.id) AS gps_point_count,
    (s.clock_in_location->>'latitude')::DECIMAL(10, 8) AS clock_in_latitude,
    (s.clock_in_location->>'longitude')::DECIMAL(11, 8) AS clock_in_longitude,
    (s.clock_out_location->>'latitude')::DECIMAL(10, 8) AS clock_out_latitude,
    (s.clock_out_location->>'longitude')::DECIMAL(11, 8) AS clock_out_longitude
  FROM shifts s
  JOIN employee_profiles ep ON ep.id = s.employee_id
  WHERE s.employee_id = ANY(v_authorized_employees)
    AND s.clocked_in_at::DATE >= p_start_date
    AND s.clocked_in_at::DATE <= p_end_date
  ORDER BY ep.full_name, s.clocked_in_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: get_team_activity_summary
-- Retrieves aggregated team activity metrics
CREATE OR REPLACE FUNCTION get_team_activity_summary(
  p_start_date DATE,
  p_end_date DATE,
  p_team_id UUID DEFAULT NULL
)
RETURNS TABLE (
  period TEXT,
  total_hours DECIMAL(10, 2),
  total_shifts INTEGER,
  avg_hours_per_employee DECIMAL(10, 2),
  employees_active INTEGER,
  hours_by_day JSONB
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_authorized_employees UUID[];
BEGIN
  -- Get caller's role
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE employee_profiles.id = v_user_id;

  IF v_user_role NOT IN ('admin', 'super_admin', 'manager') THEN
    RETURN;
  END IF;

  -- Get authorized employees
  IF v_user_role IN ('admin', 'super_admin') THEN
    IF p_team_id IS NOT NULL THEN
      SELECT array_agg(es.employee_id) INTO v_authorized_employees
      FROM employee_supervisors es
      WHERE es.manager_id = p_team_id
        AND es.effective_to IS NULL;
    ELSE
      SELECT array_agg(id) INTO v_authorized_employees
      FROM employee_profiles
      WHERE employee_profiles.status = 'active';
    END IF;
  ELSE
    SELECT array_agg(es.employee_id) INTO v_authorized_employees
    FROM employee_supervisors es
    WHERE es.manager_id = v_user_id
      AND es.effective_to IS NULL;
  END IF;

  IF v_authorized_employees IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH shift_stats AS (
    SELECT
      s.employee_id,
      s.clocked_in_at,
      s.clocked_out_at,
      CASE
        WHEN s.clocked_out_at IS NOT NULL THEN
          EXTRACT(EPOCH FROM (s.clocked_out_at - s.clocked_in_at)) / 3600.0
        ELSE 0
      END AS hours_worked,
      TO_CHAR(s.clocked_in_at, 'Dy') AS day_name
    FROM shifts s
    WHERE s.employee_id = ANY(v_authorized_employees)
      AND s.clocked_in_at::DATE >= p_start_date
      AND s.clocked_in_at::DATE <= p_end_date
      AND s.clocked_out_at IS NOT NULL
  ),
  day_breakdown AS (
    SELECT
      day_name,
      ROUND(SUM(hours_worked)::NUMERIC, 2) AS day_hours
    FROM shift_stats
    GROUP BY day_name
  )
  SELECT
    TO_CHAR(p_start_date, 'YYYY-MM') AS period,
    ROUND(COALESCE(SUM(ss.hours_worked), 0)::NUMERIC, 2) AS total_hours,
    COUNT(*)::INTEGER AS total_shifts,
    ROUND((COALESCE(SUM(ss.hours_worked), 0) / NULLIF(COUNT(DISTINCT ss.employee_id), 0))::NUMERIC, 2) AS avg_hours_per_employee,
    COUNT(DISTINCT ss.employee_id)::INTEGER AS employees_active,
    (SELECT jsonb_object_agg(day_name, day_hours) FROM day_breakdown) AS hours_by_day
  FROM shift_stats ss;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: get_attendance_report_data
-- Retrieves attendance/absence data for employees
CREATE OR REPLACE FUNCTION get_attendance_report_data(
  p_start_date DATE,
  p_end_date DATE,
  p_employee_ids UUID[] DEFAULT NULL
)
RETURNS TABLE (
  employee_id UUID,
  employee_name TEXT,
  total_working_days INTEGER,
  days_worked INTEGER,
  days_absent INTEGER,
  attendance_rate DECIMAL(5, 2),
  calendar_data JSONB
) AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_authorized_employees UUID[];
  v_total_days INTEGER;
BEGIN
  -- Get caller's role
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE employee_profiles.id = v_user_id;

  IF v_user_role NOT IN ('admin', 'super_admin', 'manager') THEN
    RETURN;
  END IF;

  -- Calculate total working days (exclude weekends)
  SELECT COUNT(*) INTO v_total_days
  FROM generate_series(p_start_date, p_end_date, '1 day'::INTERVAL) d
  WHERE EXTRACT(DOW FROM d) NOT IN (0, 6);

  -- Get authorized employees
  IF v_user_role IN ('admin', 'super_admin') THEN
    IF p_employee_ids IS NOT NULL THEN
      v_authorized_employees := p_employee_ids;
    ELSE
      SELECT array_agg(id) INTO v_authorized_employees
      FROM employee_profiles
      WHERE employee_profiles.status = 'active';
    END IF;
  ELSE
    SELECT array_agg(es.employee_id) INTO v_authorized_employees
    FROM employee_supervisors es
    WHERE es.manager_id = v_user_id
      AND es.effective_to IS NULL
      AND (p_employee_ids IS NULL OR es.employee_id = ANY(p_employee_ids));
  END IF;

  IF v_authorized_employees IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH employee_shifts AS (
    SELECT
      s.employee_id,
      s.clocked_in_at::DATE AS work_date
    FROM shifts s
    WHERE s.employee_id = ANY(v_authorized_employees)
      AND s.clocked_in_at::DATE >= p_start_date
      AND s.clocked_in_at::DATE <= p_end_date
      AND s.clocked_out_at IS NOT NULL
    GROUP BY s.employee_id, s.clocked_in_at::DATE
  ),
  calendar AS (
    SELECT
      ep.id AS emp_id,
      ep.full_name AS emp_name,
      jsonb_object_agg(
        d::DATE::TEXT,
        EXISTS(SELECT 1 FROM employee_shifts es WHERE es.employee_id = ep.id AND es.work_date = d::DATE)
      ) AS cal_data,
      (SELECT COUNT(DISTINCT work_date) FROM employee_shifts es WHERE es.employee_id = ep.id)::INTEGER AS worked
    FROM employee_profiles ep
    CROSS JOIN generate_series(p_start_date, p_end_date, '1 day'::INTERVAL) d
    WHERE ep.id = ANY(v_authorized_employees)
    GROUP BY ep.id, ep.full_name
  )
  SELECT
    c.emp_id AS employee_id,
    c.emp_name AS employee_name,
    v_total_days AS total_working_days,
    c.worked AS days_worked,
    (v_total_days - c.worked) AS days_absent,
    ROUND((c.worked::DECIMAL / NULLIF(v_total_days, 0) * 100), 2) AS attendance_rate,
    c.cal_data AS calendar_data
  FROM calendar c
  ORDER BY c.emp_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- SCHEDULE MANAGEMENT FUNCTIONS
-- =====================================================

-- Function: create_report_schedule
CREATE OR REPLACE FUNCTION create_report_schedule(
  p_name TEXT,
  p_report_type TEXT,
  p_config JSONB,
  p_frequency TEXT,
  p_schedule_config JSONB
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_user_role TEXT;
  v_schedule_id UUID;
  v_next_run TIMESTAMPTZ;
BEGIN
  -- Get caller's role
  SELECT role INTO v_user_role
  FROM employee_profiles
  WHERE employee_profiles.id = v_user_id;

  IF v_user_role NOT IN ('admin', 'super_admin') THEN
    RETURN jsonb_build_object('error', 'Only admins can create schedules');
  END IF;

  -- Calculate next run time (simplified - would need timezone handling)
  v_next_run := NOW() + INTERVAL '1 day';

  -- Create schedule
  INSERT INTO report_schedules (
    user_id,
    name,
    report_type,
    config,
    frequency,
    schedule_config,
    next_run_at
  ) VALUES (
    v_user_id,
    p_name,
    p_report_type,
    p_config,
    p_frequency,
    p_schedule_config,
    v_next_run
  ) RETURNING id INTO v_schedule_id;

  -- Log the schedule creation
  INSERT INTO report_audit_logs (
    user_id,
    action,
    report_type,
    parameters,
    status
  ) VALUES (
    v_user_id,
    'scheduled',
    p_report_type,
    jsonb_build_object('schedule_id', v_schedule_id, 'name', p_name),
    'success'
  );

  RETURN jsonb_build_object(
    'schedule_id', v_schedule_id,
    'name', p_name,
    'next_run_at', v_next_run,
    'status', 'active'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: get_report_schedules
CREATE OR REPLACE FUNCTION get_report_schedules()
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_items JSONB;
  v_total INTEGER;
BEGIN
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', rs.id,
      'name', rs.name,
      'report_type', rs.report_type,
      'config', rs.config,
      'frequency', rs.frequency,
      'schedule_config', rs.schedule_config,
      'status', rs.status,
      'next_run_at', rs.next_run_at,
      'last_run_at', rs.last_run_at,
      'last_run_status', rs.last_run_status,
      'run_count', rs.run_count,
      'failure_count', rs.failure_count
    ) ORDER BY rs.created_at DESC
  ) INTO v_items
  FROM report_schedules rs
  WHERE rs.user_id = v_user_id
    AND rs.status != 'deleted';

  SELECT COUNT(*) INTO v_total
  FROM report_schedules
  WHERE user_id = v_user_id
    AND status != 'deleted';

  RETURN jsonb_build_object(
    'items', COALESCE(v_items, '[]'::jsonb),
    'total_count', v_total
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: update_report_schedule
CREATE OR REPLACE FUNCTION update_report_schedule(
  p_schedule_id UUID,
  p_name TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_config JSONB DEFAULT NULL,
  p_schedule_config JSONB DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_schedule RECORD;
BEGIN
  -- Get existing schedule
  SELECT * INTO v_schedule
  FROM report_schedules
  WHERE id = p_schedule_id AND user_id = v_user_id;

  IF v_schedule IS NULL THEN
    RETURN jsonb_build_object('error', 'Schedule not found');
  END IF;

  -- Update fields
  UPDATE report_schedules SET
    name = COALESCE(p_name, name),
    status = COALESCE(p_status, status),
    config = COALESCE(p_config, config),
    schedule_config = COALESCE(p_schedule_config, schedule_config),
    updated_at = NOW()
  WHERE id = p_schedule_id;

  RETURN jsonb_build_object(
    'id', p_schedule_id,
    'status', COALESCE(p_status, v_schedule.status),
    'updated_at', NOW()
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: delete_report_schedule
CREATE OR REPLACE FUNCTION delete_report_schedule(
  p_schedule_id UUID
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  UPDATE report_schedules
  SET status = 'deleted', updated_at = NOW()
  WHERE id = p_schedule_id AND user_id = v_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Schedule not found');
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- NOTIFICATION FUNCTIONS
-- =====================================================

-- Function: get_pending_report_notifications
CREATE OR REPLACE FUNCTION get_pending_report_notifications()
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_items JSONB;
  v_count INTEGER;
BEGIN
  SELECT jsonb_agg(
    jsonb_build_object(
      'job_id', rj.id,
      'report_type', rj.report_type,
      'completed_at', rj.completed_at,
      'schedule_name', rs.name
    ) ORDER BY rj.completed_at DESC
  ),
  COUNT(*)
  INTO v_items, v_count
  FROM report_jobs rj
  LEFT JOIN report_schedules rs ON rs.id = rj.schedule_id
  WHERE rj.user_id = v_user_id
    AND rj.status = 'completed'
    AND rj.notification_seen = false;

  RETURN jsonb_build_object(
    'count', COALESCE(v_count, 0),
    'items', COALESCE(v_items, '[]'::jsonb)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function: mark_report_notification_seen
CREATE OR REPLACE FUNCTION mark_report_notification_seen(
  p_job_id UUID
)
RETURNS JSONB AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  UPDATE report_jobs
  SET notification_seen = true
  WHERE id = p_job_id AND user_id = v_user_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false);
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- GRANT PERMISSIONS
-- =====================================================

GRANT EXECUTE ON FUNCTION count_report_records TO authenticated;
GRANT EXECUTE ON FUNCTION generate_report TO authenticated;
GRANT EXECUTE ON FUNCTION get_report_job_status TO authenticated;
GRANT EXECUTE ON FUNCTION get_report_history TO authenticated;
GRANT EXECUTE ON FUNCTION get_timesheet_report_data TO authenticated;
GRANT EXECUTE ON FUNCTION get_shift_history_export_data TO authenticated;
GRANT EXECUTE ON FUNCTION get_team_activity_summary TO authenticated;
GRANT EXECUTE ON FUNCTION get_attendance_report_data TO authenticated;
GRANT EXECUTE ON FUNCTION create_report_schedule TO authenticated;
GRANT EXECUTE ON FUNCTION get_report_schedules TO authenticated;
GRANT EXECUTE ON FUNCTION update_report_schedule TO authenticated;
GRANT EXECUTE ON FUNCTION delete_report_schedule TO authenticated;
GRANT EXECUTE ON FUNCTION get_pending_report_notifications TO authenticated;
GRANT EXECUTE ON FUNCTION mark_report_notification_seen TO authenticated;
