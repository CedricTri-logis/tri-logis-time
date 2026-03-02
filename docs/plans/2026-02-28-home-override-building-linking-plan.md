# Home Override & Building-Location Linking Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Link cleaning buildings and property buildings to location geofences, allow associating "home" locations to employees, and compute effective cluster types that override based on active cleaning/maintenance sessions.

**Architecture:** Three-layer approach: (1) Schema migration adding FKs, toggles, and `employee_home_locations` table, (2) Data backfill linking 72 property_buildings + 10 cleaning buildings to locations by name, (3) Update `detect_trips()` to compute `effective_location_type` on clusters. Dashboard gets new sections on the location edit page for home/office toggles and building links.

**Tech Stack:** PostgreSQL/Supabase (migrations, RPCs), Next.js/React (dashboard), TypeScript, Zod, shadcn/ui

---

### Task 1: Schema Migration — employee_home_locations, location flags, building FKs, cluster field

**Files:**
- Create: `supabase/migrations/093_home_override_schema.sql`

**Step 1: Write the migration**

```sql
-- Migration 093: Home override schema
-- Adds employee_home_locations table, is_employee_home/is_also_office flags on locations,
-- location_id FK on buildings and property_buildings, effective_location_type on stationary_clusters

-- 1. New columns on locations
ALTER TABLE locations ADD COLUMN is_employee_home BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE locations ADD COLUMN is_also_office BOOLEAN NOT NULL DEFAULT false;

-- 2. New FK on buildings (cleaning)
ALTER TABLE buildings ADD COLUMN location_id UUID REFERENCES locations(id) ON DELETE SET NULL;

-- 3. New FK on property_buildings (maintenance)
ALTER TABLE property_buildings ADD COLUMN location_id UUID REFERENCES locations(id) ON DELETE SET NULL;

-- 4. New column on stationary_clusters
ALTER TABLE stationary_clusters ADD COLUMN effective_location_type TEXT;

-- 5. New table: employee_home_locations
CREATE TABLE employee_home_locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  employee_id UUID NOT NULL REFERENCES employee_profiles(id) ON DELETE CASCADE,
  location_id UUID NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(employee_id, location_id)
);

-- Indexes
CREATE INDEX idx_employee_home_locations_employee ON employee_home_locations(employee_id);
CREATE INDEX idx_employee_home_locations_location ON employee_home_locations(location_id);
CREATE INDEX idx_buildings_location ON buildings(location_id);
CREATE INDEX idx_property_buildings_location ON property_buildings(location_id);

-- 6. RLS on employee_home_locations
ALTER TABLE employee_home_locations ENABLE ROW LEVEL SECURITY;

-- SELECT: admin/super_admin or supervisor of employee
CREATE POLICY employee_home_locations_select ON employee_home_locations
  FOR SELECT USING (
    is_admin_or_super_admin(auth.uid())
    OR employee_id IN (
      SELECT es.employee_id FROM employee_supervisors es
      WHERE es.supervisor_id = auth.uid()
    )
  );

-- INSERT/UPDATE/DELETE: admin/super_admin only
CREATE POLICY employee_home_locations_insert ON employee_home_locations
  FOR INSERT WITH CHECK (is_admin_or_super_admin(auth.uid()));

CREATE POLICY employee_home_locations_update ON employee_home_locations
  FOR UPDATE USING (is_admin_or_super_admin(auth.uid()));

CREATE POLICY employee_home_locations_delete ON employee_home_locations
  FOR DELETE USING (is_admin_or_super_admin(auth.uid()));
```

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

**Step 3: Verify**

Run SQL to confirm: `SELECT column_name FROM information_schema.columns WHERE table_name = 'locations' AND column_name IN ('is_employee_home', 'is_also_office');`

**Step 4: Commit**

```bash
git add supabase/migrations/093_home_override_schema.sql
git commit -m "feat: add home override schema — employee_home_locations, building FKs, cluster effective type"
```

---

### Task 2: Backfill Migration — Link existing buildings and property_buildings to locations

**Files:**
- Create: `supabase/migrations/094_backfill_building_location_links.sql`

