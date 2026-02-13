# Spec 014: Gestion des Lieux de Travail (Geofences) et Segmentation des Shifts

## Vue d'Ensemble

Cette spécification détaille l'implémentation d'un système de gestion de lieux géographiques (geofences) permettant de segmenter automatiquement les shifts des employés en fonction de leur position GPS.

### Objectifs
- Créer/gérer des zones géographiques (bureau, chantier, fournisseur, domicile)
- Configurer le rayon de détection (10-1000m)
- Géocoder des adresses via Google Maps API
- Importer en masse via CSV
- Visualiser sur carte interactive avec cercles de geofence
- Segmenter les shifts en timeline colorée par type de lieu

### Décisions Techniques
- **Geocodage**: Google Maps Geocoding API (nécessite clé API dans env)
- **Matching GPS**: À la demande (lors de la consultation de la timeline, pas de trigger temps réel)
- **Auto-détection**: Prévu pour une phase ultérieure (clustering DBSCAN)

---

## Contexte du Projet

### Architecture Existante

```
GPS_Tracker/
├── dashboard/                    # Next.js 14+ App Router
│   ├── src/
│   │   ├── app/dashboard/       # Pages protégées
│   │   ├── components/          # Composants React
│   │   ├── lib/
│   │   │   ├── hooks/           # React hooks personnalisés
│   │   │   ├── utils/           # Utilitaires (distance.ts, etc.)
│   │   │   ├── validations/     # Schemas Zod
│   │   │   └── providers/       # Refine data provider
│   │   └── types/               # Types TypeScript
│   └── package.json
├── supabase/
│   └── migrations/              # Migrations PostgreSQL (001-014)
└── gps_tracker/                 # App Flutter (mobile)
```

### Technologies Dashboard
- **Framework**: Next.js 14+ (App Router)
- **UI**: shadcn/ui, Tailwind CSS
- **State/Data**: Refine (@refinedev/supabase)
- **Validation**: Zod
- **Cartes**: react-leaflet 5.0.0, Leaflet 1.9.4
- **Dates**: date-fns 4.1.0
- **TypeScript**: 5.x strict mode

### Tables Supabase Existantes
- `employee_profiles` - Profils employés
- `shifts` - Shifts (clocked_in_at, clocked_out_at, status)
- `gps_points` - Points GPS (latitude, longitude, accuracy, captured_at, shift_id)
- `employee_supervisors` - Relations superviseur-employé

### Utilitaires Existants

**`dashboard/src/lib/utils/distance.ts`**:
```typescript
// Calcul distance Haversine entre 2 points GPS
export function haversineDistance(
  lat1: number, lon1: number,
  lat2: number, lon2: number
): number;

// Distance totale d'un trajet
export function calculateTotalDistance(points: GpsPoint[]): number;

// Formatage distance (m ou km)
export function formatDistance(meters: number): string;
```

---

## Phase 1: Schema Base de Données

### Migration: `015_location_geofences.sql`

```sql
-- Enable PostGIS extension if not already enabled
CREATE EXTENSION IF NOT EXISTS postgis;

-- ============================================
-- Table: locations (geofences)
-- ============================================
CREATE TABLE locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id),
  name TEXT NOT NULL,
  location_type TEXT NOT NULL CHECK (location_type IN ('office', 'building', 'vendor', 'home', 'other')),
  -- PostGIS geometry pour requêtes spatiales optimisées
  location GEOMETRY(Point, 4326),
  latitude DECIMAL(10, 8) NOT NULL CHECK (latitude >= -90.0 AND latitude <= 90.0),
  longitude DECIMAL(11, 8) NOT NULL CHECK (longitude >= -180.0 AND longitude <= 180.0),
  radius_meters DECIMAL(10, 2) NOT NULL DEFAULT 100 CHECK (radius_meters >= 10 AND radius_meters <= 1000),
  address TEXT,
  notes TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Trigger pour auto-générer la colonne geometry depuis lat/lng
CREATE OR REPLACE FUNCTION update_location_geometry()
RETURNS TRIGGER AS $$
BEGIN
  NEW.location := ST_SetSRID(ST_MakePoint(NEW.longitude::float, NEW.latitude::float), 4326);
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER locations_geometry_trigger
  BEFORE INSERT OR UPDATE ON locations
  FOR EACH ROW EXECUTE FUNCTION update_location_geometry();

-- Index spatial pour requêtes de proximité rapides
CREATE INDEX idx_locations_geometry ON locations USING GIST(location);
CREATE INDEX idx_locations_type ON locations(location_type);
CREATE INDEX idx_locations_active ON locations(is_active) WHERE is_active = true;
CREATE INDEX idx_locations_user ON locations(user_id);

-- ============================================
-- Table: location_matches (GPS point <-> Location associations)
-- ============================================
CREATE TABLE location_matches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  gps_point_id UUID NOT NULL REFERENCES gps_points(id) ON DELETE CASCADE,
  location_id UUID NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  distance_meters DECIMAL(10, 2) NOT NULL,
  confidence_score DECIMAL(3, 2) CHECK (confidence_score >= 0 AND confidence_score <= 1),
  matched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(gps_point_id, location_id)
);

CREATE INDEX idx_location_matches_gps_point ON location_matches(gps_point_id);
CREATE INDEX idx_location_matches_location ON location_matches(location_id);

-- ============================================
-- RLS Policies
-- ============================================
ALTER TABLE locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE location_matches ENABLE ROW LEVEL SECURITY;

-- Locations: visible par tous les users authentifiés (pour le matching)
CREATE POLICY "Users can view all active locations"
  ON locations FOR SELECT
  TO authenticated
  USING (is_active = true);

-- Locations: CRUD par le propriétaire ou admin
CREATE POLICY "Users can manage their own locations"
  ON locations FOR ALL
  TO authenticated
  USING (user_id = auth.uid());

-- Location matches: visibles selon les permissions sur gps_points
CREATE POLICY "Users can view location matches for accessible gps_points"
  ON location_matches FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM gps_points gp
      WHERE gp.id = gps_point_id
      AND (
        gp.employee_id IN (
          SELECT ep.id FROM employee_profiles ep
          WHERE ep.user_id = auth.uid()
          OR EXISTS (
            SELECT 1 FROM employee_supervisors es
            WHERE es.supervisor_id = auth.uid()
            AND es.employee_id = ep.id
          )
        )
      )
    )
  );
```

