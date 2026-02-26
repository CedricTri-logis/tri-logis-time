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
  onSubmit,
  onCancel,
  isSubmitting = false,
}: LocationFormProps) {
  const [isGeocoding, setIsGeocoding] = useState(false);
  const [geocodeError, setGeocodeError] = useState<string | null>(null);

  const form = useForm<LocationFormInput>({
    resolver: zodResolver(locationFormSchema),
    defaultValues: {
      name: location?.name ?? '',
      location_type: location?.locationType ?? 'office',
      latitude: location?.latitude ?? 0,
      longitude: location?.longitude ?? 0,
      radius_meters: location?.radiusMeters ?? 100,
      address: location?.address ?? '',
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
      setGeocodeError('Please enter an address to search');
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
        error instanceof Error ? error.message : 'Failed to geocode address'
      );
    } finally {
      setIsGeocoding(false);
    }
  }, [form]);

  // Handle form submission
  const handleSubmit = form.handleSubmit(async (data) => {
    if (data.latitude === 0 && data.longitude === 0) {
      form.setError('latitude', { message: 'Please select a location on the map' });
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
            <CardTitle className="text-base">Basic Information</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <FormField
              control={form.control}
              name="name"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Location Name *</FormLabel>
                  <FormControl>
                    <Input
                      placeholder="e.g., Head Office, Construction Site A"
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
                  <FormLabel>Location Type *</FormLabel>
                  <Select
                    onValueChange={field.onChange}
                    defaultValue={field.value}
                  >
                    <FormControl>
                      <SelectTrigger>
                        <SelectValue placeholder="Select type" />
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
                    <FormLabel>Active</FormLabel>
                    <FormDescription className="text-xs">
                      Active locations are used for GPS matching
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
            <CardTitle className="text-base">Address</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <FormField
              control={form.control}
              name="address"
              render={({ field }) => (
                <FormItem>
                  <FormLabel>Street Address</FormLabel>
                  <div className="flex gap-2">
                    <FormControl>
                      <Input
                        placeholder="e.g., 123 Main St, Montreal, QC"
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
                      <span className="ml-2 hidden sm:inline">Search</span>
                    </Button>
                  </div>
                  <FormDescription className="text-xs">
                    Enter an address and click Search to auto-fill coordinates
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
            <CardTitle className="text-base">Location on Map *</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <p className="text-sm text-slate-500 mb-2">
              Click on the map to set the location, or drag the marker to adjust
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
            <CardTitle className="text-base">Geofence Radius</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <FormField
              control={form.control}
              name="radius_meters"
              render={({ field }) => (
                <FormItem>
                  <div className="flex items-center justify-between">
                    <FormLabel>Radius</FormLabel>
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
                    Employees within this radius will be matched to this location
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
                      placeholder="Optional notes about this location..."
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
              Cancel
            </Button>
          )}
          <Button type="submit" disabled={isSubmitting}>
            {isSubmitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
            {location ? 'Update Location' : 'Create Location'}
          </Button>
        </div>
      </form>
    </Form>
  );
}
