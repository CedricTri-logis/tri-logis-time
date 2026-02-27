'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import { MapPin, Check, Loader2 } from 'lucide-react';
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from '@/components/ui/popover';
import { supabaseClient } from '@/lib/supabase/client';
import { toast } from 'sonner';

interface NearbyLocation {
  id: string;
  name: string;
  location_type: string;
  distance_meters: number;
  radius_meters: number;
}

interface LocationPickerDropdownProps {
  tripId: string;
  endpoint: 'start' | 'end';
  latitude: number;
  longitude: number;
  currentLocationId: string | null;
  currentLocationName: string | null;
  displayText: string;
  onLocationChanged: () => void;
}

// Shared geocode cache + throttled queue (module-level, shared across all instances)
const geocodeCache = new Map<string, string>();
const geocodeQueue: Array<() => void> = [];
let geocodeActive = 0;
const MAX_CONCURRENT_GEOCODES = 3;

function enqueueGeocode(fn: () => Promise<void>) {
  const run = async () => {
    geocodeActive++;
    try {
      await fn();
    } finally {
      geocodeActive--;
      const next = geocodeQueue.shift();
      if (next) next();
    }
  };
  if (geocodeActive < MAX_CONCURRENT_GEOCODES) {
    run();
  } else {
    geocodeQueue.push(run);
  }
}

export function LocationPickerDropdown({
  tripId,
  endpoint,
  latitude,
  longitude,
  currentLocationId,
  currentLocationName,
  displayText,
  onLocationChanged,
}: LocationPickerDropdownProps) {
  const [open, setOpen] = useState(false);
  const [nearbyLocations, setNearbyLocations] = useState<NearbyLocation[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [resolvedAddress, setResolvedAddress] = useState<string | null>(null);
  const geocodedRef = useRef(false);

  // Reverse geocode to get a readable address when no location name is set
  useEffect(() => {
    if (currentLocationName || geocodedRef.current) return;

    const cacheKey = `${latitude.toFixed(6)},${longitude.toFixed(6)}`;
    const cached = geocodeCache.get(cacheKey);
    if (cached) {
      setResolvedAddress(cached);
      geocodedRef.current = true;
      return;
    }

    const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;
    if (!apiKey) return;

    geocodedRef.current = true;
    let cancelled = false;
    enqueueGeocode(async () => {
      // Re-check cache (another instance may have resolved it while queued)
      const cachedNow = geocodeCache.get(cacheKey);
      if (cachedNow) {
        if (!cancelled) setResolvedAddress(cachedNow);
        return;
      }
      try {
        const res = await fetch(
          `https://maps.googleapis.com/maps/api/geocode/json?latlng=${latitude},${longitude}&key=${apiKey}&language=fr`
        );
        const data = await res.json();
        const addr = data.results?.[0]?.formatted_address;
        if (addr) {
          geocodeCache.set(cacheKey, addr);
          if (!cancelled) setResolvedAddress(addr);
        }
      } catch {
        /* keep displayText fallback */
      }
    });
    return () => { cancelled = true; };
  }, [latitude, longitude, currentLocationName]);

  const fetchNearby = useCallback(async () => {
    setIsLoading(true);
    const { data, error } = await supabaseClient.rpc('get_nearby_locations', {
      p_latitude: latitude,
      p_longitude: longitude,
      p_limit: 10,
    });
    if (error) {
      toast.error('Erreur lors du chargement des emplacements');
    } else {
      setNearbyLocations(data || []);
    }
    setIsLoading(false);
  }, [latitude, longitude]);

  useEffect(() => {
    if (open) fetchNearby();
  }, [open, fetchNearby]);

  const handleSelect = async (locationId: string | null) => {
    setIsSaving(true);
    const { error } = await supabaseClient.rpc('update_trip_location', {
      p_trip_id: tripId,
      p_endpoint: endpoint,
      p_location_id: locationId,
    });
    if (error) {
      toast.error('Erreur lors de la mise à jour');
    } else {
      toast.success('Emplacement mis à jour');
      onLocationChanged();
    }
    setIsSaving(false);
    setOpen(false);
  };

  const triggerText = currentLocationName || resolvedAddress || displayText;
  const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY || '';
  const staticMapUrl = apiKey
    ? `https://maps.googleapis.com/maps/api/staticmap?center=${latitude},${longitude}&zoom=16&size=268x140&scale=2&markers=color:red%7C${latitude},${longitude}&key=${apiKey}`
    : '';

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button
          className="flex items-center gap-0.5 text-xs cursor-pointer hover:underline truncate"
          title={`Cliquer pour modifier (${endpoint === 'start' ? 'départ' : 'arrivée'})`}
          onClick={(e) => e.stopPropagation()}
        >
          {currentLocationName ? (
            <span className="flex items-center gap-0.5 text-emerald-700 font-medium truncate">
              <MapPin className="h-3 w-3 flex-shrink-0 text-emerald-500" />
              {currentLocationName}
            </span>
          ) : (
            <span className="truncate opacity-70">{triggerText}</span>
          )}
        </button>
      </PopoverTrigger>
      <PopoverContent className="w-72 p-2" align="start">
        <div className="text-xs font-medium text-muted-foreground mb-2">
          {endpoint === 'start' ? 'Emplacement de départ' : "Emplacement d'arrivée"}
        </div>

        {/* Mini map preview */}
        {staticMapUrl && (
          <div className="mb-2 rounded-md overflow-hidden border border-slate-200">
            <img
              src={staticMapUrl}
              alt="Aperçu de la localisation"
              className="w-full h-[140px] object-cover"
              loading="lazy"
            />
          </div>
        )}

        {/* Resolved address under map */}
        {!currentLocationName && resolvedAddress && (
          <p className="text-[10px] text-muted-foreground mb-2 leading-tight">
            {resolvedAddress}
          </p>
        )}

        {isLoading ? (
          <div className="flex items-center justify-center py-4">
            <Loader2 className="h-4 w-4 animate-spin" />
          </div>
        ) : (
          <div className="space-y-1 max-h-60 overflow-y-auto">
            <button
              onClick={() => handleSelect(null)}
              disabled={isSaving}
              className={`w-full text-left px-2 py-1.5 rounded text-xs hover:bg-muted flex items-center justify-between ${
                currentLocationId === null ? 'bg-muted' : ''
              }`}
            >
              <span className="text-muted-foreground italic">Aucun / Inconnu</span>
              {currentLocationId === null && <Check className="h-3 w-3 text-emerald-500" />}
            </button>
            {nearbyLocations.map((loc) => (
              <button
                key={loc.id}
                onClick={() => handleSelect(loc.id)}
                disabled={isSaving}
                className={`w-full text-left px-2 py-1.5 rounded text-xs hover:bg-muted flex items-center justify-between ${
                  currentLocationId === loc.id ? 'bg-muted' : ''
                }`}
              >
                <div className="truncate">
                  <span className="font-medium">{loc.name}</span>
                  <span className="text-muted-foreground ml-1">
                    ({Math.round(loc.distance_meters)}m)
                  </span>
                </div>
                {currentLocationId === loc.id && <Check className="h-3 w-3 text-emerald-500" />}
              </button>
            ))}
            {nearbyLocations.length === 0 && (
              <div className="text-xs text-muted-foreground text-center py-2">
                Aucun emplacement trouvé
              </div>
            )}
          </div>
        )}
      </PopoverContent>
    </Popover>
  );
}