**Step 1: Write the backfill migration**

```sql
-- Migration 094: Backfill building-location links
-- Links property_buildings and cleaning buildings to their matching locations by name

-- 1. Link property_buildings to locations by exact name match (72 of 77 match)
UPDATE property_buildings pb
SET location_id = l.id
FROM locations l
WHERE l.name = pb.name
  AND l.is_active = true
  AND pb.location_id IS NULL;

-- 2. Link cleaning buildings to locations using known mapping from short_term.building_studio_mapping
-- (from Tri-logis.ca Supabase project)

-- Le Cardinal → 254-258_Cardinal-Begin-E
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '254-258_Cardinal-Begin-E')
WHERE name = 'Le Cardinal' AND location_id IS NULL;

-- Le Central → 22-28_Gamble-O
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '22-28_Gamble-O')
WHERE name = 'Le Central' AND location_id IS NULL;

-- Le Centre-Ville → 14-20_Perreault-E
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '14-20_Perreault-E')
WHERE name = 'Le Centre-Ville' AND location_id IS NULL;

-- Le Chambreur → 110-114_Mgr-Tessier-O
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '110-114_Mgr-Tessier-O')
WHERE name = 'Le Chambreur' AND location_id IS NULL;

-- Le Chic-urbain → 151-159_Principale (the office!)
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '151-159_Principale')
WHERE name = 'Le Chic-urbain' AND location_id IS NULL;

-- Le Cinq Étoiles → 500_Boutour
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '500_Boutour')
WHERE name = 'Le Cinq Étoiles' AND location_id IS NULL;

-- Le Citadin → 45_Perreault-E
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '45_Perreault-E')
WHERE name = 'Le Citadin' AND location_id IS NULL;

-- Le Contemporain → 296-300_Principale
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '296-300_Principale')
WHERE name = 'Le Contemporain' AND location_id IS NULL;

-- Le Convivial → 62-66_Perreault-E
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '62-66_Perreault-E')
WHERE name = 'Le Convivial' AND location_id IS NULL;

-- Le Court-toit → 96_Horne
UPDATE buildings SET location_id = (SELECT id FROM locations WHERE name = '96_Horne')
WHERE name = 'Le Court-toit' AND location_id IS NULL;

-- 3. Mark 151-159_Principale as also an office (Le Chic-urbain is office + building)
UPDATE locations SET is_also_office = true WHERE name = '151-159_Principale';
```

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

**Step 3: Verify the links**

Run SQL:
```sql
-- Verify cleaning buildings
SELECT b.name, b.location_id, l.name as location_name
FROM buildings b LEFT JOIN locations l ON l.id = b.location_id
ORDER BY b.name;

-- Verify property buildings (count linked)
SELECT COUNT(*) as linked FROM property_buildings WHERE location_id IS NOT NULL;

-- Verify office flag
SELECT name, is_also_office FROM locations WHERE name = '151-159_Principale';
```

Expected: 10 cleaning buildings linked, ~72 property_buildings linked, 151-159_Principale has `is_also_office = true`.

**Step 4: Commit**

```bash
git add supabase/migrations/094_backfill_building_location_links.sql
git commit -m "feat: backfill building-location links — 72 property_buildings + 10 cleaning buildings"
```

---

### Task 3: Update detect_trips — compute effective_location_type on clusters

**Files:**
- Create: `supabase/migrations/095_detect_trips_effective_type.sql`
- Reference: `supabase/migrations/088_detect_trips_gps_gap_resilience.sql` (current detect_trips)

**Step 1: Write the migration**

This migration adds a new step at the end of `detect_trips()` that computes `effective_location_type` for all clusters in the shift. It runs AFTER all clusters and trips are created.

The full `detect_trips` function is large (~600 lines). The migration should use `CREATE OR REPLACE FUNCTION` and copy the existing function body from migration 088, adding the new effective_type computation block at the end (before the final RETURN QUERY).

**Implementation approach:**
1. Read the full current `detect_trips` function from migration 088
2. Add the effective_type computation as a new block just before the final `RETURN QUERY`
3. The new block iterates over all clusters for this shift and computes the effective type

