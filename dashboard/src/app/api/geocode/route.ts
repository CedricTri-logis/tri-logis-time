import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';

const geocodeSchema = z.object({
  address: z.string().min(1).max(500),
});

interface GeocodeResult {
  lat: number;
  lng: number;
  formattedAddress: string;
}

// In-memory cache (use Redis in production for distributed caching)
const cache = new Map<string, { data: GeocodeResult; timestamp: number }>();
const CACHE_TTL = 24 * 60 * 60 * 1000; // 24 hours

/**
 * POST /api/geocode
 * Convert address to coordinates using Google Maps Geocoding API
 * Falls back to Nominatim (OpenStreetMap) if Google API is not configured
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const parseResult = geocodeSchema.safeParse(body);

    if (!parseResult.success) {
      return NextResponse.json(
        { success: false, error: 'Invalid address' },
        { status: 400 }
      );
    }

    const { address } = parseResult.data;

    // Check cache
    const cacheKey = address.toLowerCase().trim();
    const cached = cache.get(cacheKey);
    if (cached && Date.now() - cached.timestamp < CACHE_TTL) {
      return NextResponse.json({
        success: true,
        data: cached.data,
        cached: true,
      });
    }

    // Try Google Maps API first if key is configured
    const googleApiKey = process.env.GOOGLE_MAPS_API_KEY;
    if (googleApiKey) {
      try {
        const result = await geocodeWithGoogle(address, googleApiKey);
        if (result) {
          cache.set(cacheKey, { data: result, timestamp: Date.now() });
          return NextResponse.json({ success: true, data: result });
        }
      } catch (error) {
        console.error('Google geocoding error:', error);
        // Fall through to Nominatim
      }
    }

    // Fallback to Nominatim (OpenStreetMap)
    try {
      const result = await geocodeWithNominatim(address);
      if (result) {
        cache.set(cacheKey, { data: result, timestamp: Date.now() });
        return NextResponse.json({ success: true, data: result });
      }
    } catch (error) {
      console.error('Nominatim geocoding error:', error);
    }

    return NextResponse.json(
      { success: false, error: 'Address not found' },
      { status: 404 }
    );
  } catch (error) {
    console.error('Geocoding error:', error);
    return NextResponse.json(
      { success: false, error: 'Geocoding service unavailable' },
      { status: 500 }
    );
  }
}

async function geocodeWithGoogle(
  address: string,
  apiKey: string
): Promise<GeocodeResult | null> {
  const url = new URL('https://maps.googleapis.com/maps/api/geocode/json');
  url.searchParams.set('address', address);
  url.searchParams.set('key', apiKey);

  const response = await fetch(url.toString());
  const data = await response.json();

  if (data.status === 'OK' && data.results.length > 0) {
    const result = data.results[0];
    return {
      lat: result.geometry.location.lat,
      lng: result.geometry.location.lng,
      formattedAddress: result.formatted_address,
    };
  }

  if (data.status === 'ZERO_RESULTS') {
    return null;
  }

  if (data.status === 'OVER_QUERY_LIMIT') {
    throw new Error('API rate limit exceeded');
  }

  if (data.status === 'REQUEST_DENIED') {
    throw new Error('API request denied - check API key configuration');
  }

  return null;
}

async function geocodeWithNominatim(
  address: string
): Promise<GeocodeResult | null> {
  const url = new URL('https://nominatim.openstreetmap.org/search');
  url.searchParams.set('q', address);
  url.searchParams.set('format', 'json');
  url.searchParams.set('limit', '1');
  url.searchParams.set('addressdetails', '1');

  const response = await fetch(url.toString(), {
    headers: {
      'User-Agent': 'GPS-Tracker-Dashboard/1.0 (location geocoding)',
    },
  });

  const results = await response.json();

  if (results.length === 0) {
    return null;
  }

  const result = results[0];
  return {
    lat: parseFloat(result.lat),
    lng: parseFloat(result.lon),
    formattedAddress: result.display_name,
  };
}