### Fonctions RPC

```sql
-- ============================================
-- Function: get_locations_paginated
-- ============================================
CREATE OR REPLACE FUNCTION get_locations_paginated(
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0,
  p_type TEXT DEFAULT NULL,
  p_search TEXT DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT true
)
RETURNS TABLE (
  id UUID,
  user_id UUID,
  name TEXT,
  location_type TEXT,
  latitude DECIMAL,
  longitude DECIMAL,
  radius_meters DECIMAL,
  address TEXT,
  notes TEXT,
  is_active BOOLEAN,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  total_count BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total BIGINT;
BEGIN
  -- Count total matching records
  SELECT COUNT(*) INTO v_total
  FROM locations l
  WHERE (p_is_active IS NULL OR l.is_active = p_is_active)
    AND (p_type IS NULL OR l.location_type = p_type)
    AND (p_search IS NULL OR l.name ILIKE '%' || p_search || '%' OR l.address ILIKE '%' || p_search || '%');

  RETURN QUERY
  SELECT
    l.id,
    l.user_id,
    l.name,
    l.location_type,
    l.latitude,
    l.longitude,
    l.radius_meters,
    l.address,
    l.notes,
    l.is_active,
    l.created_at,
    l.updated_at,
    v_total
  FROM locations l
  WHERE (p_is_active IS NULL OR l.is_active = p_is_active)
    AND (p_type IS NULL OR l.location_type = p_type)
    AND (p_search IS NULL OR l.name ILIKE '%' || p_search || '%' OR l.address ILIKE '%' || p_search || '%')
  ORDER BY l.name
  LIMIT p_limit
  OFFSET p_offset;
END;
$$;

-- ============================================
-- Function: match_shift_gps_to_locations
-- Matches all GPS points of a shift to nearby locations
-- ============================================
CREATE OR REPLACE FUNCTION match_shift_gps_to_locations(p_shift_id UUID)
RETURNS TABLE (
  gps_point_id UUID,
  location_id UUID,
  location_name TEXT,
  location_type TEXT,
  distance_meters DECIMAL,
  confidence_score DECIMAL
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Delete existing matches for this shift's GPS points
  DELETE FROM location_matches
  WHERE gps_point_id IN (SELECT id FROM gps_points WHERE shift_id = p_shift_id);

  -- Insert new matches and return them
  RETURN QUERY
  WITH gps_with_geometry AS (
    SELECT
      gp.id AS gps_id,
      ST_SetSRID(ST_MakePoint(gp.longitude, gp.latitude), 4326) AS gps_location
    FROM gps_points gp
    WHERE gp.shift_id = p_shift_id
  ),
  matches AS (
    SELECT DISTINCT ON (g.gps_id)
      g.gps_id,
      l.id AS loc_id,
      l.name AS loc_name,
      l.location_type AS loc_type,
      ST_Distance(g.gps_location::geography, l.location::geography) AS dist_meters,
      -- Confidence: 1.0 at center, decreasing to 0 at radius edge
      GREATEST(0, 1 - (ST_Distance(g.gps_location::geography, l.location::geography) / l.radius_meters)) AS conf
    FROM gps_with_geometry g
    CROSS JOIN locations l
    WHERE l.is_active = true
      AND ST_DWithin(g.gps_location::geography, l.location::geography, l.radius_meters)
    ORDER BY g.gps_id, dist_meters ASC
  )
  INSERT INTO location_matches (gps_point_id, location_id, distance_meters, confidence_score)
  SELECT gps_id, loc_id, dist_meters, conf
  FROM matches
  RETURNING
    location_matches.gps_point_id,
    location_matches.location_id,
    (SELECT name FROM locations WHERE id = location_matches.location_id),
    (SELECT location_type FROM locations WHERE id = location_matches.location_id),
    location_matches.distance_meters,
    location_matches.confidence_score;
END;
$$;

-- ============================================
-- Function: get_shift_timeline
-- Returns segmented timeline of a shift
-- ============================================
CREATE OR REPLACE FUNCTION get_shift_timeline(p_shift_id UUID)
RETURNS TABLE (
  segment_index INTEGER,
  segment_type TEXT,
  start_time TIMESTAMPTZ,
  end_time TIMESTAMPTZ,
  duration_seconds INTEGER,
  location_id UUID,
  location_name TEXT,
  point_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- First, ensure GPS points are matched to locations
  PERFORM match_shift_gps_to_locations(p_shift_id);

  RETURN QUERY
  WITH shift_points AS (
    -- Get all GPS points for the shift with their location matches
    SELECT
      gp.id AS gps_id,
      gp.captured_at,
      lm.location_id,
      l.name AS location_name,
      l.location_type,
      CASE WHEN lm.id IS NOT NULL THEN true ELSE false END AS is_matched,
      ROW_NUMBER() OVER (ORDER BY gp.captured_at) AS point_index
    FROM gps_points gp
    LEFT JOIN location_matches lm ON lm.gps_point_id = gp.id
    LEFT JOIN locations l ON l.id = lm.location_id
    WHERE gp.shift_id = p_shift_id
    ORDER BY gp.captured_at
  ),
  point_pairs AS (
    -- Create pairs of consecutive points to determine segment type
    SELECT
      p1.point_index AS start_index,
      p2.point_index AS end_index,
      p1.captured_at AS start_time,
      p2.captured_at AS end_time,
      p1.is_matched AS start_matched,
      p1.location_type AS start_loc_type,
      p1.location_id AS start_loc_id,
      p1.location_name AS start_loc_name,
      p2.is_matched AS end_matched,
      p2.location_type AS end_loc_type,
      -- Determine segment type
      CASE
        WHEN NOT p1.is_matched AND NOT p2.is_matched THEN 'unmatched'
        WHEN NOT p1.is_matched OR NOT p2.is_matched THEN 'travel'
        WHEN p1.location_id = p2.location_id THEN p1.location_type
        WHEN p1.location_type = p2.location_type THEN p1.location_type
        ELSE 'mixed'
      END AS seg_type,
      EXTRACT(EPOCH FROM (p2.captured_at - p1.captured_at)) AS duration_sec
    FROM shift_points p1
    JOIN shift_points p2 ON p2.point_index = p1.point_index + 1
  ),
  segments_with_boundaries AS (
    -- Mark segment boundaries where type changes
    SELECT
      *,
      CASE
        WHEN LAG(seg_type) OVER (ORDER BY start_index) IS NULL THEN 1
        WHEN LAG(seg_type) OVER (ORDER BY start_index) IS DISTINCT FROM seg_type THEN 1
        WHEN LAG(start_loc_id) OVER (ORDER BY start_index) IS DISTINCT FROM start_loc_id
          AND seg_type NOT IN ('travel', 'unmatched', 'mixed') THEN 1
        ELSE 0
      END AS is_new_segment
    FROM point_pairs
  ),
  merged_segments AS (
    -- Group consecutive segments of same type
    SELECT
      *,
      SUM(is_new_segment) OVER (ORDER BY start_index) AS segment_group
    FROM segments_with_boundaries
  )
  SELECT
    ROW_NUMBER() OVER (ORDER BY MIN(ms.start_index))::INTEGER AS segment_index,
    ms.seg_type AS segment_type,
    MIN(ms.start_time) AS start_time,
    MAX(ms.end_time) AS end_time,
    SUM(ms.duration_sec)::INTEGER AS duration_seconds,
    (ARRAY_AGG(ms.start_loc_id) FILTER (WHERE ms.start_loc_id IS NOT NULL))[1] AS location_id,
    (ARRAY_AGG(ms.start_loc_name) FILTER (WHERE ms.start_loc_name IS NOT NULL))[1] AS location_name,
    COUNT(*)::INTEGER + 1 AS point_count
  FROM merged_segments ms
  GROUP BY ms.segment_group, ms.seg_type
  ORDER BY MIN(ms.start_index);
END;
$$;

-- ============================================
-- Function: get_shift_timeline_summary
-- Returns summary statistics for shift timeline
-- ============================================
CREATE OR REPLACE FUNCTION get_shift_timeline_summary(p_shift_id UUID)
RETURNS TABLE (
  total_duration_seconds INTEGER,
  office_seconds INTEGER,
  building_seconds INTEGER,
  vendor_seconds INTEGER,
  home_seconds INTEGER,
  travel_seconds INTEGER,
  unmatched_seconds INTEGER,
  mixed_seconds INTEGER,
  segment_count INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT
    COALESCE(SUM(t.duration_seconds), 0)::INTEGER AS total_duration_seconds,
    COALESCE(SUM(t.duration_seconds) FILTER (WHERE t.segment_type = 'office'), 0)::INTEGER AS office_seconds,
    COALESCE(SUM(t.duration_seconds) FILTER (WHERE t.segment_type = 'building'), 0)::INTEGER AS building_seconds,
    COALESCE(SUM(t.duration_seconds) FILTER (WHERE t.segment_type = 'vendor'), 0)::INTEGER AS vendor_seconds,
    COALESCE(SUM(t.duration_seconds) FILTER (WHERE t.segment_type = 'home'), 0)::INTEGER AS home_seconds,
    COALESCE(SUM(t.duration_seconds) FILTER (WHERE t.segment_type = 'travel'), 0)::INTEGER AS travel_seconds,
    COALESCE(SUM(t.duration_seconds) FILTER (WHERE t.segment_type = 'unmatched'), 0)::INTEGER AS unmatched_seconds,
    COALESCE(SUM(t.duration_seconds) FILTER (WHERE t.segment_type = 'mixed'), 0)::INTEGER AS mixed_seconds,
    COUNT(*)::INTEGER AS segment_count
  FROM get_shift_timeline(p_shift_id) t;
END;
$$;
```

