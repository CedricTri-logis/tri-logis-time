'use client';

import { useCustom } from '@refinedev/core';
import { useMemo, useCallback, useState, useEffect } from 'react';
import { supabaseClient } from '@/lib/supabase/client';
import type {
  Location,
  LocationRow,
  LocationFormData,
  BulkInsertResult,
  BulkInsertResultRow,
} from '@/types/location';
import type { LocationType } from '@/types/location';

/**
 * Filter parameters for locations list
 */
export interface LocationFilters {
  search?: string;
  locationType?: LocationType;
  isActive?: boolean;
  sortBy?: 'name' | 'created_at' | 'updated_at' | 'location_type';
  sortOrder?: 'asc' | 'desc';
  limit?: number;
  offset?: number;
}

/**
 * Hook to fetch paginated locations with filtering
 */
export function useLocations(filters: LocationFilters = {}) {
  const {
    search,
    locationType,
    isActive,
    sortBy = 'name',
    sortOrder = 'asc',
    limit = 20,
    offset = 0,
  } = filters;

  const { query, result } = useCustom<LocationRow[]>({
    url: '',
    method: 'get',
    meta: {
      rpc: 'get_locations_paginated',
    },
    config: {
      payload: {
        p_limit: limit,
        p_offset: offset,
        p_search: search || null,
        p_location_type: locationType || null,
        p_is_active: isActive ?? null,
        p_sort_by: sortBy,
        p_sort_order: sortOrder,
      } as Record<string, unknown>,
    },
    queryOptions: {
      staleTime: 30 * 1000, // Cache for 30 seconds
    },
  });

  const rawData = result?.data as LocationRow[] | undefined;

  const locations: Location[] = useMemo(() => {
    if (!rawData || !Array.isArray(rawData)) return [];
    return rawData.map((row) => ({
      id: row.id,
      name: row.name,
      locationType: row.location_type,
      latitude: row.latitude,
      longitude: row.longitude,
      radiusMeters: row.radius_meters,
      address: row.address,
      notes: row.notes,
      isActive: row.is_active,
      createdAt: new Date(row.created_at),
      updatedAt: new Date(row.updated_at),
    }));
  }, [rawData]);

  const totalCount = useMemo(() => {
    if (!rawData || !Array.isArray(rawData) || rawData.length === 0) return 0;
    return rawData[0].total_count ?? rawData.length;
  }, [rawData]);

  return {
    locations,
    totalCount,
    isLoading: query.isLoading,
    isFetching: query.isFetching,
    error: query.isError ? (query.error as unknown as Error)?.message ?? 'Unknown error' : null,
    refetch: query.refetch,
  };
}

/**
 * Hook to fetch a single location by ID
 */
