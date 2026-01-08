-- GPS Clock-In Tracker: Initial Database Schema
-- Migration: 001_initial_schema
-- Date: 2026-01-08
-- Feature: Project Foundation

-- =============================================================================
-- EXTENSIONS
-- =============================================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =============================================================================
-- TABLES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- employee_profiles: User profile data linked to auth.users
-- -----------------------------------------------------------------------------
CREATE TABLE employee_profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT NOT NULL UNIQUE,
    full_name TEXT,
    employee_id TEXT,
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'inactive', 'suspended')),
    privacy_consent_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE employee_profiles IS 'Employee profile data extending auth.users';
COMMENT ON COLUMN employee_profiles.privacy_consent_at IS 'Required before location tracking (Constitution III)';

-- Indexes
CREATE INDEX idx_employee_profiles_email ON employee_profiles(email);
CREATE INDEX idx_employee_profiles_status ON employee_profiles(status);

-- -----------------------------------------------------------------------------
-- shifts: Work sessions with clock in/out times and locations
-- -----------------------------------------------------------------------------
CREATE TABLE shifts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    request_id UUID UNIQUE,  -- Idempotency key for clock operations
    status TEXT NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'completed')),
    clocked_in_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    clock_in_location JSONB,  -- {latitude: number, longitude: number}
    clock_in_accuracy DECIMAL(8, 2),  -- GPS accuracy in meters
    clocked_out_at TIMESTAMPTZ,
    clock_out_location JSONB,
    clock_out_accuracy DECIMAL(8, 2),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT shift_clock_times_valid CHECK (
        clocked_out_at IS NULL OR clocked_out_at > clocked_in_at
    )
);

COMMENT ON TABLE shifts IS 'Work sessions with clock in/out tracking';
COMMENT ON COLUMN shifts.request_id IS 'Client-provided idempotency key for clock operations';

-- Indexes
CREATE INDEX idx_shifts_employee_id ON shifts(employee_id);
CREATE INDEX idx_shifts_status ON shifts(status);
CREATE INDEX idx_shifts_employee_active ON shifts(employee_id) WHERE status = 'active';
CREATE INDEX idx_shifts_clocked_in_at ON shifts(clocked_in_at DESC);

-- -----------------------------------------------------------------------------
-- gps_points: Location captures during active shifts
-- -----------------------------------------------------------------------------
CREATE TABLE gps_points (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id UUID NOT NULL UNIQUE,  -- Client-generated UUID for deduplication
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
    latitude DECIMAL(10, 8) NOT NULL
        CHECK (latitude >= -90.0 AND latitude <= 90.0),
    longitude DECIMAL(11, 8) NOT NULL
        CHECK (longitude >= -180.0 AND longitude <= 180.0),
    accuracy DECIMAL(8, 2),  -- GPS accuracy in meters
    captured_at TIMESTAMPTZ NOT NULL,  -- Client timestamp
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),  -- Server timestamp
    device_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE gps_points IS 'GPS location captures during active shifts';
COMMENT ON COLUMN gps_points.client_id IS 'Client-generated UUID for offline deduplication';
COMMENT ON COLUMN gps_points.captured_at IS 'Client device timestamp when GPS was captured';
COMMENT ON COLUMN gps_points.received_at IS 'Server timestamp when sync occurred';

-- Indexes
CREATE INDEX idx_gps_points_shift_id ON gps_points(shift_id);
CREATE INDEX idx_gps_points_employee_id ON gps_points(employee_id);
CREATE INDEX idx_gps_points_captured_at ON gps_points(captured_at DESC);

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================

ALTER TABLE employee_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE gps_points ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- employee_profiles RLS policies
-- -----------------------------------------------------------------------------
CREATE POLICY "Users can view own profile"
ON employee_profiles FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = id);

CREATE POLICY "Users can update own profile"
ON employee_profiles FOR UPDATE TO authenticated
USING ((SELECT auth.uid()) = id)
WITH CHECK ((SELECT auth.uid()) = id);

-- -----------------------------------------------------------------------------
-- shifts RLS policies
-- -----------------------------------------------------------------------------
CREATE POLICY "Users can view own shifts"
ON shifts FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = employee_id);

CREATE POLICY "Users can insert own shifts"
ON shifts FOR INSERT TO authenticated
WITH CHECK ((SELECT auth.uid()) = employee_id);

CREATE POLICY "Users can update own shifts"
ON shifts FOR UPDATE TO authenticated
USING ((SELECT auth.uid()) = employee_id)
WITH CHECK ((SELECT auth.uid()) = employee_id);

-- -----------------------------------------------------------------------------
-- gps_points RLS policies
-- -----------------------------------------------------------------------------
CREATE POLICY "Users can view own GPS points"
ON gps_points FOR SELECT TO authenticated
USING ((SELECT auth.uid()) = employee_id);

