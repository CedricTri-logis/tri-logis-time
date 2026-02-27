'use client';

import { useState, useCallback, useEffect } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import dynamic from 'next/dynamic';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Slider } from '@/components/ui/slider';
import { Skeleton } from '@/components/ui/skeleton';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Form,
  FormControl,
  FormDescription,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from '@/components/ui/form';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

// Dynamic import to avoid SSR issues
const LocationMap = dynamic(
  () => import('./google-location-map').then((mod) => mod.GoogleLocationMap),
  {
    ssr: false,
    loading: () => <Skeleton className="h-[300px] w-full rounded-lg" />,
  }
);
import {
  locationFormSchema,
  LOCATION_TYPE_VALUES,
  LOCATION_TYPE_LABELS,
  type LocationFormInput,
} from '@/lib/validations/location';
import { LOCATION_TYPE_COLORS } from '@/lib/utils/segment-colors';
import type { Location, LocationType } from '@/types/location';
import { Building2, HardHat, Truck, Home, MapPin, Search, Loader2 } from 'lucide-react';

interface LocationFormProps {
  location?: Location | null;
  /** Pre-fill values for creating a new location (does not trigger "edit" mode) */
  prefill?: {
    name?: string;
    address?: string;
    latitude?: number;
    longitude?: number;
  } | null;
  onSubmit: (data: LocationFormInput) => Promise<void>;
  onCancel?: () => void;
  isSubmitting?: boolean;
}

const LOCATION_TYPE_ICONS: Record<LocationType, React.ElementType> = {
  office: Building2,
  building: HardHat,
  vendor: Truck,
  home: Home,
  other: MapPin,
};

/**
 * Form for creating/editing a location with interactive map.
 * Click on map to set coordinates, use slider to adjust radius.
 */