export function useLocation(locationId: string | null) {
  const [location, setLocation] = useState<Location | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchLocation = useCallback(async () => {
    if (!locationId) {
      setLocation(null);
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      const { data, error: fetchError } = await supabaseClient
        .from('locations')
        .select('*')
        .eq('id', locationId)
        .single();

      if (fetchError) throw fetchError;

      if (data) {
        setLocation({
          id: data.id,
          name: data.name,
          locationType: data.location_type,
          latitude: data.latitude,
          longitude: data.longitude,
          radiusMeters: data.radius_meters,
          address: data.address,
          notes: data.notes,
          isActive: data.is_active,
          createdAt: new Date(data.created_at),
          updatedAt: new Date(data.updated_at),
        });
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to fetch location');
      setLocation(null);
    } finally {
      setIsLoading(false);
    }
  }, [locationId]);

  // Fetch on mount and when locationId changes
  useEffect(() => {
    fetchLocation();
  }, [fetchLocation]);

  return {
    location,
    isLoading,
    error,
    refetch: fetchLocation,
  };
}

/**
 * Hook for location CRUD mutations
 */
export function useLocationMutations() {
  const [isCreating, setIsCreating] = useState(false);
  const [isUpdating, setIsUpdating] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);

  const createLocation = useCallback(
    async (data: LocationFormData): Promise<Location> => {
      setIsCreating(true);
      try {
        const { data: result, error } = await supabaseClient
          .from('locations')
          .insert({
            name: data.name,
            location_type: data.locationType,
            location: `SRID=4326;POINT(${data.longitude} ${data.latitude})`,
            radius_meters: data.radiusMeters,
            address: data.address,
            notes: data.notes,
            is_active: data.isActive,
          })
          .select()
          .single();

        if (error) throw error;
        if (!result) throw new Error('Failed to create location');

        return {
          id: result.id,
          name: result.name,
          locationType: result.location_type,
          latitude: data.latitude, // Use input since PostGIS functions not available in direct query
          longitude: data.longitude,
          radiusMeters: result.radius_meters,
          address: result.address,
          notes: result.notes,
          isActive: result.is_active,
          createdAt: new Date(result.created_at),
          updatedAt: new Date(result.updated_at),
        };
      } finally {
        setIsCreating(false);
      }
    },
    []
  );

  const updateLocation = useCallback(
    async (id: string, data: Partial<LocationFormData>): Promise<Location> => {
      setIsUpdating(true);
      try {
        const updatePayload: Record<string, unknown> = {};

        if (data.name !== undefined) updatePayload.name = data.name;
        if (data.locationType !== undefined) updatePayload.location_type = data.locationType;
        if (data.latitude !== undefined && data.longitude !== undefined) {
          updatePayload.location = `SRID=4326;POINT(${data.longitude} ${data.latitude})`;
        }
        if (data.radiusMeters !== undefined) updatePayload.radius_meters = data.radiusMeters;
        if (data.address !== undefined) updatePayload.address = data.address;
        if (data.notes !== undefined) updatePayload.notes = data.notes;
        if (data.isActive !== undefined) updatePayload.is_active = data.isActive;

        const { data: result, error } = await supabaseClient
          .from('locations')
          .update(updatePayload)
          .eq('id', id)
          .select()
          .single();

        if (error) throw error;
        if (!result) throw new Error('Failed to update location');

        // For coordinates, we need to re-fetch via RPC to get the extracted lat/lng
        // For now, return what we have and caller can refetch if needed
        return {
          id: result.id,
          name: result.name,
          locationType: result.location_type,
          latitude: data.latitude ?? 0, // Will be 0 if not updated - caller should refetch
          longitude: data.longitude ?? 0,
          radiusMeters: result.radius_meters,
          address: result.address,
          notes: result.notes,
          isActive: result.is_active,
          createdAt: new Date(result.created_at),
          updatedAt: new Date(result.updated_at),
        };
      } finally {
        setIsUpdating(false);
      }
    },
    []
  );

  const deleteLocation = useCallback(
    async (id: string): Promise<void> => {
      setIsDeleting(true);
      try {
        const { error } = await supabaseClient
          .from('locations')
          .delete()
          .eq('id', id);

        if (error) throw error;
      } finally {
        setIsDeleting(false);
      }
    },
    []
  );

  const toggleActive = useCallback(
    async (id: string, isActive: boolean): Promise<Location> => {
      return updateLocation(id, { isActive });
    },
    [updateLocation]
  );

  return {
    createLocation,
    updateLocation,
    deleteLocation,
    toggleActive,
    isCreating,
    isUpdating,
    isDeleting,
    isMutating: isCreating || isUpdating || isDeleting,
  };
}

/**
 * Hook for bulk location import via RPC
 */
export function useBulkInsertLocations() {
  const [isInserting, setIsInserting] = useState(false);
  const [progress, setProgress] = useState<{
    current: number;
    total: number;
  } | null>(null);

  const bulkInsert = useCallback(
    async (
      locations: Array<{
        name: string;
        location_type: string;
        latitude: number;
        longitude: number;
        radius_meters?: number;
        address?: string | null;
        notes?: string | null;
        is_active?: boolean;
      }>
    ): Promise<BulkInsertResult[]> => {
      setIsInserting(true);
      setProgress({ current: 0, total: locations.length });

      try {
        const { data, error } = await supabaseClient.rpc('bulk_insert_locations', {
          p_locations: JSON.stringify(locations),
        });

        if (error) throw error;

        const rawData = data as BulkInsertResultRow[];
        if (!rawData || !Array.isArray(rawData)) {
          throw new Error('Invalid response from bulk insert');
        }

        setProgress({ current: locations.length, total: locations.length });

        return rawData.map((row) => ({
          id: row.id,
          name: row.name,
          success: row.success,
          errorMessage: row.error_message,
        }));
      } finally {
        setIsInserting(false);
        setProgress(null);
      }
    },
    []
  );

  return {
    bulkInsert,
    isInserting,
    progress,
  };
}

/**
 * Hook to fetch all active locations for map display
 */
export function useActiveLocations() {
  return useLocations({
    isActive: true,
    limit: 500, // Get all active locations
    sortBy: 'name',
    sortOrder: 'asc',
  });
}
