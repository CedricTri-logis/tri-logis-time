# Employee Hourly Rates & Weekend Cleaning Premium — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-employee hourly rates with period history, a global weekend cleaning premium for cleaning work sessions, a dashboard management page, and enriched timesheet export with pay calculations.

**Architecture:** Two new DB tables (`employee_hourly_rates`, `pay_settings`) + one new RPC (`get_timesheet_with_pay`) + one new dashboard page (`/dashboard/remuneration`) + enriched timesheet CSV/PDF export. Follows existing `employee_vehicle_periods` pattern for period-based data with overlap triggers.

**Tech Stack:** PostgreSQL (Supabase), Next.js 14+ (App Router), TypeScript, shadcn/ui, Tailwind, Zod, @tanstack/react-table, date-fns, lucide-react.

**Spec:** `docs/superpowers/specs/2026-03-12-employee-hourly-rates-design.md`

---

## Chunk 1: Database Migration

### Task 1: Create `employee_hourly_rates` and `pay_settings` tables

**Files:**
- Create: `supabase/migrations/20260312700000_employee_hourly_rates.sql`

- [ ] **Step 1: Write the migration file**

```sql
-- ============================================================
-- Migration: Employee Hourly Rates & Pay Settings
-- Feature: Per-employee hourly rates with period history
--          + global weekend cleaning premium
-- ============================================================

-- ===================
-- 1. pay_settings
-- ===================
CREATE TABLE IF NOT EXISTS pay_settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key TEXT UNIQUE NOT NULL,
  value JSONB NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now(),
  updated_by UUID REFERENCES employee_profiles(id)
);

-- Trigger: auto-update updated_at
CREATE TRIGGER update_pay_settings_updated_at
  BEFORE UPDATE ON pay_settings
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- RLS
ALTER TABLE pay_settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage pay_settings"
  ON pay_settings FOR ALL
  USING (is_admin_or_super_admin(auth.uid()))
  WITH CHECK (is_admin_or_super_admin(auth.uid()));

CREATE POLICY "Authenticated users can read pay_settings"
  ON pay_settings FOR SELECT
  USING (auth.role() = 'authenticated');

-- Seed default weekend cleaning premium
INSERT INTO pay_settings (key, value)
VALUES ('weekend_cleaning_premium', '{"amount": 0.00, "currency": "CAD"}');

-- Comments
COMMENT ON TABLE pay_settings IS
  'ROLE: Stores global pay configuration key-value pairs.
   STATUTS: N/A (config rows, not status-driven).
   REGLES: Only admins can modify. Authenticated users can read.
   RELATIONS: updated_by → employee_profiles.
   TRIGGERS: update_updated_at_column on UPDATE.';

COMMENT ON COLUMN pay_settings.key IS 'Unique config key, e.g. weekend_cleaning_premium';
COMMENT ON COLUMN pay_settings.value IS 'JSONB value — for weekend_cleaning_premium: {"amount": decimal, "currency": "CAD"}';

-- ===================
-- 2. employee_hourly_rates
-- ===================
CREATE TABLE IF NOT EXISTS employee_hourly_rates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  rate DECIMAL(10,2) NOT NULL CHECK (rate > 0),
  effective_from DATE NOT NULL,
  effective_to DATE NULL,
  created_by UUID REFERENCES employee_profiles(id),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  CONSTRAINT hourly_rate_dates_valid CHECK (effective_to IS NULL OR effective_to > effective_from),
  CONSTRAINT hourly_rate_unique_period UNIQUE (employee_id, effective_from)
);

-- Partial unique index: only one active (no end date) rate per employee
CREATE UNIQUE INDEX idx_employee_hourly_rates_active
  ON employee_hourly_rates(employee_id) WHERE effective_to IS NULL;

-- Performance index for per-day rate lookups
CREATE INDEX idx_employee_hourly_rates_lookup
  ON employee_hourly_rates(employee_id, effective_from DESC);

-- Trigger: auto-update updated_at
CREATE TRIGGER update_employee_hourly_rates_updated_at
  BEFORE UPDATE ON employee_hourly_rates
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- ===================
-- 3. Overlap prevention trigger
-- ===================
CREATE OR REPLACE FUNCTION check_hourly_rate_overlap()
RETURNS TRIGGER AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM employee_hourly_rates
    WHERE employee_id = NEW.employee_id
      AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
      AND effective_from < COALESCE(NEW.effective_to, '9999-12-31'::date)
      AND COALESCE(effective_to, '9999-12-31'::date) > NEW.effective_from
  ) THEN
    RAISE EXCEPTION 'Overlapping hourly rate period for employee %', NEW.employee_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_hourly_rate_overlap
  BEFORE INSERT OR UPDATE ON employee_hourly_rates
  FOR EACH ROW
  EXECUTE FUNCTION check_hourly_rate_overlap();

-- ===================
-- 4. RLS for employee_hourly_rates
-- ===================
ALTER TABLE employee_hourly_rates ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage hourly rates"
  ON employee_hourly_rates FOR ALL
  USING (is_admin_or_super_admin(auth.uid()))
  WITH CHECK (is_admin_or_super_admin(auth.uid()));

-- Comments
COMMENT ON TABLE employee_hourly_rates IS
  'ROLE: Stores per-employee hourly rates with period-based history.
   STATUTS: effective_to IS NULL means currently active rate.
   REGLES: No overlapping periods per employee (trigger). At most one active rate per employee (partial unique index). Rate must be > 0.
   RELATIONS: employee_id → employee_profiles (CASCADE), created_by → employee_profiles.
   TRIGGERS: check_hourly_rate_overlap (BEFORE INSERT/UPDATE), update_updated_at_column (BEFORE UPDATE).';

COMMENT ON COLUMN employee_hourly_rates.rate IS 'Hourly rate in CAD ($/h)';
COMMENT ON COLUMN employee_hourly_rates.effective_from IS 'Start date of this rate period (inclusive)';
COMMENT ON COLUMN employee_hourly_rates.effective_to IS 'End date of this rate period (inclusive). NULL = currently active.';
COMMENT ON COLUMN employee_hourly_rates.created_by IS 'Admin who created/modified this rate entry';

-- Grant
GRANT ALL ON employee_hourly_rates TO authenticated;
GRANT ALL ON pay_settings TO authenticated;
```

