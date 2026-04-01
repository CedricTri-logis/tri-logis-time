import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { createAdminClient, createAdminWorkforceClient } from '@/lib/supabase/admin';

const SEARCH_RADIUS_METERS = 55; // matches DBSCAN eps=0.0005 (~55m)

const pointSchema = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
});

const batchSchema = z.object({
  points: z.array(pointSchema).min(1).max(100),
});

interface ReverseGeocodeResult {
  formatted_address: string | null;
  place_name: string | null;
}

async function reverseGeocodeGoogle(
  lat: number,
  lng: number,
  apiKey: string
): Promise<{ address: string | null; placeName: string | null }> {
  let address: string | null = null;
  let placeName: string | null = null;

  // 1. Reverse geocode for address
  try {
    const geoRes = await fetch(
      `https://maps.googleapis.com/maps/api/geocode/json?latlng=${lat},${lng}&key=${apiKey}&language=fr`
    );
    const geoData = await geoRes.json();
    address = geoData.results?.[0]?.formatted_address || null;
  } catch {
    /* keep null */
  }

  // 2. Places Nearby Search for business name
  try {
    const placesRes = await fetch(
      'https://places.googleapis.com/v1/places:searchNearby',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask':
            'places.displayName,places.formattedAddress,places.types',
        },
        body: JSON.stringify({
          locationRestriction: {
            circle: {
              center: { latitude: lat, longitude: lng },
              radius: 50.0,
            },
          },
          maxResultCount: 1,
          languageCode: 'fr',
        }),
      }
    );
    const placesData = await placesRes.json();
    placeName = placesData.places?.[0]?.displayName?.text || null;
    if (!address && placesData.places?.[0]?.formattedAddress) {
      address = placesData.places[0].formattedAddress;
    }
  } catch {
    /* no business name found */
  }

  return { address, placeName };
}

/**
 * POST /api/reverse-geocode
 *
 * Accepts { points: [{ latitude, longitude }, ...] } (max 100)
 * Returns { results: [{ formatted_address, place_name }, ...] }
 *
 * For each point: checks geocode_cache (spatial match within 55m).
 * On cache miss: calls Google reverse geocode + Places Nearby, stores result in cache.
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const parseResult = batchSchema.safeParse(body);

    if (!parseResult.success) {
      return NextResponse.json(
        { success: false, error: 'Invalid input' },
        { status: 400 }
      );
    }

    const { points } = parseResult.data;
    const supabase = createAdminWorkforceClient();
    const apiKey = process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;
    const results: ReverseGeocodeResult[] = [];

    for (const point of points) {
      // 1. Check cache (spatial match within 55m)
      const { data: cached } = await supabase
        .rpc('find_geocode_cache', {
          p_lat: point.latitude,
          p_lng: point.longitude,
          p_radius: SEARCH_RADIUS_METERS,
        });

      if (cached && cached.length > 0) {
        results.push({
          formatted_address: cached[0].formatted_address,
          place_name: cached[0].place_name,
        });
        continue;
      }

      // 2. Cache miss — call Google (skip if no API key)
      if (!apiKey) {
        results.push({ formatted_address: null, place_name: null });
        continue;
      }

      const { address, placeName } = await reverseGeocodeGoogle(
        point.latitude,
        point.longitude,
        apiKey
      );

      // 3. Store in cache if we got an address
      if (address) {
        await supabase
          .from('geocode_cache')
          .insert({
            location: `SRID=4326;POINT(${point.longitude} ${point.latitude})`,
            formatted_address: address,
            place_name: placeName,
          });
      }

      results.push({
        formatted_address: address,
        place_name: placeName,
      });
    }

    return NextResponse.json({ success: true, results });
  } catch (error) {
    console.error('Reverse geocode error:', error);
    return NextResponse.json(
      { success: false, error: 'Reverse geocoding failed' },
      { status: 500 }
    );
  }
}
