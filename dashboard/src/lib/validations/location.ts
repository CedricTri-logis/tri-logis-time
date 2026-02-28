import { z } from 'zod';

// Location type enum values
export const LocationTypeEnum = {
  OFFICE: 'office',
  BUILDING: 'building',
  VENDOR: 'vendor',
  HOME: 'home',
  CAFE_RESTAURANT: 'cafe_restaurant',
  GAZ: 'gaz',
  OTHER: 'other',
} as const;

export type LocationTypeValue = (typeof LocationTypeEnum)[keyof typeof LocationTypeEnum];

export const LOCATION_TYPE_VALUES = ['office', 'building', 'vendor', 'home', 'cafe_restaurant', 'gaz', 'other'] as const;

// Location type display names
export const LOCATION_TYPE_LABELS: Record<LocationTypeValue, string> = {
  office: 'Office',
  building: 'Immeuble',
  vendor: 'Vendor',
  home: 'Home',
  cafe_restaurant: 'Café / Restaurant',
  gaz: 'Gas Station',
  other: 'Other',
};

// Schema for location form (create/edit)
export const locationFormSchema = z.object({
  name: z
    .string()
    .min(1, 'Name is required')
    .max(100, 'Name must be 100 characters or less'),
  location_type: z.enum(LOCATION_TYPE_VALUES, {
    message: 'Location type is required',
  }),
  latitude: z
    .number({ message: 'Latitude must be a number' })
    .min(-90, 'Latitude must be between -90 and 90')
    .max(90, 'Latitude must be between -90 and 90'),
  longitude: z
    .number({ message: 'Longitude must be a number' })
    .min(-180, 'Longitude must be between -180 and 180')
    .max(180, 'Longitude must be between -180 and 180'),
  radius_meters: z
    .number({ message: 'Radius must be a number' })
    .min(10, 'Radius must be at least 10 meters')
    .max(200, 'Radius cannot exceed 200 meters'),
  address: z.string().max(500, 'Address must be 500 characters or less').nullable().optional(),
  notes: z.string().max(1000, 'Notes must be 1000 characters or less').nullable().optional(),
  is_active: z.boolean(),
});

export type LocationFormInput = z.infer<typeof locationFormSchema>;

// Schema for CSV row validation
export const locationCsvRowSchema = z.object({
  name: z
    .string()
    .min(1, 'Name is required')
    .max(100, 'Name must be 100 characters or less'),
  location_type: z
    .string()
    .transform((val) => val.toLowerCase().trim())
    .pipe(
      z.enum(LOCATION_TYPE_VALUES, {
        message: `Location type must be one of: ${LOCATION_TYPE_VALUES.join(', ')}`,
      })
    ),
  latitude: z.coerce
    .number({ message: 'Latitude must be a number' })
    .min(-90, 'Latitude must be between -90 and 90')
    .max(90, 'Latitude must be between -90 and 90'),
  longitude: z.coerce
    .number({ message: 'Longitude must be a number' })
    .min(-180, 'Longitude must be between -180 and 180')
    .max(180, 'Longitude must be between -180 and 180'),
  radius_meters: z.coerce
    .number({ message: 'Radius must be a number' })
    .min(10, 'Radius must be at least 10 meters')
    .max(200, 'Radius cannot exceed 200 meters')
    .optional()
    .default(40),
  address: z.string().max(500).optional().nullable().default(null),
  notes: z.string().max(1000).optional().nullable().default(null),
  is_active: z
    .union([z.boolean(), z.string()])
    .optional()
    .transform((val) => {
      if (typeof val === 'boolean') return val;
      if (typeof val === 'string') {
        const lower = val.toLowerCase().trim();
        return lower === 'true' || lower === '1' || lower === 'yes';
      }
      return true;
    })
    .default(true),
});

export type LocationCsvRowInput = z.infer<typeof locationCsvRowSchema>;

// Schema for location filter params
export const locationFilterSchema = z.object({
  search: z.string().optional(),
  location_type: z.enum(LOCATION_TYPE_VALUES).optional(),
  is_active: z.boolean().optional(),
  sort_by: z.enum(['name', 'created_at', 'updated_at', 'location_type']).default('name'),
  sort_order: z.enum(['asc', 'desc']).default('asc'),
});

export type LocationFilterInput = z.infer<typeof locationFilterSchema>;

// Schema for pagination params
export const paginationSchema = z.object({
  limit: z.number().min(1).max(100).default(20),
  offset: z.number().min(0).default(0),
});

export type PaginationInput = z.infer<typeof paginationSchema>;

// Schema for bulk insert input
export const bulkInsertSchema = z.array(
  z.object({
    name: z.string().min(1),
    location_type: z.enum(LOCATION_TYPE_VALUES),
    latitude: z.number().min(-90).max(90),
    longitude: z.number().min(-180).max(180),
    radius_meters: z.number().min(10).max(200).optional().default(40),
    address: z.string().nullable().optional(),
    notes: z.string().nullable().optional(),
    is_active: z.boolean().optional().default(true),
  })
);

export type BulkInsertInput = z.infer<typeof bulkInsertSchema>;

// CSV expected headers
export const CSV_EXPECTED_HEADERS = [
  'name',
  'location_type',
  'latitude',
  'longitude',
] as const;

export const CSV_OPTIONAL_HEADERS = [
  'radius_meters',
  'address',
  'notes',
  'is_active',
] as const;

export const CSV_ALL_HEADERS = [...CSV_EXPECTED_HEADERS, ...CSV_OPTIONAL_HEADERS] as const;

// Helper to validate CSV headers
export function validateCsvHeaders(headers: string[]): {
  valid: boolean;
  missingRequired: string[];
  unknownHeaders: string[];
} {
  const normalizedHeaders = headers.map((h) => h.toLowerCase().trim());
  const missingRequired = CSV_EXPECTED_HEADERS.filter(
    (h) => !normalizedHeaders.includes(h)
  );
  const unknownHeaders = normalizedHeaders.filter(
    (h) => !CSV_ALL_HEADERS.includes(h as (typeof CSV_ALL_HEADERS)[number])
  );

  return {
    valid: missingRequired.length === 0,
    missingRequired,
    unknownHeaders,
  };
}
