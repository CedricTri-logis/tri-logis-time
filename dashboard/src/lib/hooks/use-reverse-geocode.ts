'use client';

import { useState, useEffect, useMemo } from 'react';

interface GeoPoint {
  latitude: number;
  longitude: number;
}

export interface GeocodeResult {
  formatted_address: string | null;
  place_name: string | null;
}

// Module-level in-memory cache — survives re-renders and component remounts
const sessionCache = new Map<string, GeocodeResult>();

function cacheKey(lat: number, lng: number): string {
  return `${lat.toFixed(5)},${lng.toFixed(5)}`;
}

/**
 * Batch reverse-geocode a list of points.
 * Returns a Map keyed by "lat,lng" (5 decimal places) → GeocodeResult.
 * Uses: session memory cache → server geocode_cache → Google API (stored back to cache).
 */
export function useReverseGeocode(points: GeoPoint[]) {
  const [results, setResults] = useState<Map<string, GeocodeResult>>(new Map());
  const [isLoading, setIsLoading] = useState(false);

  // Serialize points into a stable string for useEffect dependency
  const stableKey = useMemo(() => {
    const keys: string[] = [];
    for (const p of points) {
      if (p.latitude != null && p.longitude != null) {
        keys.push(cacheKey(p.latitude, p.longitude));
      }
    }
    // Deduplicate and sort for stability
    return [...new Set(keys)].sort().join('|');
  }, [points]);

  useEffect(() => {
    if (!stableKey) return;

    const keys = stableKey.split('|');

    // Separate cached vs. uncached
    const fromCache = new Map<string, GeocodeResult>();
    const toFetch: GeoPoint[] = [];

    for (const key of keys) {
      const hit = sessionCache.get(key);
      if (hit) {
        fromCache.set(key, hit);
      } else {
        const [lat, lng] = key.split(',').map(Number);
        toFetch.push({ latitude: lat, longitude: lng });
      }
    }

    // Apply cached results immediately
    if (fromCache.size > 0) {
      setResults((prev) => {
        const next = new Map(prev);
        fromCache.forEach((v, k) => next.set(k, v));
        return next;
      });
    }

    if (toFetch.length === 0) return;

    let cancelled = false;
    setIsLoading(true);

    fetch('/api/reverse-geocode', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ points: toFetch }),
    })
      .then((res) => res.json())
      .then((data) => {
        if (cancelled || !data.success || !data.results) return;
        const fetched = new Map<string, GeocodeResult>();
        toFetch.forEach((p, i) => {
          const key = cacheKey(p.latitude, p.longitude);
          const result = data.results[i];
          sessionCache.set(key, result);
          fetched.set(key, result);
        });
        setResults((prev) => {
          const next = new Map(prev);
          fetched.forEach((v, k) => next.set(k, v));
          return next;
        });
      })
      .catch(console.error)
      .finally(() => {
        if (!cancelled) setIsLoading(false);
      });

    return () => { cancelled = true; };
  }, [stableKey]);

  return { results, isLoading };
}

/**
 * Helper to resolve a geocoded display name for an activity.
 * Returns place_name > formatted_address > fallback.
 */
export function resolveGeocodedName(
  lat: number | null,
  lng: number | null,
  geocodedAddresses: Map<string, GeocodeResult> | undefined,
  fallback: string
): string {
  if (lat == null || lng == null || !geocodedAddresses) return fallback;
  const key = cacheKey(lat, lng);
  const geo = geocodedAddresses.get(key);
  if (geo?.place_name) return geo.place_name;
  if (geo?.formatted_address) return geo.formatted_address;
  return fallback;
}