**New block to add (pseudocode → actual SQL):**

```sql
-- =========================================================================
-- STEP H: Compute effective_location_type for clusters
-- Priority: (1) cleaning/maintenance session → 'building'
--           (2) employee home association → 'home'
--           (3) is_also_office flag → 'office'
--           (4) default → location.location_type
-- =========================================================================
UPDATE stationary_clusters sc
SET effective_location_type = CASE
  -- Priority 1: Active cleaning session at linked building
  WHEN EXISTS (
    SELECT 1 FROM cleaning_sessions cs
    JOIN studios s ON s.id = cs.studio_id
    JOIN buildings b ON b.id = s.building_id
    WHERE b.location_id = sc.matched_location_id
      AND cs.employee_id = p_employee_id
      AND cs.shift_id = p_shift_id
      AND cs.started_at < sc.ended_at
      AND (cs.completed_at > sc.started_at OR cs.completed_at IS NULL)
  ) THEN 'building'
  -- Priority 1b: Active maintenance session at linked property building
  WHEN EXISTS (
    SELECT 1 FROM maintenance_sessions ms
    JOIN property_buildings pb ON pb.id = ms.building_id
    WHERE pb.location_id = sc.matched_location_id
      AND ms.employee_id = p_employee_id
      AND ms.shift_id = p_shift_id
      AND ms.started_at < sc.ended_at
      AND (ms.completed_at > sc.started_at OR ms.completed_at IS NULL)
  ) THEN 'building'
  -- Priority 2: Employee home association
  WHEN EXISTS (
    SELECT 1 FROM locations l
    JOIN employee_home_locations ehl ON ehl.location_id = l.id
    WHERE l.id = sc.matched_location_id
      AND l.is_employee_home = true
      AND ehl.employee_id = p_employee_id
  ) THEN 'home'
  -- Priority 3: Office flag
  WHEN EXISTS (
    SELECT 1 FROM locations l
    WHERE l.id = sc.matched_location_id
      AND l.is_also_office = true
  ) THEN 'office'
  -- Priority 4: Default location type
  ELSE (
    SELECT l.location_type::TEXT FROM locations l
    WHERE l.id = sc.matched_location_id
  )
END
WHERE sc.shift_id = p_shift_id
  AND sc.matched_location_id IS NOT NULL;
```

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

**Step 3: Verify with a test query**

Run SQL against a known shift that has clusters at the office location:
```sql
SELECT sc.id, sc.matched_location_id, l.name, l.location_type, sc.effective_location_type
FROM stationary_clusters sc
LEFT JOIN locations l ON l.id = sc.matched_location_id
WHERE sc.shift_id = '<known_shift_id>'
ORDER BY sc.started_at;
```

**Step 4: Commit**

```bash
git add supabase/migrations/095_detect_trips_effective_type.sql
git commit -m "feat: detect_trips computes effective_location_type on clusters"
```

---

### Task 4: Update get_employee_activity — return effective_location_type for stops

**Files:**
- Create: `supabase/migrations/096_activity_effective_location_type.sql`
- Reference: `supabase/migrations/089_activity_gps_gap_fields.sql` (current get_employee_activity)

**Step 1: Write the migration**

Add `effective_location_type TEXT` to the RETURNS TABLE of `get_employee_activity()`. For stop rows, populate it from `stationary_clusters.effective_location_type`. For trip and clock_event rows, set it to NULL.

The full function is ~200 lines. The migration replaces the function with the new output column.

Key changes:
- Add `effective_location_type TEXT` to RETURNS TABLE
- In the stop query (UNION ALL block for stops), add `sc.effective_location_type`
- In trip and clock_event blocks, add `NULL::TEXT as effective_location_type`

**Step 2: Apply the migration**

Run: `cd supabase && supabase db push`

**Step 3: Verify**

```sql
SELECT activity_type, matched_location_name, effective_location_type
FROM get_employee_activity('<employee_id>', '<date>')
WHERE activity_type = 'stop'
LIMIT 5;
```