---

## Phase 2: Types TypeScript

### Fichier: `dashboard/src/types/locations.ts`

```typescript
// ============================================
// Location Types
// ============================================

export type LocationType = 'office' | 'building' | 'vendor' | 'home' | 'other';

export type SegmentType = 'office' | 'building' | 'vendor' | 'home' | 'mixed' | 'travel' | 'unmatched';

export interface Location {
  id: string;
  userId: string;
  name: string;
  locationType: LocationType;
  latitude: number;
  longitude: number;
  radiusMeters: number;
  address: string | null;
  notes: string | null;
  isActive: boolean;
  createdAt: Date;
  updatedAt: Date;
}

export interface LocationMatch {
  id: string;
  gpsPointId: string;
  locationId: string;
  distanceMeters: number;
  confidenceScore: number;
  matchedAt: Date;
}

// ============================================
// Timeline Types
// ============================================

export interface TimelineSegment {
  segmentIndex: number;
  segmentType: SegmentType;
  startTime: Date;
  endTime: Date;
  durationSeconds: number;
  locationId: string | null;
  locationName: string | null;
  pointCount: number;
}

export interface TimelineSummary {
  totalDurationSeconds: number;
  officeSeconds: number;
  buildingSeconds: number;
  vendorSeconds: number;
  homeSeconds: number;
  travelSeconds: number;
  unmatchedSeconds: number;
  mixedSeconds: number;
  segmentCount: number;
}

export interface ShiftTimeline {
  shiftId: string;
  segments: TimelineSegment[];
  summary: TimelineSummary;
}

// ============================================
// UI Constants
// ============================================

export const SEGMENT_COLORS: Record<SegmentType, {
  bg: string;
  text: string;
  label: string;
  hex: string;
}> = {
  office: { bg: 'bg-blue-500', text: 'text-blue-700', label: 'Bureau', hex: '#3b82f6' },
  building: { bg: 'bg-green-500', text: 'text-green-700', label: 'Chantier', hex: '#22c55e' },
  vendor: { bg: 'bg-orange-500', text: 'text-orange-700', label: 'Fournisseur', hex: '#f97316' },
  home: { bg: 'bg-purple-500', text: 'text-purple-700', label: 'Domicile', hex: '#a855f7' },
  mixed: { bg: 'bg-violet-500', text: 'text-violet-700', label: 'Mixte', hex: '#8b5cf6' },
  travel: { bg: 'bg-yellow-500', text: 'text-yellow-700', label: 'Deplacement', hex: '#eab308' },
  unmatched: { bg: 'bg-red-500', text: 'text-red-700', label: 'Non-matche', hex: '#ef4444' },
};

export const LOCATION_TYPE_INFO: Record<LocationType, {
  label: string;
  icon: string;
  defaultRadius: number;
}> = {
  office: { label: 'Bureau', icon: 'Building2', defaultRadius: 100 },
  building: { label: 'Chantier', icon: 'HardHat', defaultRadius: 100 },
  vendor: { label: 'Fournisseur', icon: 'Truck', defaultRadius: 200 },
  home: { label: 'Domicile', icon: 'Home', defaultRadius: 50 },
  other: { label: 'Autre', icon: 'MapPin', defaultRadius: 100 },
};

// ============================================
// Form/Filter Types
// ============================================

export interface LocationFilters {
  type?: LocationType;
  search?: string;
  isActive?: boolean;
}

export interface LocationFormData {
  name: string;
  locationType: LocationType;
  latitude: number;
  longitude: number;
  radiusMeters: number;
  address?: string;
  notes?: string;
}
```

