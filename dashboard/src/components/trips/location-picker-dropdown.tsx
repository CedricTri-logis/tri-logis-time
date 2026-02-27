'use client';

import { useState, useEffect, useCallback } from 'react';
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

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button
          className="flex items-center gap-0.5 text-xs cursor-pointer hover:underline truncate"
          title={`Cliquer pour modifier (${endpoint === 'start' ? 'depart' : 'arrivee'})`}
          onClick={(e) => e.stopPropagation()}
        >
          {currentLocationName ? (
            <span className="flex items-center gap-0.5 text-emerald-700 font-medium truncate">
              <MapPin className="h-3 w-3 flex-shrink-0 text-emerald-500" />
              {currentLocationName}
            </span>
          ) : (
            <span className="truncate opacity-70">{displayText}</span>
          )}
        </button>
      </PopoverTrigger>
      <PopoverContent className="w-72 p-2" align="start">
        <div className="text-xs font-medium text-muted-foreground mb-2">
          {endpoint === 'start' ? 'Emplacement de depart' : "Emplacement d'arrivee"}
        </div>
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
                Aucun emplacement trouve
              </div>
            )}
          </div>
        )}
      </PopoverContent>
    </Popover>
  );
}