**Step 4: Commit**

```bash
git add supabase/migrations/096_activity_effective_location_type.sql
git commit -m "feat: get_employee_activity returns effective_location_type for stops"
```

---

### Task 5: Dashboard — Update LocationRow type and location form with home/office toggles

**Files:**
- Modify: `dashboard/src/types/location.ts` (add `is_employee_home`, `is_also_office` to LocationRow and Location)
- Modify: `dashboard/src/lib/validations/location.ts` (add to form schema)
- Modify: `dashboard/src/components/locations/location-form.tsx` (add toggle sections)
- Modify: `dashboard/src/app/dashboard/locations/[id]/page.tsx` (pass new fields to update)
- Modify: `dashboard/src/lib/hooks/use-locations.ts` (pass new fields)

**Step 1: Update TypeScript types**

In `dashboard/src/types/location.ts`:
- Add to `LocationRow`: `is_employee_home: boolean; is_also_office: boolean;`
- Add to `Location`: `isEmployeeHome: boolean; isAlsoOffice: boolean;`
- Update `transformLocationRow()` to map the new fields
- Add to `LocationFormData`: `isEmployeeHome: boolean; isAlsoOffice: boolean;`

**Step 2: Update validation schema**

In `dashboard/src/lib/validations/location.ts`:
- Add to `locationFormSchema`: `is_employee_home: z.boolean().default(false)` and `is_also_office: z.boolean().default(false)`

**Step 3: Update LocationForm component**

In `dashboard/src/components/locations/location-form.tsx`:
- Add default values for `is_employee_home` and `is_also_office` from location prop
- Add two new Card sections after the Notes card:

**"Maison d'employe(s)" section:**
```tsx
<Card>
  <CardHeader>
    <CardTitle className="text-base">Maison d'employe(s)</CardTitle>
  </CardHeader>
  <CardContent>
    <FormField
      control={form.control}
      name="is_employee_home"
      render={({ field }) => (
        <FormItem className="flex flex-row items-center justify-between rounded-lg border p-3">
          <div className="space-y-0.5">
            <FormLabel>Ce lieu est la maison d'employe(s)</FormLabel>
            <FormDescription className="text-xs">
              Les clusters de ces employes seront affiches comme "Maison" sauf si une session menage/entretien est active
            </FormDescription>
          </div>
          <FormControl>
            <input type="checkbox" checked={field.value} onChange={field.onChange} className="h-4 w-4 rounded border-slate-300" />
          </FormControl>
        </FormItem>
      )}
    />
  </CardContent>
</Card>
```

**"Aussi un bureau" section:**
```tsx
<Card>
  <CardHeader>
    <CardTitle className="text-base">Bureau</CardTitle>
  </CardHeader>
  <CardContent>
    <FormField
      control={form.control}
      name="is_also_office"
      render={({ field }) => (
        <FormItem className="flex flex-row items-center justify-between rounded-lg border p-3">
          <div className="space-y-0.5">
            <FormLabel>Ce lieu est aussi un bureau</FormLabel>
            <FormDescription className="text-xs">
              Les clusters de tous les employes seront affiches comme "Bureau" sauf si une session menage/entretien est active
            </FormDescription>
          </div>
          <FormControl>
            <input type="checkbox" checked={field.value} onChange={field.onChange} className="h-4 w-4 rounded border-slate-300" />
          </FormControl>
        </FormItem>
      )}
    />
  </CardContent>
</Card>
```

**Step 4: Update location detail page**

In `dashboard/src/app/dashboard/locations/[id]/page.tsx`:
- Pass `isEmployeeHome` and `isAlsoOffice` in the `updateLocation()` call

**Step 5: Update use-locations hook**

In `dashboard/src/lib/hooks/use-locations.ts`:
- Include `is_employee_home` and `is_also_office` in UPDATE payload

**Step 6: Test in browser**

Navigate to `/dashboard/locations/<id>` for any location. Verify:
- Two new toggle sections appear
- Toggles save correctly on form submit
- Page reloads with saved values

**Step 7: Commit**