### Fichier: `dashboard/src/lib/validations/locations.ts`

```typescript
import { z } from 'zod';

export const LocationTypeEnum = z.enum(['office', 'building', 'vendor', 'home', 'other']);

export const locationCreateSchema = z.object({
  name: z.string().min(1, 'Le nom est requis').max(100, 'Nom trop long'),
  location_type: LocationTypeEnum,
  latitude: z.number().min(-90, 'Latitude invalide').max(90, 'Latitude invalide'),
  longitude: z.number().min(-180, 'Longitude invalide').max(180, 'Longitude invalide'),
  radius_meters: z.number().min(10, 'Minimum 10m').max(1000, 'Maximum 1000m').default(100),
  address: z.string().max(500).optional().nullable(),
  notes: z.string().max(500).optional().nullable(),
});

export const locationUpdateSchema = locationCreateSchema.partial().extend({
  is_active: z.boolean().optional(),
});

export const locationFilterSchema = z.object({
  type: LocationTypeEnum.optional(),
  search: z.string().optional(),
  is_active: z.boolean().optional(),
});

export const locationBulkImportSchema = z.array(
  z.object({
    name: z.string().min(1),
    location_type: LocationTypeEnum,
    latitude: z.number().min(-90).max(90),
    longitude: z.number().min(-180).max(180),
    radius_meters: z.number().min(10).max(1000).optional(),
    address: z.string().optional(),
  })
);

export type LocationCreate = z.infer<typeof locationCreateSchema>;
export type LocationUpdate = z.infer<typeof locationUpdateSchema>;
```

