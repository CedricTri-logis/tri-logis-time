-- Migration 038: Diagnostic Logs
-- Server-side table for receiving diagnostic events from mobile devices.
-- Enables remote visibility into GPS tracking failures, shift issues, and sync problems.

-- Create diagnostic_logs table
CREATE TABLE IF NOT EXISTS diagnostic_logs (
  id UUID PRIMARY KEY,
  employee_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  shift_id UUID,
  device_id TEXT NOT NULL,
  event_category TEXT NOT NULL CHECK (event_category IN ('gps', 'shift', 'sync', 'auth', 'permission', 'lifecycle', 'thermal', 'error', 'network')),
  severity TEXT NOT NULL CHECK (severity IN ('info', 'warn', 'error', 'critical')),
  message TEXT NOT NULL,
  metadata JSONB,
  app_version TEXT NOT NULL,
  platform TEXT NOT NULL CHECK (platform IN ('ios', 'android')),
  os_version TEXT,
  created_at TIMESTAMPTZ NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_diag_logs_employee ON diagnostic_logs (employee_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_diag_logs_shift ON diagnostic_logs (shift_id) WHERE shift_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_diag_logs_category ON diagnostic_logs (event_category, severity);
CREATE INDEX IF NOT EXISTS idx_diag_logs_created ON diagnostic_logs (created_at DESC);

-- Enable RLS
ALTER TABLE diagnostic_logs ENABLE ROW LEVEL SECURITY;

-- RLS: Employees can insert their own diagnostic logs
CREATE POLICY "Employees can insert own diagnostic logs"
  ON diagnostic_logs
  FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = employee_id);

-- RLS: Admins and managers can read all diagnostic logs
CREATE POLICY "Admins and managers can read diagnostic logs"
  ON diagnostic_logs
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM employee_profiles
      WHERE employee_profiles.id = auth.uid()
        AND employee_profiles.role IN ('admin', 'manager')
    )
  );

-- RPC: Batch sync diagnostic logs from mobile devices
CREATE OR REPLACE FUNCTION sync_diagnostic_logs(p_events JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_event JSONB;
  v_inserted INT := 0;
  v_duplicates INT := 0;
  v_errors INT := 0;
  v_caller_id UUID := auth.uid();
BEGIN
  FOR v_event IN SELECT * FROM jsonb_array_elements(p_events)
  LOOP
    BEGIN
      -- Verify caller owns the event
      IF (v_event->>'employee_id')::UUID != v_caller_id THEN
        v_errors := v_errors + 1;
        CONTINUE;
      END IF;

      INSERT INTO diagnostic_logs (
        id, employee_id, shift_id, device_id,
        event_category, severity, message, metadata,
        app_version, platform, os_version, created_at
      ) VALUES (
        (v_event->>'id')::UUID,
        (v_event->>'employee_id')::UUID,
        NULLIF(v_event->>'shift_id', '')::UUID,
        v_event->>'device_id',
        v_event->>'event_category',
        v_event->>'severity',
        v_event->>'message',
        (v_event->'metadata')::JSONB,
        v_event->>'app_version',
        v_event->>'platform',
        v_event->>'os_version',
        (v_event->>'created_at')::TIMESTAMPTZ
      );
      v_inserted := v_inserted + 1;
    EXCEPTION
      WHEN unique_violation THEN
        v_duplicates := v_duplicates + 1;
      WHEN OTHERS THEN
        v_errors := v_errors + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'success',
    'inserted', v_inserted,
    'duplicates', v_duplicates,
    'errors', v_errors
  );
END;
$$;

-- Retention: Clean up diagnostic logs older than 90 days (daily at 3am UTC)
SELECT cron.schedule(
  'cleanup-diagnostic-logs',
  '0 3 * * *',
  $$DELETE FROM diagnostic_logs WHERE created_at < NOW() - INTERVAL '90 days'$$
);