```bash
git add dashboard/src/types/location.ts dashboard/src/lib/validations/location.ts dashboard/src/components/locations/location-form.tsx dashboard/src/app/dashboard/locations/\\[id\\]/page.tsx dashboard/src/lib/hooks/use-locations.ts
git commit -m "feat: dashboard location form — home employee and office toggles"
```

---

### Task 6: Dashboard — Employee home picker on location edit page

**Files:**
- Create: `dashboard/src/components/locations/employee-home-picker.tsx`
- Modify: `dashboard/src/app/dashboard/locations/[id]/page.tsx` (add picker below form)

**Step 1: Create the EmployeeHomePicker component**

This component:
- Shows only when `is_employee_home` is true on the location
- Fetches current `employee_home_locations` for this location_id
- Displays a list of associated employees with remove buttons
- Has an "Add employee" combobox (searches employee_profiles by name)
- INSERT/DELETE on `employee_home_locations` table directly via Supabase client

```tsx
// dashboard/src/components/locations/employee-home-picker.tsx
'use client';

import { useState, useEffect, useCallback } from 'react';
import { supabaseClient } from '@/lib/supabase/client';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { X, Plus, Search, Loader2, Home } from 'lucide-react';
import { toast } from 'sonner';

interface EmployeeHomePickerProps {
  locationId: string;
  isEmployeeHome: boolean;
}

interface EmployeeRow {
  id: string;
  first_name: string;
  last_name: string;
}

export function EmployeeHomePicker({ locationId, isEmployeeHome }: EmployeeHomePickerProps) {
  const [employees, setEmployees] = useState<EmployeeRow[]>([]);
  const [searchResults, setSearchResults] = useState<EmployeeRow[]>([]);
  const [search, setSearch] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [isSearching, setIsSearching] = useState(false);

  // Fetch associated employees
  const fetchEmployees = useCallback(async () => {
    setIsLoading(true);
    const { data } = await supabaseClient
      .from('employee_home_locations')
      .select('employee_id')
      .eq('location_id', locationId);

    if (data && data.length > 0) {
      const ids = data.map((d) => d.employee_id);
      const { data: profiles } = await supabaseClient
        .from('employee_profiles')
        .select('id, first_name, last_name')
        .in('id', ids)
        .order('first_name');
      setEmployees(profiles ?? []);
    } else {
      setEmployees([]);
    }
    setIsLoading(false);
  }, [locationId]);

  useEffect(() => {
    if (isEmployeeHome) fetchEmployees();
  }, [isEmployeeHome, fetchEmployees]);

  // Search employees
  const handleSearch = useCallback(async (query: string) => {
    setSearch(query);
    if (query.length < 2) { setSearchResults([]); return; }
    setIsSearching(true);
    const { data } = await supabaseClient
      .from('employee_profiles')
      .select('id, first_name, last_name')
      .or(`first_name.ilike.%${query}%,last_name.ilike.%${query}%`)
      .order('first_name')
      .limit(10);
    // Filter out already associated
    const existingIds = new Set(employees.map((e) => e.id));
    setSearchResults((data ?? []).filter((e) => !existingIds.has(e.id)));
    setIsSearching(false);
  }, [employees]);

  // Add employee
  const handleAdd = useCallback(async (employeeId: string) => {
    const { error } = await supabaseClient
      .from('employee_home_locations')
      .insert({ employee_id: employeeId, location_id: locationId });
    if (error) { toast.error('Erreur lors de l\'ajout'); return; }
    toast.success('Employe associe');
    setSearch('');
    setSearchResults([]);
    fetchEmployees();
  }, [locationId, fetchEmployees]);

  // Remove employee
  const handleRemove = useCallback(async (employeeId: string) => {
    const { error } = await supabaseClient
      .from('employee_home_locations')
      .delete()
      .eq('employee_id', employeeId)
      .eq('location_id', locationId);
    if (error) { toast.error('Erreur lors de la suppression'); return; }
    toast.success('Association supprimee');
    fetchEmployees();
  }, [locationId, fetchEmployees]);

  if (!isEmployeeHome) return null;

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base flex items-center gap-2">
          <Home className="h-4 w-4" />
          Employes associes a ce domicile
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        {isLoading ? (
          <Loader2 className="h-4 w-4 animate-spin" />
        ) : (
          <>
            {employees.map((emp) => (
              <div key={emp.id} className="flex items-center justify-between rounded-lg border p-2">
                <span className="text-sm">{emp.first_name} {emp.last_name}</span>
                <Button variant="ghost" size="icon" onClick={() => handleRemove(emp.id)}>
                  <X className="h-4 w-4 text-red-500" />
                </Button>
              </div>
            ))}
            {employees.length === 0 && (
              <p className="text-sm text-slate-500">Aucun employe associe</p>
            )}
            <div className="relative">
              <div className="flex gap-2">
                <Input
                  placeholder="Rechercher un employe..."
                  value={search}
                  onChange={(e) => handleSearch(e.target.value)}
                />
                {isSearching && <Loader2 className="h-4 w-4 animate-spin absolute right-3 top-3" />}
              </div>
              {searchResults.length > 0 && (
                <div className="absolute z-10 w-full mt-1 bg-white border rounded-md shadow-lg max-h-48 overflow-y-auto">
                  {searchResults.map((emp) => (
                    <button
                      key={emp.id}
                      className="w-full text-left px-3 py-2 hover:bg-slate-50 text-sm flex items-center gap-2"
                      onClick={() => handleAdd(emp.id)}
                    >
                      <Plus className="h-3 w-3" />
                      {emp.first_name} {emp.last_name}
                    </button>
                  ))}
                </div>
              )}
            </div>
          </>
        )}
      </CardContent>
    </Card>
  );
}
```