---

## Phase 3: React Hooks

### Fichier: `dashboard/src/lib/hooks/use-locations.ts`

```typescript
'use client';

import { useList, useOne, useCreate, useUpdate, useDelete } from '@refinedev/core';
import { Location, LocationFilters, LocationFormData } from '@/types/locations';

export function useLocations(filters?: LocationFilters) {
  return useList<Location>({
    resource: 'locations',
    filters: [
      ...(filters?.type ? [{ field: 'location_type', operator: 'eq', value: filters.type }] : []),
      ...(filters?.search ? [{ field: 'name', operator: 'contains', value: filters.search }] : []),
      ...(filters?.isActive !== undefined ? [{ field: 'is_active', operator: 'eq', value: filters.isActive }] : []),
    ],
    sorters: [{ field: 'name', order: 'asc' }],
  });
}

export function useLocation(id: string) {
  return useOne<Location>({
    resource: 'locations',
    id,
  });
}

export function useCreateLocation() {
  return useCreate<Location, LocationFormData>();
}

export function useUpdateLocation() {
  return useUpdate<Location, Partial<LocationFormData>>();
}

export function useDeleteLocation() {
  return useDelete<Location>();
}
```

### Fichier: `dashboard/src/lib/hooks/use-shift-timeline.ts`

```typescript
'use client';

import { useState, useEffect } from 'react';
import { createClient } from '@/lib/supabase/client';
import { ShiftTimeline, TimelineSegment, TimelineSummary } from '@/types/locations';

export function useShiftTimeline(shiftId: string | null) {
  const [timeline, setTimeline] = useState<ShiftTimeline | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    if (!shiftId) {
      setTimeline(null);
      return;
    }

    const fetchTimeline = async () => {
      setIsLoading(true);
      setError(null);

      try {
        const supabase = createClient();

        // Fetch segments
        const { data: segments, error: segError } = await supabase
          .rpc('get_shift_timeline', { p_shift_id: shiftId });

        if (segError) throw segError;

        // Fetch summary
        const { data: summary, error: sumError } = await supabase
          .rpc('get_shift_timeline_summary', { p_shift_id: shiftId });

        if (sumError) throw sumError;

        setTimeline({
          shiftId,
          segments: (segments || []).map((s: any) => ({
            segmentIndex: s.segment_index,
            segmentType: s.segment_type,
            startTime: new Date(s.start_time),
            endTime: new Date(s.end_time),
            durationSeconds: s.duration_seconds,
            locationId: s.location_id,
            locationName: s.location_name,
            pointCount: s.point_count,
          })),
          summary: summary?.[0] ? {
            totalDurationSeconds: summary[0].total_duration_seconds,
            officeSeconds: summary[0].office_seconds,
            buildingSeconds: summary[0].building_seconds,
            vendorSeconds: summary[0].vendor_seconds,
            homeSeconds: summary[0].home_seconds,
            travelSeconds: summary[0].travel_seconds,
            unmatchedSeconds: summary[0].unmatched_seconds,
            mixedSeconds: summary[0].mixed_seconds,
            segmentCount: summary[0].segment_count,
          } : {
            totalDurationSeconds: 0,
            officeSeconds: 0,
            buildingSeconds: 0,
            vendorSeconds: 0,
            homeSeconds: 0,
            travelSeconds: 0,
            unmatchedSeconds: 0,
            mixedSeconds: 0,
            segmentCount: 0,
          },
        });
      } catch (err) {
        setError(err instanceof Error ? err : new Error('Failed to fetch timeline'));
      } finally {
        setIsLoading(false);
      }
    };

    fetchTimeline();
  }, [shiftId]);

  return { timeline, isLoading, error };
}
```

### Fichier: `dashboard/src/lib/hooks/use-geocoding.ts`