- [ ] **Step 2: Apply migration via MCP**

Run: `mcp__supabase__apply_migration` with the SQL above and name `employee_hourly_rates`.

- [ ] **Step 3: Verify tables exist**

Run SQL:
```sql
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name IN ('employee_hourly_rates', 'pay_settings')
ORDER BY table_name, ordinal_position;
```

Also verify the seed row:
```sql
SELECT * FROM pay_settings WHERE key = 'weekend_cleaning_premium';
```

- [ ] **Step 4: Verify overlap trigger works**

Run SQL to test:
```sql
-- Insert a test rate
INSERT INTO employee_hourly_rates (employee_id, rate, effective_from)
SELECT id, 20.00, '2026-01-01' FROM employee_profiles LIMIT 1;

-- Try overlapping — should fail
INSERT INTO employee_hourly_rates (employee_id, rate, effective_from)
SELECT employee_id, 25.00, '2026-01-15' FROM employee_hourly_rates LIMIT 1;

-- Clean up
DELETE FROM employee_hourly_rates;
```

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260312700000_employee_hourly_rates.sql
git commit -m "feat: add employee_hourly_rates and pay_settings tables"
```

---

### Task 2: Create `get_timesheet_with_pay` RPC

**Files:**
- Create: `supabase/migrations/20260312700001_get_timesheet_with_pay.sql`

- [ ] **Step 1: Write the RPC migration**

```sql
-- ============================================================
-- RPC: get_timesheet_with_pay
-- Returns per-day pay data for approved days within a date range.
-- Crosses: day_approvals (approved minutes), employee_hourly_rates
--          (rate on that date), work_sessions (cleaning on weekends),
--          pay_settings (weekend premium).
-- ============================================================