**Step 2: Add to location detail page**

In `dashboard/src/app/dashboard/locations/[id]/page.tsx`, after `<LocationForm ... />`:

```tsx
import { EmployeeHomePicker } from '@/components/locations/employee-home-picker';

// Inside the return, after <LocationForm ... />:
<EmployeeHomePicker
  locationId={id}
  isEmployeeHome={location.isEmployeeHome}
/>
```

**Step 3: Test in browser**

- Set `is_employee_home = true` on a location, save
- Verify the employee picker appears
- Search and add an employee
- Verify the association in the database
- Remove the employee
- Set toggle to false, verify picker hides

**Step 4: Commit**

```bash
git add dashboard/src/components/locations/employee-home-picker.tsx dashboard/src/app/dashboard/locations/\\[id\\]/page.tsx
git commit -m "feat: employee home picker on location edit page"
```

---

### Task 7: Dashboard — Building link dropdowns on location edit page

**Files:**
- Create: `dashboard/src/components/locations/building-link-section.tsx`
- Modify: `dashboard/src/app/dashboard/locations/[id]/page.tsx` (add building link section)

**Step 1: Create the BuildingLinkSection component**

This component:
- Shows two dropdowns: one for cleaning buildings, one for property buildings
- Fetches buildings that currently link to this location_id
- Allows changing the link (UPDATE buildings SET location_id)

