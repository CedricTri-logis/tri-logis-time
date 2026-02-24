'use client';

import { useCustom } from '@refinedev/core';
import { useMemo, useCallback, useState } from 'react';
import { supabaseClient } from '@/lib/supabase/client';
import type {
  LocationMatch,
  LocationMatchRow,
  ShiftMatchesCheck,
  ShiftMatchesCheckRow,
} from '@/types/location';

/**
 * Hook to check if a shift has cached location matches
 */
export function useShiftMatchesCheck(shiftId: string | null) {
  const { query, result } = useCustom<ShiftMatchesCheckRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'check_shift_matches_exist',
    },
    config: {
      payload: {
        p_shift_id: shiftId,
      } as Record<string, unknown>,
    },
    queryOptions: {
      enabled: !!shiftId,
      staleTime: 30 * 1000, // Cache for 30 seconds
    },
  });

  const rawData = result?.data as ShiftMatchesCheckRow[] | undefined;

  const matchStatus: ShiftMatchesCheck | null = useMemo(() => {
    if (!rawData || !Array.isArray(rawData) || rawData.length === 0) return null;
    const row = rawData[0];
    return {
      hasMatches: row.has_matches,
      matchCount: row.match_count,
      matchedAt: row.matched_at ? new Date(row.matched_at) : null,
    };
  }, [rawData]);

  return {
    matchStatus,
    isLoading: query.isLoading,
    error: query.isError
      ? ((query.error as unknown as Error)?.message ?? 'Unknown error')
      : null,
    refetch: query.refetch,
  };
}

/**
 * Hook to fetch/compute GPS-to-location matches for a shift
 */
export function useLocationMatches(shiftId: string | null) {
  const { query, result } = useCustom<LocationMatchRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'match_shift_gps_to_locations',
    },
    config: {
      payload: {
        p_shift_id: shiftId,
      } as Record<string, unknown>,
    },
    queryOptions: {
      enabled: !!shiftId,
      staleTime: 5 * 60 * 1000, // Cache for 5 minutes
    },
  });

  const rawData = result?.data as LocationMatchRow[] | undefined;

  const matches: LocationMatch[] = useMemo(() => {
    if (!rawData || !Array.isArray(rawData)) return [];
    return rawData.map((row) => ({
      gpsPointId: row.gps_point_id,
      gpsLatitude: row.gps_latitude,
      gpsLongitude: row.gps_longitude,
      capturedAt: new Date(row.captured_at),
      locationId: row.location_id,
      locationName: row.location_name,
      locationType: row.location_type,
      distanceMeters: row.distance_meters,
      confidenceScore: row.confidence_score,
    }));
  }, [rawData]);

  // Statistics
  const stats = useMemo(() => {
    if (matches.length === 0) {
      return {
        totalPoints: 0,
        matchedPoints: 0,
        unmatchedPoints: 0,
        matchPercentage: 0,
      };
    }

    const matched = matches.filter((m) => m.locationId !== null);
    const unmatched = matches.filter((m) => m.locationId === null);

    return {
      totalPoints: matches.length,
      matchedPoints: matched.length,
      unmatchedPoints: unmatched.length,
      matchPercentage: (matched.length / matches.length) * 100,
    };
  }, [matches]);

  return {
    matches,
    stats,
    isLoading: query.isLoading,
    isFetching: query.isFetching,
    error: query.isError
      ? ((query.error as unknown as Error)?.message ?? 'Unknown error')
      : null,
    refetch: query.refetch,
  };
}

/**
 * Hook for lazy loading location matches (trigger computation manually)
 */
export function useLazyLocationMatches() {
  const [isComputing, setIsComputing] = useState(false);

  const computeMatches = useCallback(
    async (shiftId: string): Promise<LocationMatch[]> => {
      setIsComputing(true);
      try {
        const { data, error } = await supabaseClient.rpc('match_shift_gps_to_locations', {
          p_shift_id: shiftId,
        });

        if (error) throw error;

        const rawData = data as LocationMatchRow[];
        if (!rawData || !Array.isArray(rawData)) return [];

        return rawData.map((row) => ({
          gpsPointId: row.gps_point_id,
          gpsLatitude: row.gps_latitude,
          gpsLongitude: row.gps_longitude,
          capturedAt: new Date(row.captured_at),
          locationId: row.location_id,
          locationName: row.location_name,
          locationType: row.location_type,
          distanceMeters: row.distance_meters,
          confidenceScore: row.confidence_score,
        }));
      } finally {
        setIsComputing(false);
      }
    },
    []
  );

  return {
    computeMatches,
    isComputing,
  };
}