export function LocationForm({
  location,
  prefill,
  onSubmit,
  onCancel,
  isSubmitting = false,
}: LocationFormProps) {
  const [isGeocoding, setIsGeocoding] = useState(false);
  const [geocodeError, setGeocodeError] = useState<string | null>(null);

  const form = useForm<LocationFormInput>({
    resolver: zodResolver(locationFormSchema),
    defaultValues: {
      name: location?.name ?? prefill?.name ?? '',
      location_type: location?.locationType ?? 'office',
      latitude: location?.latitude ?? prefill?.latitude ?? 0,
      longitude: location?.longitude ?? prefill?.longitude ?? 0,
      radius_meters: location?.radiusMeters ?? 100,
      address: location?.address ?? prefill?.address ?? '',
      notes: location?.notes ?? '',
      is_active: location?.isActive ?? true,
    },
  });

  const latitude = form.watch('latitude');
  const longitude = form.watch('longitude');
  const radius = form.watch('radius_meters');
  const locationType = form.watch('location_type');
  const address = form.watch('address');

  // Position for map (null if coordinates are default/unset)
  const mapPosition: [number, number] | null =
    latitude !== 0 || longitude !== 0 ? [latitude, longitude] : null;

  // Handle map position change
  const handlePositionChange = useCallback(
    (lat: number, lng: number) => {
      form.setValue('latitude', lat, { shouldValidate: true });
      form.setValue('longitude', lng, { shouldValidate: true });
    },
    [form]
  );

  // Handle radius slider change
  const handleRadiusChange = useCallback(
    (value: number[]) => {
      form.setValue('radius_meters', value[0], { shouldValidate: true });
    },
    [form]
  );

  // Geocode address to coordinates
  const handleGeocode = useCallback(async () => {
    const currentAddress = form.getValues('address');
    if (!currentAddress || currentAddress.trim().length < 3) {
      setGeocodeError('Veuillez entrer une adresse pour rechercher');
      return;
    }

    setIsGeocoding(true);
    setGeocodeError(null);

    try {
      const response = await fetch('/api/geocode', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ address: currentAddress }),
      });

      const data = await response.json();

      if (!response.ok) {
        throw new Error(data.error || 'Geocoding failed');
      }

      form.setValue('latitude', data.data.lat, { shouldValidate: true });
      form.setValue('longitude', data.data.lng, { shouldValidate: true });
      if (data.data.formattedAddress) {
        form.setValue('address', data.data.formattedAddress);
      }
    } catch (error) {
      setGeocodeError(
        error instanceof Error ? error.message : 'Échec du géocodage de l\'adresse'
      );
    } finally {
      setIsGeocoding(false);
    }
  }, [form]);

  // Handle form submission
  const handleSubmit = form.handleSubmit(async (data) => {
    if (data.latitude === 0 && data.longitude === 0) {
      form.setError('latitude', { message: 'Veuillez sélectionner un emplacement sur la carte' });
      return;
    }
    await onSubmit(data);
  });

  return (
    <Form {...form}>
      <form onSubmit={handleSubmit} className="space-y-6">
        {/* Basic Information */}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Informations de base</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <FormField
              control={form.control}
              name="name"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Nom de l'emplacement *</FormLabel>
                  <FormControl>
                    <Input
                      placeholder="ex. Bureau principal, Chantier A"
                      {...field}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="location_type"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Type d'emplacement *</FormLabel>
                  <Select
                    onValueChange={field.onChange}
                    defaultValue={field.value}
                  >
                    <FormControl>
                      <SelectTrigger>
                        <SelectValue placeholder="Sélectionner le type" />
                      </SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      {LOCATION_TYPE_VALUES.map((type) => {
                        const Icon = LOCATION_TYPE_ICONS[type];
                        const color = LOCATION_TYPE_COLORS[type].color;
                        return (
                          <SelectItem key={type} value={type}>
                            <div className="flex items-center gap-2">
                              <Icon className="h-4 w-4" style={{ color }} />
                              <span>{LOCATION_TYPE_LABELS[type]}</span>
                            </div>
                          </SelectItem>
                        );
                      })}
                    </SelectContent>
                  </Select>
                  <FormMessage />
                </FormItem>
              )}
            />

            <FormField
              control={form.control}
              name="is_active"
              render={({ field }) => (
                <FormItem className="flex flex-row items-center justify-between rounded-lg border p-3">
                  <div className="space-y-0.5">
                    <FormLabel>Actif</FormLabel>
                    <FormDescription className="text-xs">
                      Les emplacements actifs sont utilisés pour la correspondance GPS
                    </FormDescription>
                  </div>
                  <FormControl>
                    <input
                      type="checkbox"
                      checked={field.value}
                      onChange={field.onChange}
                      className="h-4 w-4 rounded border-slate-300"
                    />
                  </FormControl>
                </FormItem>
              )}
            />
          </CardContent>
        </Card>

        {/* Address & Geocoding */}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Adresse</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <FormField
              control={form.control}
              name="address"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Adresse</FormLabel>
                  <div className="flex gap-2">
                    <FormControl>
                      <Input
                        placeholder="ex. 123 rue Principale, Montréal, QC"
                        {...field}
                        value={field.value ?? ''}
                      />
                    </FormControl>
                    <Button
                      type="button"
                      variant="outline"
                      onClick={handleGeocode}
                      disabled={isGeocoding}
                    >
                      {isGeocoding ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <Search className="h-4 w-4" />
                      )}
                      <span className="ml-2 hidden sm:inline">Rechercher</span>
                    </Button>
                  </div>
                  <FormDescription className="text-xs">
                    Entrez une adresse et cliquez sur Rechercher pour remplir les coordonnées automatiquement
                  </FormDescription>
                  {geocodeError && (
                    <p className="text-sm text-red-500">{geocodeError}</p>
                  )}
                  <FormMessage />
                </FormItem>
              )}
            />
          </CardContent>
        </Card>

        {/* Map & Coordinates */}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Emplacement sur la carte *</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <p className="text-sm text-slate-500 mb-2">
              Cliquez sur la carte pour définir l'emplacement, ou glissez le marqueur pour ajuster
            </p>

            <LocationMap
              position={mapPosition}
              radius={radius}
              locationType={locationType}
              onPositionChange={handlePositionChange}
              className="h-[350px] w-full rounded-lg border"
            />

            <div className="grid grid-cols-2 gap-4">
              <FormField
                control={form.control}
                name="latitude"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Latitude</FormLabel>
                    <FormControl>
                      <Input
                        type="number"
                        step="any"
                        placeholder="45.5017"
                        {...field}
                        onChange={(e) =>
                          field.onChange(parseFloat(e.target.value) || 0)
                        }
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />

              <FormField
                control={form.control}
                name="longitude"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>Longitude</FormLabel>
                    <FormControl>
                      <Input
                        type="number"
                        step="any"
                        placeholder="-73.5673"
                        {...field}
                        onChange={(e) =>
                          field.onChange(parseFloat(e.target.value) || 0)
                        }
                      />
                    </FormControl>
                    <FormMessage />
                  </FormItem>
                )}
              />
            </div>
          </CardContent>
        </Card>

        {/* Geofence Radius */}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Rayon de géorepérage</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <FormField
              control={form.control}
              name="radius_meters"
              render={({ field }) => (
                <FormItem>
                  <div className="flex items-center justify-between">
                    <FormLabel>Rayon</FormLabel>
                    <span className="text-sm font-medium">{field.value}m</span>
                  </div>
                  <FormControl>
                    <Slider
                      value={[field.value]}
                      onValueChange={handleRadiusChange}
                      min={10}
                      max={1000}
                      step={10}
                      className="mt-2"
                    />
                  </FormControl>
                  <FormDescription className="text-xs">
                    Les employés dans ce rayon seront associés à cet emplacement
                  </FormDescription>
                  <FormMessage />
                </FormItem>
              )}
            />
          </CardContent>
        </Card>

        {/* Notes */}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Notes</CardTitle>

          </CardHeader>
          <CardContent>
            <FormField
              control={form.control}
              name="notes"
              render={({ field }) => (
                <FormItem>
                  <FormControl>
                    <textarea
                      className="w-full min-h-[80px] px-3 py-2 text-sm rounded-md border border-slate-200 focus:outline-none focus:ring-2 focus:ring-blue-500 resize-y"
                      placeholder="Notes optionnelles sur cet emplacement..."
                      {...field}
                      value={field.value ?? ''}
                    />
                  </FormControl>
                  <FormMessage />
                </FormItem>
              )}
            />
          </CardContent>
        </Card>

        {/* Actions */}
        <div className="flex gap-3 justify-end">
          {onCancel && (
            <Button
              type="button"
              variant="outline"
              onClick={onCancel}
              disabled={isSubmitting}
            >
              Annuler
            </Button>
          )}
          <Button type="submit" disabled={isSubmitting}>
            {isSubmitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
            {location ? 'Modifier l\'emplacement' : 'Créer l\'emplacement'}
          </Button>
        </div>
      </form>
    </Form>
  );
}