```tsx
// dashboard/src/components/locations/building-link-section.tsx
'use client';

import { useState, useEffect, useCallback } from 'react';
import { supabaseClient } from '@/lib/supabase/client';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Label } from '@/components/ui/label';
import { Building, Loader2 } from 'lucide-react';
import { toast } from 'sonner';

interface BuildingLinkSectionProps {
  locationId: string;
}

interface BuildingOption {
  id: string;
  name: string;
  location_id: string | null;
}

export function BuildingLinkSection({ locationId }: BuildingLinkSectionProps) {
  const [cleaningBuildings, setCleaningBuildings] = useState<BuildingOption[]>([]);
  const [propertyBuildings, setPropertyBuildings] = useState<BuildingOption[]>([]);
  const [linkedCleaning, setLinkedCleaning] = useState<string>('none');
  const [linkedProperty, setLinkedProperty] = useState<string>('none');
  const [isLoading, setIsLoading] = useState(true);

  const fetchData = useCallback(async () => {
    setIsLoading(true);
    const [{ data: cb }, { data: pb }] = await Promise.all([
      supabaseClient.from('buildings').select('id, name, location_id').order('name'),
      supabaseClient.from('property_buildings').select('id, name, location_id').order('name'),
    ]);
    setCleaningBuildings(cb ?? []);
    setPropertyBuildings(pb ?? []);
    setLinkedCleaning(cb?.find((b) => b.location_id === locationId)?.id ?? 'none');
    setLinkedProperty(pb?.find((b) => b.location_id === locationId)?.id ?? 'none');
    setIsLoading(false);
  }, [locationId]);

  useEffect(() => { fetchData(); }, [fetchData]);

  const handleCleaningChange = useCallback(async (buildingId: string) => {
    // Unlink previous
    if (linkedCleaning !== 'none') {
      await supabaseClient.from('buildings').update({ location_id: null }).eq('id', linkedCleaning);
    }
    // Link new
    if (buildingId !== 'none') {
      const { error } = await supabaseClient.from('buildings').update({ location_id: locationId }).eq('id', buildingId);
      if (error) { toast.error('Erreur'); return; }
    }
    setLinkedCleaning(buildingId);
    toast.success('Building menage mis a jour');
  }, [locationId, linkedCleaning]);

  const handlePropertyChange = useCallback(async (buildingId: string) => {
    if (linkedProperty !== 'none') {
      await supabaseClient.from('property_buildings').update({ location_id: null }).eq('id', linkedProperty);
    }
    if (buildingId !== 'none') {
      const { error } = await supabaseClient.from('property_buildings').update({ location_id: locationId }).eq('id', buildingId);
      if (error) { toast.error('Erreur'); return; }
    }
    setLinkedProperty(buildingId);
    toast.success('Building entretien mis a jour');
  }, [locationId, linkedProperty]);

  if (isLoading) return <Card><CardContent className="py-6"><Loader2 className="h-4 w-4 animate-spin" /></CardContent></Card>;

  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base flex items-center gap-2">
          <Building className="h-4 w-4" />
          Buildings lies
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="space-y-2">
          <Label>Building menage (cleaning)</Label>
          <Select value={linkedCleaning} onValueChange={handleCleaningChange}>
            <SelectTrigger><SelectValue placeholder="Aucun" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="none">Aucun</SelectItem>
              {cleaningBuildings
                .filter((b) => b.location_id === null || b.location_id === locationId)
                .map((b) => (
                  <SelectItem key={b.id} value={b.id}>{b.name}</SelectItem>
                ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-2">
          <Label>Building entretien (property)</Label>
          <Select value={linkedProperty} onValueChange={handlePropertyChange}>
            <SelectTrigger><SelectValue placeholder="Aucun" /></SelectTrigger>
            <SelectContent>
              <SelectItem value="none">Aucun</SelectItem>
              {propertyBuildings
                .filter((b) => b.location_id === null || b.location_id === locationId)
                .map((b) => (
                  <SelectItem key={b.id} value={b.id}>{b.name}</SelectItem>
                ))}
            </SelectContent>
          </Select>
        </div>
      </CardContent>
    </Card>
  );
}
```

**Step 2: Add to location detail page**

In `dashboard/src/app/dashboard/locations/[id]/page.tsx`, after EmployeeHomePicker:

```tsx
import { BuildingLinkSection } from '@/components/locations/building-link-section';

// After EmployeeHomePicker:
<BuildingLinkSection locationId={id} />
```

**Step 3: Test in browser**

- Navigate to a location that should have a linked building
- Verify the dropdowns show the correct linked buildings
- Change links and verify in database
- Verify already-linked buildings don't appear in other location's dropdowns

**Step 4: Commit**

```bash
git add dashboard/src/components/locations/building-link-section.tsx dashboard/src/app/dashboard/locations/\\[id\\]/page.tsx
git commit -m "feat: building link dropdowns on location edit page"
```

---

### Task 8: Dashboard — Show effective_location_type in activity tab