```typescript
'use client';

import { useState, useCallback } from 'react';

interface GeocodingResult {
  latitude: number;
  longitude: number;
  formattedAddress: string;
}

export function useGeocoding() {
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const geocodeAddress = useCallback(async (address: string): Promise<GeocodingResult> => {
    setIsLoading(true);
    setError(null);

    try {
      const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;
      if (!apiKey) {
        throw new Error('Google Maps API key not configured');
      }

      const response = await fetch(
        `https://maps.googleapis.com/maps/api/geocode/json?address=${encodeURIComponent(address)}&key=${apiKey}`
      );

      const data = await response.json();

      if (data.status !== 'OK' || !data.results?.[0]) {
        throw new Error('Adresse non trouvee');
      }

      const { lat, lng } = data.results[0].geometry.location;

      return {
        latitude: lat,
        longitude: lng,
        formattedAddress: data.results[0].formatted_address,
      };
    } catch (err) {
      const error = err instanceof Error ? err : new Error('Geocoding failed');
      setError(error);
      throw error;
    } finally {
      setIsLoading(false);
    }
  }, []);

  return { geocodeAddress, isLoading, error };
}
```

---

## Phase 4: Composants UI

### Structure des composants à créer

```
dashboard/src/components/
├── locations/
│   ├── location-table.tsx        # Table paginée des locations
│   ├── location-filters.tsx      # Filtres (type, recherche, actif)
│   ├── location-form.tsx         # Formulaire création/édition
│   ├── location-map-picker.tsx   # Carte interactive pour placement
│   ├── radius-slider.tsx         # Slider rayon 10-1000m
│   ├── geofence-circle.tsx       # Cercle Leaflet pour visualisation
│   └── bulk-import-dialog.tsx    # Import CSV en masse
└── timeline/
    ├── shift-timeline.tsx        # Barre horizontale colorée
    ├── timeline-segment.tsx      # Segment individuel avec tooltip
    ├── timeline-summary.tsx      # Stats par type (camembert)
    ├── timeline-legend.tsx       # Légende des couleurs
    └── segmented-trail-map.tsx   # Carte avec tracé coloré
```

### Composant clé: `location-form.tsx`

```typescript
'use client';

import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { locationCreateSchema, LocationCreate } from '@/lib/validations/locations';
import { LocationType, LOCATION_TYPE_INFO } from '@/types/locations';
import { useGeocoding } from '@/lib/hooks/use-geocoding';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Slider } from '@/components/ui/slider';
import LocationMapPicker from './location-map-picker';

interface LocationFormProps {
  defaultValues?: Partial<LocationCreate>;
  onSubmit: (data: LocationCreate) => void;
  isLoading?: boolean;
}