CREATE OR REPLACE FUNCTION get_timesheet_with_pay(
  p_start_date DATE,
  p_end_date DATE,
  p_employee_ids UUID[] DEFAULT NULL
)
RETURNS TABLE (
  employee_id UUID,
  full_name TEXT,
  employee_id_code TEXT,
  date DATE,
  approved_minutes INTEGER,
  hourly_rate DECIMAL(10,2),
  base_amount DECIMAL(10,2),
  weekend_cleaning_minutes INTEGER,
  weekend_premium_rate DECIMAL(10,2),
  premium_amount DECIMAL(10,2),
  total_amount DECIMAL(10,2),
  has_rate BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_caller_role TEXT;
  v_caller_id UUID := auth.uid();
  v_premium DECIMAL(10,2);
  v_supervised_ids UUID[];
BEGIN
  -- 1. Auth check
  SELECT role INTO v_caller_role
  FROM employee_profiles WHERE id = v_caller_id;

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('admin', 'super_admin', 'manager') THEN
    RAISE EXCEPTION 'Unauthorized: requires admin, super_admin, or manager role';
  END IF;

  -- 2. For managers, restrict to supervised employees
  IF v_caller_role = 'manager' THEN
    SELECT array_agg(es.employee_id) INTO v_supervised_ids
    FROM employee_supervisors es
    WHERE es.manager_id = v_caller_id
      AND es.effective_to IS NULL;

    IF p_employee_ids IS NOT NULL THEN
      -- Intersect requested with supervised
      p_employee_ids := ARRAY(
        SELECT unnest(p_employee_ids)
        INTERSECT
        SELECT unnest(v_supervised_ids)
      );
    ELSE
      p_employee_ids := v_supervised_ids;
    END IF;
  END IF;

  -- 3. Get weekend cleaning premium
  SELECT COALESCE((value->>'amount')::DECIMAL(10,2), 0.00) INTO v_premium
  FROM pay_settings WHERE key = 'weekend_cleaning_premium';

  IF v_premium IS NULL THEN
    v_premium := 0.00;
  END IF;

  -- 4. Return per-day rows
  RETURN QUERY
  WITH approved_days AS (
    SELECT
      da.employee_id,
      da.date,
      da.approved_minutes AS mins
    FROM day_approvals da
    WHERE da.status = 'approved'
      AND da.date BETWEEN p_start_date AND p_end_date
      AND (p_employee_ids IS NULL OR da.employee_id = ANY(p_employee_ids))
  ),
  rates AS (
    SELECT
      ehr.employee_id,
      ehr.rate,
      ehr.effective_from,
      ehr.effective_to
    FROM employee_hourly_rates ehr
    WHERE (p_employee_ids IS NULL OR ehr.employee_id = ANY(p_employee_ids))
  ),
  weekend_cleaning AS (
    SELECT
      ws.employee_id,
      (ws.started_at AT TIME ZONE 'America/Toronto')::DATE AS ws_date,
      SUM(
        EXTRACT(EPOCH FROM (
          COALESCE(ws.completed_at, now()) - ws.started_at
        )) / 60
      )::INTEGER AS cleaning_mins
    FROM work_sessions ws
    WHERE ws.activity_type = 'cleaning'
      AND ws.status IN ('completed', 'auto_closed', 'manually_closed')
      AND (ws.started_at AT TIME ZONE 'America/Toronto')::DATE BETWEEN p_start_date AND p_end_date
      AND EXTRACT(DOW FROM (ws.started_at AT TIME ZONE 'America/Toronto')) IN (0, 6) -- 0=Sun, 6=Sat
      AND (p_employee_ids IS NULL OR ws.employee_id = ANY(p_employee_ids))
    GROUP BY ws.employee_id, (ws.started_at AT TIME ZONE 'America/Toronto')::DATE
  )
  SELECT
    ad.employee_id,
    ep.full_name,
    ep.employee_id AS employee_id_code,
    ad.date,
    ad.mins AS approved_minutes,
    r.rate AS hourly_rate,
    COALESCE(ROUND((ad.mins / 60.0) * r.rate, 2), 0.00) AS base_amount,
    COALESCE(wc.cleaning_mins, 0) AS weekend_cleaning_minutes,
    v_premium AS weekend_premium_rate,
    COALESCE(ROUND((COALESCE(wc.cleaning_mins, 0) / 60.0) * v_premium, 2), 0.00) AS premium_amount,
    COALESCE(ROUND((ad.mins / 60.0) * r.rate, 2), 0.00)
      + COALESCE(ROUND((COALESCE(wc.cleaning_mins, 0) / 60.0) * v_premium, 2), 0.00) AS total_amount,
    r.rate IS NOT NULL AS has_rate
  FROM approved_days ad
  JOIN employee_profiles ep ON ep.id = ad.employee_id
  LEFT JOIN rates r ON r.employee_id = ad.employee_id
    AND r.effective_from <= ad.date
    AND (r.effective_to IS NULL OR r.effective_to >= ad.date)
  LEFT JOIN weekend_cleaning wc ON wc.employee_id = ad.employee_id AND wc.ws_date = ad.date
  ORDER BY ep.full_name, ad.date;
END;
$$;

GRANT EXECUTE ON FUNCTION get_timesheet_with_pay TO authenticated;

COMMENT ON FUNCTION get_timesheet_with_pay IS
  'Returns per-employee per-day pay data for approved days.
   Calculates base_amount (approved_minutes x hourly_rate) plus
   weekend cleaning premium (cleaning work_session minutes on Sat/Sun x global premium).
   Timezone: America/Toronto for weekend determination.
   Note: cross-midnight sessions are attributed to their start date (no splitting).';
```

- [ ] **Step 2: Apply migration via MCP**

Run: `mcp__supabase__apply_migration` with the SQL above and name `get_timesheet_with_pay`.

- [ ] **Step 3: Verify RPC works with test data**

Run SQL:
```sql
SELECT * FROM get_timesheet_with_pay('2026-03-01', '2026-03-12');
```

Expected: Returns rows for approved days in that range (may be empty if no approved days yet — that's OK, verify no errors).

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260312700001_get_timesheet_with_pay.sql
git commit -m "feat: add get_timesheet_with_pay RPC for pay calculations"
```

---

## Chunk 2: Dashboard Types, Validation & API

### Task 3: Add TypeScript types and Zod schemas

**Files:**
- Create: `dashboard/src/types/remuneration.ts`
- Create: `dashboard/src/lib/validations/remuneration.ts`

- [ ] **Step 1: Create type definitions**

Write `dashboard/src/types/remuneration.ts`:

```typescript
// Types for employee hourly rates & pay settings

export interface EmployeeHourlyRate {
  id: string;
  employee_id: string;
  rate: number;
  effective_from: string; // DATE as ISO string
  effective_to: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
}

export interface EmployeeHourlyRateWithCreator extends EmployeeHourlyRate {
  creator_name: string | null; // joined from employee_profiles
}

export interface EmployeeRateListItem {
  employee_id: string;
  full_name: string | null;
  employee_id_code: string | null;
  current_rate: number | null;
  effective_from: string | null;
}

export interface PaySetting {
  id: string;
  key: string;
  value: Record<string, unknown>;
  updated_at: string;
  updated_by: string | null;
}

export interface WeekendCleaningPremium {
  amount: number;
  currency: string;
}

export interface TimesheetWithPayRow {
  employee_id: string;
  full_name: string;
  employee_id_code: string;
  date: string;
  approved_minutes: number;
  hourly_rate: number | null;
  base_amount: number;
  weekend_cleaning_minutes: number;
  weekend_premium_rate: number;
  premium_amount: number;
  total_amount: number;
  has_rate: boolean;
}
```

- [ ] **Step 2: Create Zod validation schemas**

Write `dashboard/src/lib/validations/remuneration.ts`:

```typescript
import { z } from 'zod';

export const hourlyRateFormSchema = z.object({
  rate: z
    .number({ required_error: 'Le taux horaire est requis' })
    .positive('Le taux doit être supérieur à 0')
    .multipleOf(0.01, 'Maximum 2 décimales'),
  effective_from: z
    .string({ required_error: 'La date est requise' })
    .regex(/^\d{4}-\d{2}-\d{2}$/, 'Format de date invalide (AAAA-MM-JJ)'),
});

export type HourlyRateFormValues = z.infer<typeof hourlyRateFormSchema>;

export const weekendPremiumFormSchema = z.object({
  amount: z
    .number({ required_error: 'Le montant est requis' })
    .min(0, 'Le montant ne peut pas être négatif')
    .multipleOf(0.01, 'Maximum 2 décimales'),
});

export type WeekendPremiumFormValues = z.infer<typeof weekendPremiumFormSchema>;
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/types/remuneration.ts dashboard/src/lib/validations/remuneration.ts
git commit -m "feat: add remuneration types and Zod schemas"
```

---

### Task 4: Add API helper functions

**Files:**
- Create: `dashboard/src/lib/api/remuneration.ts`

- [ ] **Step 1: Create API helpers**

Write `dashboard/src/lib/api/remuneration.ts`:

```typescript
import { supabaseClient } from '@/lib/supabase/client';
import type {
  EmployeeHourlyRateWithCreator,
  EmployeeRateListItem,
  WeekendCleaningPremium,
  TimesheetWithPayRow,
} from '@/types/remuneration';

// ── Employee Hourly Rates ──

export async function getEmployeeRatesList(): Promise<EmployeeRateListItem[]> {
  // Get all employees with their current rate (if any)
  const { data, error } = await supabaseClient
    .from('employee_profiles')
    .select('id, full_name, employee_id')
    .eq('status', 'active')
    .order('full_name');

  if (error) throw error;

  // Get all active rates
  const { data: rates, error: ratesError } = await supabaseClient
    .from('employee_hourly_rates')
    .select('employee_id, rate, effective_from')
    .is('effective_to', null);

  if (ratesError) throw ratesError;

  const rateMap = new Map(
    (rates || []).map((r) => [r.employee_id, r])
  );

  return (data || []).map((emp) => {
    const rate = rateMap.get(emp.id);
    return {
      employee_id: emp.id,
      full_name: emp.full_name,
      employee_id_code: emp.employee_id,
      current_rate: rate?.rate ?? null,
      effective_from: rate?.effective_from ?? null,
    };
  });
}

export async function getEmployeeRateHistory(
  employeeId: string
): Promise<EmployeeHourlyRateWithCreator[]> {
  const { data, error } = await supabaseClient
    .from('employee_hourly_rates')
    .select(`
      *,
      creator:created_by(full_name)
    `)
    .eq('employee_id', employeeId)
    .order('effective_from', { ascending: false });

  if (error) throw error;

  return (data || []).map((row) => ({
    ...row,
    creator_name: (row.creator as any)?.full_name ?? null,
  }));
}

export async function upsertEmployeeRate(
  employeeId: string,
  rate: number,
  effectiveFrom: string
): Promise<void> {
  // Get current user for created_by
  const { data: { user } } = await supabaseClient.auth.getUser();

  // 1. Close current active rate (if any)
  const { data: activeRate } = await supabaseClient
    .from('employee_hourly_rates')
    .select('id')
    .eq('employee_id', employeeId)
    .is('effective_to', null)
    .single();

  if (activeRate) {
    // Close previous period: effective_to = day before new effective_from
    const closingDate = new Date(effectiveFrom);
    closingDate.setDate(closingDate.getDate() - 1);
    const closingDateStr = closingDate.toISOString().split('T')[0];

    const { error: updateError } = await supabaseClient
      .from('employee_hourly_rates')
      .update({ effective_to: closingDateStr })
      .eq('id', activeRate.id);

    if (updateError) throw updateError;
  }

  // 2. Insert new rate with created_by
  const { error: insertError } = await supabaseClient
    .from('employee_hourly_rates')
    .insert({
      employee_id: employeeId,
      rate,
      effective_from: effectiveFrom,
      effective_to: null,
      created_by: user?.id ?? null,
    });

  if (insertError) throw insertError;
}

// ── Pay Settings ──

export async function getWeekendPremium(): Promise<WeekendCleaningPremium> {
  const { data, error } = await supabaseClient
    .from('pay_settings')
    .select('value')
    .eq('key', 'weekend_cleaning_premium')
    .single();

  if (error) throw error;
  return data.value as WeekendCleaningPremium;
}

export async function updateWeekendPremium(amount: number): Promise<void> {
  const { error } = await supabaseClient
    .from('pay_settings')
    .update({
      value: { amount, currency: 'CAD' },
    })
    .eq('key', 'weekend_cleaning_premium');

  if (error) throw error;
}

// ── Timesheet with Pay ──

export async function getTimesheetWithPay(
  startDate: string,
  endDate: string,
  employeeIds?: string[]
): Promise<TimesheetWithPayRow[]> {
  const { data, error } = await supabaseClient.rpc('get_timesheet_with_pay', {
    p_start_date: startDate,
    p_end_date: endDate,
    p_employee_ids: employeeIds ?? null,
  });

  if (error) throw error;
  return data || [];
}
```

- [ ] **Step 2: Commit**

```bash
git add dashboard/src/lib/api/remuneration.ts
git commit -m "feat: add remuneration API helper functions"
```

---

## Chunk 3: Dashboard Rémunération Page

### Task 5: Add sidebar navigation entry

**Files:**
- Modify: `dashboard/src/components/layout/sidebar.tsx`

- [ ] **Step 1: Read sidebar file**

Read `dashboard/src/components/layout/sidebar.tsx` to find the navigation array and existing imports.

- [ ] **Step 2: Add DollarSign import and navigation entry**

Add `DollarSign` to the lucide-react import. Add the navigation entry after "Approbation" and before "Rapports":

```typescript
{
  name: 'Rémunération',
  href: '/dashboard/remuneration',
  icon: DollarSign,
},
```

- [ ] **Step 3: Commit**

```bash
git add dashboard/src/components/layout/sidebar.tsx
git commit -m "feat: add Rémunération entry to dashboard sidebar"
```

---

### Task 6: Create the Rémunération page

**Files:**
- Create: `dashboard/src/app/dashboard/remuneration/page.tsx`
- Create: `dashboard/src/components/remuneration/rates-table.tsx`
- Create: `dashboard/src/components/remuneration/rate-dialog.tsx`
- Create: `dashboard/src/components/remuneration/rate-history.tsx`
- Create: `dashboard/src/components/remuneration/premium-section.tsx`

- [ ] **Step 1: Create the page component**

Write `dashboard/src/app/dashboard/remuneration/page.tsx`:

```typescript
'use client';

import { useState, useEffect } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { RatesTable } from '@/components/remuneration/rates-table';
import { PremiumSection } from '@/components/remuneration/premium-section';
import { getEmployeeRatesList, getWeekendPremium } from '@/lib/api/remuneration';
import type { EmployeeRateListItem, WeekendCleaningPremium } from '@/types/remuneration';

export default function RemunerationPage() {
  const [employees, setEmployees] = useState<EmployeeRateListItem[]>([]);
  const [premium, setPremium] = useState<WeekendCleaningPremium | null>(null);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState<'all' | 'with_rate' | 'without_rate'>('all');
  const [error, setError] = useState<string | null>(null);

  const fetchData = async () => {
    setLoading(true);
    setError(null);
    try {
      const [empData, premData] = await Promise.all([
        getEmployeeRatesList(),
        getWeekendPremium(),
      ]);
      setEmployees(empData);
      setPremium(premData);
    } catch (e: any) {
      setError(e.message || 'Erreur lors du chargement des données');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { fetchData(); }, []);

  const filtered = employees.filter((emp) => {
    const matchesSearch = !search
      || (emp.full_name?.toLowerCase().includes(search.toLowerCase()))
      || (emp.employee_id_code?.toLowerCase().includes(search.toLowerCase()));
    const matchesFilter =
      filter === 'all' ? true
      : filter === 'with_rate' ? emp.current_rate !== null
      : emp.current_rate === null;
    return matchesSearch && matchesFilter;
  });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Rémunération</h1>
        <p className="text-muted-foreground">
          Gérer les taux horaires des employés et la prime de fin de semaine.
        </p>
      </div>

      {error && (
        <div className="rounded-md bg-destructive/15 p-3 text-sm text-destructive">
          {error}
        </div>
      )}

      <PremiumSection premium={premium} onUpdate={fetchData} />

      <Card>
        <CardHeader>
          <CardTitle>Taux horaires</CardTitle>
        </CardHeader>
        <CardContent>
          <RatesTable
            employees={filtered}
            loading={loading}
            search={search}
            onSearchChange={setSearch}
            filter={filter}
            onFilterChange={setFilter}
            onUpdate={fetchData}
          />
        </CardContent>
      </Card>
    </div>
  );
}
```

- [ ] **Step 2: Create PremiumSection component**

Write `dashboard/src/components/remuneration/premium-section.tsx`:

```typescript
'use client';

import { useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import { Pencil } from 'lucide-react';
import { updateWeekendPremium } from '@/lib/api/remuneration';
import type { WeekendCleaningPremium } from '@/types/remuneration';

interface PremiumSectionProps {
  premium: WeekendCleaningPremium | null;
  onUpdate: () => void;
}

export function PremiumSection({ premium, onUpdate }: PremiumSectionProps) {
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState('');
  const [saving, setSaving] = useState(false);

  const handleOpen = () => {
    setAmount(premium?.amount?.toString() ?? '0');
    setOpen(true);
  };

  const handleSave = async () => {
    const parsed = parseFloat(amount);
    if (isNaN(parsed) || parsed < 0) return;
    setSaving(true);
    try {
      await updateWeekendPremium(parsed);
      onUpdate();
      setOpen(false);
    } finally {
      setSaving(false);
    }
  };

  return (
    <>
      <Card>
        <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
          <CardTitle className="text-base font-medium">
            Prime fin de semaine — Ménage
          </CardTitle>
          <Button variant="ghost" size="sm" onClick={handleOpen}>
            <Pencil className="h-4 w-4 mr-1" /> Modifier
          </Button>
        </CardHeader>
        <CardContent>
          <div className="text-2xl font-bold">
            +{premium?.amount?.toFixed(2) ?? '0.00'} $/h
          </div>
          <p className="text-xs text-muted-foreground mt-1">
            S&apos;applique aux heures de sessions ménage le samedi et dimanche.
          </p>
        </CardContent>
      </Card>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Modifier la prime weekend</DialogTitle>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="premium-amount">Montant ($/h)</Label>
              <Input
                id="premium-amount"
                type="number"
                step="0.01"
                min="0"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)}>
              Annuler
            </Button>
            <Button onClick={handleSave} disabled={saving}>
              {saving ? 'Enregistrement...' : 'Enregistrer'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
```

- [ ] **Step 3: Create RatesTable component**

Write `dashboard/src/components/remuneration/rates-table.tsx`:

```typescript
'use client';

import { useState, useMemo, Fragment } from 'react';
import {
  useReactTable,
  getCoreRowModel,
  flexRender,
  type ColumnDef,
} from '@tanstack/react-table';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { ChevronDown, ChevronRight, Pencil } from 'lucide-react';
import { RateDialog } from './rate-dialog';
import { RateHistory } from './rate-history';
import type { EmployeeRateListItem } from '@/types/remuneration';

interface RatesTableProps {
  employees: EmployeeRateListItem[];
  loading: boolean;
  search: string;
  onSearchChange: (v: string) => void;
  filter: 'all' | 'with_rate' | 'without_rate';
  onFilterChange: (v: 'all' | 'with_rate' | 'without_rate') => void;
  onUpdate: () => void;
}

export function RatesTable({
  employees,
  loading,
  search,
  onSearchChange,
  filter,
  onFilterChange,
  onUpdate,
}: RatesTableProps) {
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [editingEmployee, setEditingEmployee] = useState<EmployeeRateListItem | null>(null);

  const columns = useMemo<ColumnDef<EmployeeRateListItem>[]>(
    () => [
      {
        id: 'expand',
        header: '',
        cell: ({ row }) => (
          <Button
            variant="ghost"
            size="sm"
            onClick={() =>
              setExpandedId(
                expandedId === row.original.employee_id
                  ? null
                  : row.original.employee_id
              )
            }
          >
            {expandedId === row.original.employee_id ? (
              <ChevronDown className="h-4 w-4" />
            ) : (
              <ChevronRight className="h-4 w-4" />
            )}
          </Button>
        ),
        size: 40,
      },
      {
        accessorKey: 'full_name',
        header: 'Nom',
        cell: ({ row }) => (
          <span className="font-medium">
            {row.original.full_name || '—'}
          </span>
        ),
      },
      {
        accessorKey: 'employee_id_code',
        header: 'ID employé',
        cell: ({ row }) => (
          <span className="text-muted-foreground">
            {row.original.employee_id_code || '—'}
          </span>
        ),
      },
      {
        accessorKey: 'current_rate',
        header: 'Taux actuel ($/h)',
        cell: ({ row }) =>
          row.original.current_rate !== null ? (
            <span className="font-mono">
              {row.original.current_rate.toFixed(2)} $
            </span>
          ) : (
            <span className="text-muted-foreground italic">Non défini</span>
          ),
      },
      {
        accessorKey: 'effective_from',
        header: 'En vigueur depuis',
        cell: ({ row }) =>
          row.original.effective_from ? (
            <span>{row.original.effective_from}</span>
          ) : (
            <span className="text-muted-foreground">—</span>
          ),
      },
      {
        id: 'actions',
        header: '',
        cell: ({ row }) => (
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setEditingEmployee(row.original)}
          >
            <Pencil className="h-4 w-4 mr-1" />
            Modifier
          </Button>
        ),
      },
    ],
    [expandedId]
  );

  const table = useReactTable({
    data: employees,
    columns,
    getCoreRowModel: getCoreRowModel(),
    getRowId: (row) => row.employee_id,
  });

  return (
    <div className="space-y-4">
      {/* Filters */}
      <div className="flex gap-4">
        <Input
          placeholder="Rechercher par nom..."
          value={search}
          onChange={(e) => onSearchChange(e.target.value)}
          className="max-w-sm"
        />
        <Select value={filter} onValueChange={(v) => onFilterChange(v as any)}>
          <SelectTrigger className="w-[200px]">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Tous les employés</SelectItem>
            <SelectItem value="with_rate">Avec taux</SelectItem>
            <SelectItem value="without_rate">Sans taux</SelectItem>
          </SelectContent>
        </Select>
      </div>

      {/* Table */}
      <div className="rounded-md border">
        <Table>
          <TableHeader>
            {table.getHeaderGroups().map((headerGroup) => (
              <TableRow key={headerGroup.id}>
                {headerGroup.headers.map((header) => (
                  <TableHead key={header.id}>
                    {flexRender(header.column.columnDef.header, header.getContext())}
                  </TableHead>
                ))}
              </TableRow>
            ))}
          </TableHeader>
          <TableBody>
            {loading ? (
              Array.from({ length: 5 }).map((_, i) => (
                <TableRow key={i}>
                  {columns.map((_, j) => (
                    <TableCell key={j}>
                      <div className="h-4 bg-muted rounded animate-pulse" />
                    </TableCell>
                  ))}
                </TableRow>
              ))
            ) : table.getRowModel().rows.length === 0 ? (
              <TableRow>
                <TableCell colSpan={columns.length} className="text-center py-8 text-muted-foreground">
                  Aucun employé trouvé
                </TableCell>
              </TableRow>
            ) : (
              table.getRowModel().rows.map((row) => (
                <Fragment key={row.id}>
                  <TableRow>
                    {row.getVisibleCells().map((cell) => (
                      <TableCell key={cell.id}>
                        {flexRender(cell.column.columnDef.cell, cell.getContext())}
                      </TableCell>
                    ))}
                  </TableRow>
                  {expandedId === row.original.employee_id && (
                    <TableRow>
                      <TableCell colSpan={columns.length} className="bg-muted/50 p-4">
                        <RateHistory employeeId={row.original.employee_id} />
                      </TableCell>
                    </TableRow>
                  )}
                </Fragment>
              ))
            )}
          </TableBody>
        </Table>
      </div>

      {/* Edit Dialog */}
      <RateDialog
        employee={editingEmployee}
        onClose={() => setEditingEmployee(null)}
        onSaved={() => {
          setEditingEmployee(null);
          onUpdate();
        }}
      />
    </div>
  );
}
```

- [ ] **Step 4: Create RateDialog component**

Write `dashboard/src/components/remuneration/rate-dialog.tsx`:

```typescript
'use client';

import { useState, useEffect } from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { upsertEmployeeRate } from '@/lib/api/remuneration';
import type { EmployeeRateListItem } from '@/types/remuneration';

interface RateDialogProps {
  employee: EmployeeRateListItem | null;
  onClose: () => void;
  onSaved: () => void;
}

export function RateDialog({ employee, onClose, onSaved }: RateDialogProps) {
  const [rate, setRate] = useState('');
  const [effectiveFrom, setEffectiveFrom] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (employee) {
      setRate(employee.current_rate?.toString() ?? '');
      setEffectiveFrom(new Date().toISOString().split('T')[0]);
      setError(null);
    }
  }, [employee]);

  const handleSave = async () => {
    setError(null);
    const parsedRate = parseFloat(rate);
    if (isNaN(parsedRate) || parsedRate <= 0) {
      setError('Le taux doit être supérieur à 0');
      return;
    }
    if (!effectiveFrom) {
      setError('La date est requise');
      return;
    }

    setSaving(true);
    try {
      await upsertEmployeeRate(employee!.employee_id, parsedRate, effectiveFrom);
      onSaved();
    } catch (e: any) {
      setError(e.message || 'Erreur lors de la sauvegarde');
    } finally {
      setSaving(false);
    }
  };

  return (
    <Dialog open={employee !== null} onOpenChange={() => onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {employee?.current_rate !== null
              ? `Modifier le taux — ${employee?.full_name}`
              : `Définir le taux — ${employee?.full_name}`}
          </DialogTitle>
        </DialogHeader>
        <div className="space-y-4 py-4">
          {employee?.current_rate !== null && (
            <p className="text-sm text-muted-foreground">
              Taux actuel : {employee?.current_rate?.toFixed(2)} $/h
              (depuis {employee?.effective_from})
            </p>
          )}
          <div className="space-y-2">
            <Label htmlFor="rate">Nouveau taux horaire ($/h)</Label>
            <Input
              id="rate"
              type="number"
              step="0.01"
              min="0.01"
              value={rate}
              onChange={(e) => setRate(e.target.value)}
              placeholder="ex: 20.00"
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="effective-from">Date d&apos;entrée en vigueur</Label>
            <Input
              id="effective-from"
              type="date"
              value={effectiveFrom}
              onChange={(e) => setEffectiveFrom(e.target.value)}
            />
          </div>
          {error && (
            <p className="text-sm text-destructive">{error}</p>
          )}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Annuler
          </Button>
          <Button onClick={handleSave} disabled={saving}>
            {saving ? 'Enregistrement...' : 'Enregistrer'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
```

- [ ] **Step 5: Create RateHistory component**

Write `dashboard/src/components/remuneration/rate-history.tsx`:

```typescript
'use client';

import { useState, useEffect } from 'react';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { getEmployeeRateHistory } from '@/lib/api/remuneration';
import type { EmployeeHourlyRateWithCreator } from '@/types/remuneration';

interface RateHistoryProps {
  employeeId: string;
}

export function RateHistory({ employeeId }: RateHistoryProps) {
  const [history, setHistory] = useState<EmployeeHourlyRateWithCreator[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    getEmployeeRateHistory(employeeId)
      .then(setHistory)
      .finally(() => setLoading(false));
  }, [employeeId]);

  if (loading) {
    return <div className="text-sm text-muted-foreground">Chargement...</div>;
  }

  if (history.length === 0) {
    return (
      <div className="text-sm text-muted-foreground">
        Aucun historique de taux pour cet employé.
      </div>
    );
  }

  return (
    <div>
      <h4 className="text-sm font-medium mb-2">Historique des taux</h4>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Taux ($/h)</TableHead>
            <TableHead>Du</TableHead>
            <TableHead>Au</TableHead>
            <TableHead>Créé par</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {history.map((entry) => (
            <TableRow key={entry.id}>
              <TableCell className="font-mono">{entry.rate.toFixed(2)} $</TableCell>
              <TableCell>{entry.effective_from}</TableCell>
              <TableCell>
                {entry.effective_to ?? (
                  <span className="text-green-600 font-medium">En cours</span>
                )}
              </TableCell>
              <TableCell className="text-muted-foreground">
                {entry.creator_name ?? '—'}
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
```

- [ ] **Step 6: Verify page builds**

Run: `cd dashboard && npm run build`

Expected: Build succeeds with no TypeScript errors on the remuneration page.

- [ ] **Step 7: Commit**

```bash
git add dashboard/src/app/dashboard/remuneration/ dashboard/src/components/remuneration/
git commit -m "feat: add Rémunération dashboard page with rates table and premium config"
```

---

## Chunk 4: Enriched Timesheet Export

### Task 7: Add pay columns to timesheet CSV export

**Files:**
- Modify: `dashboard/src/app/dashboard/reports/timesheet/page.tsx`
- Read: `dashboard/src/lib/exports/` (find existing CSV export helper)

- [ ] **Step 1: Read existing timesheet page and CSV export code**

Read `dashboard/src/app/dashboard/reports/timesheet/page.tsx` and locate the `exportTimesheetToCsv` function. Understand how the current CSV is built.

- [ ] **Step 2: Add pay data fetch alongside existing timesheet data**

In the timesheet page, after the existing `get_timesheet_report_data` RPC call, add a parallel call to `get_timesheet_with_pay` with the same date range and employee IDs. Store the pay data in state.

```typescript
import { getTimesheetWithPay } from '@/lib/api/remuneration';
import type { TimesheetWithPayRow } from '@/types/remuneration';

// Inside the generate handler, alongside existing RPC call:
const [timesheetData, payData] = await Promise.all([
  supabaseClient.rpc('get_timesheet_report_data', { /* existing params */ }),
  getTimesheetWithPay(start, end, employeeIds),
]);
```

- [ ] **Step 3: Modify CSV export to include pay columns**

Find the CSV export function and add new columns. Build a lookup map from pay data keyed by `${employee_id}_${date}`:

```typescript
// Build pay lookup
const payMap = new Map(
  payData.map((row) => [`${row.employee_id}_${row.date}`, row])
);

// In CSV row generation, add columns:
// Taux horaire ($/h), Montant de base ($), Heures ménage weekend, Prime weekend ($), Montant total ($)
```

Add the new column headers to the CSV header row and the corresponding values to each data row. For rows without pay data (unapproved days), leave pay columns empty.

- [ ] **Step 4: Verify CSV export includes pay columns**

Run: `cd dashboard && npm run build`

Then manually test: open the timesheet page, generate a report, and verify the CSV download includes the new columns.

- [ ] **Step 5: Commit**

```bash
git add dashboard/src/app/dashboard/reports/timesheet/
git commit -m "feat: add pay columns to timesheet CSV export"
```

---

### Task 8: Add pay data to timesheet PDF export

**Files:**
- Read existing PDF generation code (likely in an Edge Function or client-side)
- Modify the PDF template to include pay columns

- [ ] **Step 1: Locate PDF generation code**

Search for PDF generation in the dashboard: look for `pdf`, `jsPDF`, or Edge Function calls related to timesheet PDF. Read the relevant files.

- [ ] **Step 2: Add pay columns to PDF template**

Add the same 5 columns (Taux horaire, Montant de base, Heures ménage weekend, Prime weekend, Montant total) to the PDF table layout. Add per-employee subtotals and a grand total row at the bottom.

- [ ] **Step 3: Verify PDF generation**

Run build, then manually test PDF export to verify pay columns appear.

- [ ] **Step 4: Commit**

```bash
git commit -am "feat: add pay data to timesheet PDF export"
```

---

## Dependency Graph

```
Task 1 (DB tables) ──→ Task 2 (RPC) ──→ Task 7 (CSV export) ──→ Task 8 (PDF export)
                   ──→ Task 3 (types) ──→ Task 4 (API helpers) ──→ Task 6 (page)
                                                                ──→ Task 5 (sidebar)
```

**Parallelizable groups:**
- After Task 1: Tasks 2 and 3 can run in parallel
- After Tasks 2+3+4: Tasks 5, 6, and 7 can run in parallel
- Task 8 depends on Task 7

---

## Testing Checklist

After all tasks are complete:

- [ ] Employee hourly rates table has correct constraints (overlap trigger, partial unique index)
- [ ] Adding a new rate auto-closes the previous period
- [ ] Weekend premium can be read and updated from dashboard
- [ ] Rates table shows all active employees with current rate or "Non défini"
- [ ] Expanding a row shows rate history with creator name
- [ ] `get_timesheet_with_pay` returns correct base_amount and premium_amount
- [ ] Premium only applies to cleaning work_sessions on Sat/Sun
- [ ] CSV export includes pay columns with correct values
- [ ] PDF export includes pay columns with totals
- [ ] Manager access is restricted to supervised employees in the RPC
- [ ] `npm run build` succeeds with no TypeScript errors