**Files:**
- Modify: `dashboard/src/types/mileage.ts` (add `effective_location_type` to ActivityStop)
- Modify: `dashboard/src/components/mileage/activity-tab.tsx` (use effective type for stop icon/label)

**Step 1: Update ActivityStop type**

In `dashboard/src/types/mileage.ts`, add to ActivityStop:
```typescript
effective_location_type?: string | null;
```

**Step 2: Update activity tab stop rendering**

In the stop rendering section of `activity-tab.tsx`, when displaying the location type icon and label, use `effective_location_type ?? location_type` (or the equivalent field from the activity response).

**Step 3: Test**

- View an employee's activity for a day where they had clusters at the office with cleaning sessions
- Verify the stop shows "Immeuble" instead of "Bureau" when override is active

**Step 4: Commit**

```bash
git add dashboard/src/types/mileage.ts dashboard/src/components/mileage/activity-tab.tsx
git commit -m "feat: activity tab displays effective location type for stops"
```

---

### Task 9: Backfill existing clusters — recalculate effective_location_type

**Files:**
- Create: `supabase/migrations/097_backfill_effective_location_type.sql`

**Step 1: Write the backfill migration**

This runs the same UPDATE logic from detect_trips' Step H against ALL existing clusters that have a `matched_location_id` but no `effective_location_type`:

```sql
-- Migration 097: Backfill effective_location_type for existing clusters
-- Sets effective type based on current building links, home associations, and office flags.
-- Only affects clusters with a matched location.

UPDATE stationary_clusters sc
SET effective_location_type = CASE
  WHEN EXISTS (
    SELECT 1 FROM cleaning_sessions cs
    JOIN studios s ON s.id = cs.studio_id
    JOIN buildings b ON b.id = s.building_id
    WHERE b.location_id = sc.matched_location_id
      AND cs.employee_id = sc.employee_id
      AND cs.shift_id = sc.shift_id
      AND cs.started_at < sc.ended_at
      AND (cs.completed_at > sc.started_at OR cs.completed_at IS NULL)
  ) THEN 'building'
  WHEN EXISTS (
    SELECT 1 FROM maintenance_sessions ms
    JOIN property_buildings pb ON pb.id = ms.building_id
    WHERE pb.location_id = sc.matched_location_id
      AND ms.employee_id = sc.employee_id
      AND ms.shift_id = sc.shift_id
      AND ms.started_at < sc.ended_at
      AND (ms.completed_at > sc.started_at OR ms.completed_at IS NULL)
  ) THEN 'building'
  WHEN EXISTS (
    SELECT 1 FROM locations l
    JOIN employee_home_locations ehl ON ehl.location_id = l.id
    WHERE l.id = sc.matched_location_id
      AND l.is_employee_home = true
      AND ehl.employee_id = sc.employee_id
  ) THEN 'home'
  WHEN EXISTS (
    SELECT 1 FROM locations l
    WHERE l.id = sc.matched_location_id
      AND l.is_also_office = true
  ) THEN 'office'
  ELSE (
    SELECT l.location_type::TEXT FROM locations l
    WHERE l.id = sc.matched_location_id
  )
END
WHERE sc.matched_location_id IS NOT NULL
  AND sc.effective_location_type IS NULL;
```

**Step 2: Apply and verify**

Run: `cd supabase && supabase db push`

Verify:
```sql
SELECT effective_location_type, COUNT(*)
FROM stationary_clusters
WHERE matched_location_id IS NOT NULL
GROUP BY effective_location_type;
```

**Step 3: Commit**

```bash
git add supabase/migrations/097_backfill_effective_location_type.sql
git commit -m "feat: backfill effective_location_type for all existing clusters"
```

---

### Task 10: Update MEMORY.md with new migration numbers

**Files:**
- Modify: `/Users/cedric/.claude/projects/-Users-cedric-Desktop-PROJECT-TEST-GPS-Tracker/memory/MEMORY.md`

**Step 1: Update migration numbering**

Update:
- Last applied: 097
- Next available: 098
- Add entries for 093-097

**Step 2: Commit (memory files are not git-tracked)**

No commit needed for memory files.