export default function LocationForm({ defaultValues, onSubmit, isLoading }: LocationFormProps) {
  const { geocodeAddress, isLoading: isGeocoding } = useGeocoding();

  const form = useForm<LocationCreate>({
    resolver: zodResolver(locationCreateSchema),
    defaultValues: {
      name: '',
      location_type: 'building',
      latitude: 48.24, // Default: Rouyn-Noranda
      longitude: -79.02,
      radius_meters: 100,
      ...defaultValues,
    },
  });

  const handleGeocode = async () => {
    const address = form.getValues('address');
    if (!address) return;

    try {
      const result = await geocodeAddress(address);
      form.setValue('latitude', result.latitude);
      form.setValue('longitude', result.longitude);
      form.setValue('address', result.formattedAddress);
    } catch (err) {
      // Error handled by hook
    }
  };

  const handleMapClick = (lat: number, lng: number) => {
    form.setValue('latitude', lat);
    form.setValue('longitude', lng);
  };

  return (
    <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-6">
      {/* Name */}
      <div>
        <label className="text-sm font-medium">Nom</label>
        <Input {...form.register('name')} placeholder="Ex: 22-28_Gamble-O" />
        {form.formState.errors.name && (
          <p className="text-sm text-red-500">{form.formState.errors.name.message}</p>
        )}
      </div>

      {/* Type */}
      <div>
        <label className="text-sm font-medium">Type</label>
        <Select
          value={form.watch('location_type')}
          onValueChange={(value) => form.setValue('location_type', value as LocationType)}
        >
          <SelectTrigger>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {Object.entries(LOCATION_TYPE_INFO).map(([key, info]) => (
              <SelectItem key={key} value={key}>
                {info.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      {/* Address with Geocode */}
      <div>
        <label className="text-sm font-medium">Adresse</label>
        <div className="flex gap-2">
          <Input {...form.register('address')} placeholder="Entrez une adresse..." className="flex-1" />
          <Button type="button" onClick={handleGeocode} disabled={isGeocoding}>
            {isGeocoding ? 'Recherche...' : 'Geocoder'}
          </Button>
        </div>
      </div>

      {/* Map Picker */}
      <div>
        <label className="text-sm font-medium">Position sur la carte</label>
        <LocationMapPicker
          latitude={form.watch('latitude')}
          longitude={form.watch('longitude')}
          radius={form.watch('radius_meters')}
          onPositionChange={handleMapClick}
        />
      </div>

      {/* Radius Slider */}
      <div>
        <label className="text-sm font-medium">
          Rayon: {form.watch('radius_meters')}m
        </label>
        <Slider
          value={[form.watch('radius_meters')]}
          onValueChange={([value]) => form.setValue('radius_meters', value)}
          min={10}
          max={1000}
          step={5}
        />
      </div>

      {/* Notes */}
      <div>
        <label className="text-sm font-medium">Notes</label>
        <Input {...form.register('notes')} placeholder="Notes optionnelles..." />
      </div>

      <Button type="submit" disabled={isLoading}>
        {isLoading ? 'Enregistrement...' : 'Enregistrer'}
      </Button>
    </form>
  );
}
```

### Composant clé: `shift-timeline.tsx`

```typescript
'use client';

import { TimelineSegment, SEGMENT_COLORS } from '@/types/locations';
import { formatDuration } from '@/lib/utils/format';
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip';

interface ShiftTimelineProps {
  segments: TimelineSegment[];
  totalDuration: number;
  onSegmentClick?: (segment: TimelineSegment) => void;
}

export default function ShiftTimeline({ segments, totalDuration, onSegmentClick }: ShiftTimelineProps) {
  if (segments.length === 0) {
    return <div className="h-8 bg-gray-200 rounded">Aucune donnee</div>;
  }

  return (
    <div className="flex h-10 rounded overflow-hidden">
      {segments.map((segment) => {
        const widthPercent = (segment.durationSeconds / totalDuration) * 100;
        const colors = SEGMENT_COLORS[segment.segmentType];

        return (
          <Tooltip key={segment.segmentIndex}>
            <TooltipTrigger asChild>
              <div
                className={`${colors.bg} cursor-pointer hover:opacity-80 transition-opacity flex items-center justify-center`}
                style={{ width: `${widthPercent}%`, minWidth: widthPercent > 5 ? '20px' : '4px' }}
                onClick={() => onSegmentClick?.(segment)}
              >
                {widthPercent > 10 && (
                  <span className="text-white text-xs font-medium truncate px-1">
                    {formatDuration(segment.durationSeconds)}
                  </span>
                )}
              </div>
            </TooltipTrigger>
            <TooltipContent>
              <div className="text-sm">
                <p className="font-medium">{colors.label}</p>
                {segment.locationName && <p>{segment.locationName}</p>}
                <p>{formatDuration(segment.durationSeconds)}</p>
                <p>{segment.pointCount} points GPS</p>
              </div>
            </TooltipContent>
          </Tooltip>
        );
      })}
    </div>
  );
}
```

---

## Phase 5: Pages

### Structure des pages à créer

```
dashboard/src/app/dashboard/locations/
├── page.tsx                      # Liste des locations
├── new/page.tsx                  # Création
└── [id]/page.tsx                 # Détail/Édition
```

### Sidebar Navigation

Ajouter dans `dashboard/src/components/layout/sidebar.tsx`:

```typescript
import { MapPinned } from 'lucide-react';

// Dans le tableau des liens
{
  name: 'Lieux',
  href: '/dashboard/locations',
  icon: MapPinned,
}
```

---

## Phase 6: Import des Données Existantes

### 77 Locations à Importer

Les locations seront importées avec l'utilisateur **cedric@tri-logis.ca** comme propriétaire.

```sql
-- Dans la migration, après création des tables:

-- Récupérer l'ID de l'admin
DO $$
DECLARE
  v_admin_id UUID;
BEGIN
  SELECT id INTO v_admin_id FROM auth.users WHERE email = 'cedric@tri-logis.ca' LIMIT 1;

  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'Admin user cedric@tri-logis.ca not found';
  END IF;

  INSERT INTO locations (id, user_id, name, location_type, latitude, longitude, radius_meters, address, notes, is_active, created_at, updated_at)
  VALUES
    ('042763fe-a040-41fa-9b3c-88665033142e', v_admin_id, '22-28_Gamble-O', 'building', 48.2400725, -79.0207985, 10.00, '28 Rue Gamble O #22, Rouyn-Noranda, QC J9X 2R2, Canada', NULL, true, '2026-01-08 15:28:37.081622+00', '2026-01-08 15:30:36.008777+00'),
    ('061dddaf-e626-4310-8173-555c95d1589d', v_admin_id, '43-45_Perreault-O', 'building', 48.2379995, -79.0214298, 10.00, '45 Rue Perreault O #43, Rouyn-Noranda, QC J9X 2T3, Canada', NULL, true, '2026-01-08 15:28:43.468086+00', '2026-01-08 15:30:36.008777+00'),
    ('07f8860c-c130-4ea6-99ed-d1f451a4a5f2', v_admin_id, '7-15_15eRue', 'building', 48.2419544, -79.0326962, 34.00, '15 15e Rue #7, Rouyn-Noranda, QC J9X 2J9, Canada', NULL, true, '2026-01-08 15:28:46.360646+00', '2026-01-08 16:24:38.252583+00'),
    ('0e1ffa73-5d25-4ffe-9c11-a78d343782a9', v_admin_id, '117-119_Mgr-Tessier-O', 'building', 48.2388216, -79.0236844, 10.00, '119 Rue Mgr Tessier O #117, Rouyn-Noranda, QC J9X 2S7, Canada', NULL, true, '2026-01-08 15:28:42.826883+00', '2026-01-08 15:30:36.008777+00'),
    ('104ae513-5c5b-434a-9610-7e019537b09f', v_admin_id, 'Home Jessy', 'home', 48.2327048, -79.0135665, 20.00, 'Rouyn-Noranda, QC, Canada', '', true, '2026-01-09 18:46:24.527902+00', '2026-01-09 18:46:24.527902+00'),
    ('11b83fa9-d791-4596-8020-d6e5c4d1fbd3', v_admin_id, '260-264_Cardinal-Begin-E', 'building', 48.2365672, -79.0119461, 10.00, '264 Rue Cardinal Bégin E #260, Rouyn-Noranda, QC J9X 3H5, Canada', NULL, true, '2026-01-08 15:28:44.093476+00', '2026-01-08 15:30:36.008777+00'),
    ('11d32135-44c1-4210-93a7-4d12b5a1febd', v_admin_id, '31-37_Principale', 'building', 48.2420301, -79.0199861, 10.00, '37 Av. Principale #31, Rouyn-Noranda, QC J9X 3B5, Canada', NULL, true, '2026-01-08 15:28:43.191665+00', '2026-01-08 15:32:33.708151+00'),
    ('12506c36-2130-43e2-9139-bfb76dec63f8', v_admin_id, '103-105_Dallaire', 'building', 48.2404719, -79.0223550, 10.00, '105 Av. Dallaire #103, Rouyn-Noranda, QC J9X 4S8, Canada', NULL, false, '2026-01-08 15:28:40.078338+00', '2026-01-08 15:32:43.200393+00'),
    ('12a129da-759b-4766-9f98-b0c65c48c6fa', v_admin_id, '284-288_Dallaire', 'building', 48.2350980, -79.0228122, 10.00, '288 Av. Dallaire #284, Rouyn-Noranda, QC J9X 4T9, Canada', NULL, true, '2026-01-08 15:28:47.122679+00', '2026-01-08 15:36:01.868056+00'),
    ('13b985ab-69a8-4b00-a528-b8d07bd351b8', v_admin_id, '151-159_Principale', 'building', 48.2388758, -79.0197265, 25.00, '159 Av. Principale #151, Rouyn-Noranda, QC J9X 4P6, Canada', NULL, true, '2026-01-08 15:28:44.231997+00', '2026-01-08 15:33:26.767994+00'),
    -- ... continuer avec les 67 autres locations
    ('8d3a1b11-89fb-43a5-9adf-effe35ceea39', v_admin_id, 'Home Ozaka', 'home', 48.2276302, -79.0086250, 20.00, 'Rouyn-Noranda, QC, Canada', '', true, '2026-01-09 18:47:41.235543+00', '2026-01-09 18:47:41.235543+00')
  ON CONFLICT (id) DO NOTHING;
END $$;
```

**Note**: Le script complet d'import avec les 77 locations sera généré à partir du JSON fourni lors de l'implémentation.

---

## Configuration Requise

### Variables d'Environnement

Ajouter dans `.env.local`:

```env
NEXT_PUBLIC_GOOGLE_MAPS_API_KEY=your_google_maps_api_key_here
```

### Dépendances (déjà installées)

- `react-leaflet` - Cartes interactives
- `leaflet` - Librairie de cartes
- `@tanstack/react-table` - Tables paginées
- `date-fns` - Formatage dates/durées

---

## Vérification

### Tests Manuels

1. **CRUD Locations**:
   - Créer une location via le formulaire avec carte interactive
   - Vérifier que le cercle s'affiche correctement sur la carte
   - Modifier le rayon et voir la mise à jour en temps réel
   - Désactiver une location et vérifier qu'elle n'apparaît plus dans les filtres

2. **Geocodage**:
   - Entrer une adresse et cliquer "Geocoder"
   - Vérifier que les coordonnées sont mises à jour
   - Vérifier que le marqueur se déplace sur la carte

3. **Timeline Shift**:
   - Consulter un shift historique avec des points GPS
   - Vérifier que la timeline segmentée s'affiche
   - Vérifier les couleurs correspondent aux types de segments
   - Cliquer sur un segment pour voir les détails

4. **Import CSV**:
   - Tester l'import avec un fichier CSV de 5-10 locations
   - Vérifier la preview avant import
   - Vérifier les erreurs de validation

### Requêtes SQL de Test

```sql
-- Vérifier les locations créées
SELECT id, name, location_type, radius_meters, is_active
FROM locations
ORDER BY name;

-- Vérifier le matching d'un shift
SELECT * FROM match_shift_gps_to_locations('shift-uuid-here');

-- Tester la timeline
SELECT * FROM get_shift_timeline('shift-uuid-here');

-- Vérifier les statistiques
SELECT * FROM get_shift_timeline_summary('shift-uuid-here');
```

---

## Ordre d'Implémentation

1. **Migration DB** - Tables `locations` et `location_matches` avec PostGIS
2. **Import données** - Seed des 77 locations depuis QB Time
3. **Types + Validations** - TypeScript et Zod
4. **Hooks** - use-locations, use-shift-timeline, use-geocoding
5. **Composants Location** - Table, Form, Map Picker, Radius Slider
6. **Pages Location** - CRUD complet (/dashboard/locations/*)
7. **Composants Timeline** - Visualisation segments
8. **Intégration** - Ajouter timeline dans History page
9. **Import CSV** - Bulk import dialog
10. **Geocoding** - Intégration Google Maps API