CREATE POLICY "Users can insert own GPS points"
ON gps_points FOR INSERT TO authenticated
WITH CHECK ((SELECT auth.uid()) = employee_id);

-- GPS points are immutable - no UPDATE or DELETE policies

-- =============================================================================
-- TRIGGERS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Auto-create employee_profile on user signup
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.employee_profiles (id, email)
    VALUES (NEW.id, NEW.email);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- -----------------------------------------------------------------------------
-- Update updated_at timestamp on row changes
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_employee_profiles_updated_at
    BEFORE UPDATE ON employee_profiles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_shifts_updated_at
    BEFORE UPDATE ON shifts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- =============================================================================
-- FUNCTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- clock_in: Idempotent clock-in operation with validation
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clock_in(
    p_request_id UUID,
    p_location JSONB DEFAULT NULL,
    p_accuracy DECIMAL DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_existing_shift shifts%ROWTYPE;
    v_new_shift shifts%ROWTYPE;
    v_has_consent BOOLEAN;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    -- Check for privacy consent (Constitution III)
    SELECT privacy_consent_at IS NOT NULL INTO v_has_consent
    FROM employee_profiles WHERE id = v_user_id;

    IF NOT v_has_consent THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'message', 'Privacy consent required before clock in'
        );
    END IF;

    -- Check for duplicate request (idempotency)
    SELECT * INTO v_existing_shift FROM shifts
    WHERE request_id = p_request_id;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'status', 'already_processed',
            'shift_id', v_existing_shift.id,
            'clocked_in_at', v_existing_shift.clocked_in_at
        );
    END IF;

    -- Check for active shift
    SELECT * INTO v_existing_shift FROM shifts
    WHERE employee_id = v_user_id AND status = 'active';

    IF FOUND THEN
        RETURN jsonb_build_object(
            'status', 'error',
            'message', 'Already clocked in',
            'active_shift_id', v_existing_shift.id
        );
    END IF;

    -- Create new shift
    INSERT INTO shifts (
        employee_id, request_id, clocked_in_at,
        clock_in_location, clock_in_accuracy
    )
    VALUES (v_user_id, p_request_id, NOW(), p_location, p_accuracy)
    RETURNING * INTO v_new_shift;

    RETURN jsonb_build_object(
        'status', 'success',
        'shift_id', v_new_shift.id,
        'clocked_in_at', v_new_shift.clocked_in_at
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- clock_out: Idempotent clock-out operation with validation
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION clock_out(
    p_shift_id UUID,
    p_request_id UUID,
    p_location JSONB DEFAULT NULL,
    p_accuracy DECIMAL DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_shift shifts%ROWTYPE;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    -- Get shift and verify ownership
    SELECT * INTO v_shift FROM shifts
    WHERE id = p_shift_id AND employee_id = v_user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Shift not found');
    END IF;

    -- Check if already clocked out (idempotency via status check)
    IF v_shift.status = 'completed' THEN
        RETURN jsonb_build_object(
            'status', 'already_processed',
            'shift_id', v_shift.id,
            'clocked_out_at', v_shift.clocked_out_at
        );
    END IF;

    -- Update shift
    UPDATE shifts SET
        status = 'completed',
        clocked_out_at = NOW(),
        clock_out_location = p_location,
        clock_out_accuracy = p_accuracy
    WHERE id = p_shift_id
    RETURNING * INTO v_shift;

    RETURN jsonb_build_object(
        'status', 'success',
        'shift_id', v_shift.id,
        'clocked_out_at', v_shift.clocked_out_at
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- -----------------------------------------------------------------------------
-- sync_gps_points: Batch insert GPS points with deduplication
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sync_gps_points(p_points JSONB)
RETURNS JSONB AS $$
DECLARE
    v_user_id UUID;
    v_point JSONB;
    v_inserted INTEGER := 0;
    v_duplicates INTEGER := 0;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('status', 'error', 'message', 'Not authenticated');
    END IF;

    FOR v_point IN SELECT * FROM jsonb_array_elements(p_points)
    LOOP
        BEGIN
            INSERT INTO gps_points (
                client_id, shift_id, employee_id,
                latitude, longitude, accuracy,
                captured_at, device_id
            )
            VALUES (
                (v_point->>'client_id')::UUID,
                (v_point->>'shift_id')::UUID,
                v_user_id,
                (v_point->>'latitude')::DECIMAL,
                (v_point->>'longitude')::DECIMAL,
                (v_point->>'accuracy')::DECIMAL,
                (v_point->>'captured_at')::TIMESTAMPTZ,
                v_point->>'device_id'
            );
            v_inserted := v_inserted + 1;
        EXCEPTION WHEN unique_violation THEN
            v_duplicates := v_duplicates + 1;
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'status', 'success',
        'inserted', v_inserted,
        'duplicates', v_duplicates
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
