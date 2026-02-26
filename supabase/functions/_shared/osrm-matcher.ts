import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export interface GpsPoint {
  latitude: number;
  longitude: number;
  accuracy: number | null;
  captured_at: string;
}

export interface MatchResult {
  success: boolean;
  match_status: "matched" | "failed" | "anomalous";
  route_geometry: string | null;
  road_distance_km: number | null;
  match_confidence: number | null;
  match_error: string | null;
  geometry_points: number;
}

/**
 * Simplify a GPS trace by selecting every Nth point, preserving first and last.
 */
export function simplifyTrace(
  points: GpsPoint[],
  maxPoints: number
): GpsPoint[] {
  if (points.length <= maxPoints) return points;
  const step = (points.length - 2) / (maxPoints - 2);
  const result = [points[0]];
  for (let i = 1; i < maxPoints - 1; i++) {
    result.push(points[Math.round(i * step)]);
  }
  result.push(points[points.length - 1]);
  return result;
}

/**
 * Decode a polyline6 string to count the number of points.
 */
function countPolylinePoints(encoded: string): number {
  let count = 0;
  let index = 0;
  while (index < encoded.length) {
    // Skip latitude
    let byte: number;
    do {
      byte = encoded.charCodeAt(index++) - 63;
    } while (byte >= 0x20);
    // Skip longitude
    do {
      byte = encoded.charCodeAt(index++) - 63;
    } while (byte >= 0x20);
    count++;
  }
  return count;
}

/**
 * Calculate Haversine distance between two points in km.
 */
function haversineKm(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number
): number {
  const R = 6371.0;
  const dLat = ((lat2 - lat1) * Math.PI) / 180;
  const dLon = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos((lat1 * Math.PI) / 180) *
      Math.cos((lat2 * Math.PI) / 180) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

/**
 * OSRM region definitions. Each region has a bounding box and env var for its URL.
 * Regions are checked in order; first match wins.
 */
interface OsrmRegion {
  name: string;
  envVar: string;
  bbox: { minLat: number; maxLat: number; minLon: number; maxLon: number };
}

const OSRM_REGIONS: OsrmRegion[] = [
  {
    name: "mexico",
    envVar: "OSRM_MEXICO_BASE_URL",
    bbox: { minLat: 14.5, maxLat: 32.7, minLon: -118.5, maxLon: -86.7 },
  },
  {
    name: "quebec",
    envVar: "OSRM_BASE_URL",
    bbox: { minLat: 44.0, maxLat: 63.0, minLon: -80.0, maxLon: -57.0 },
  },
];

/**
 * Select the appropriate OSRM server URL based on the GPS coordinates.
 * Falls back to the default OSRM_BASE_URL if no region matches.
 */
export function selectOsrmUrl(points: GpsPoint[]): string | null {
  if (points.length === 0) return Deno.env.get("OSRM_BASE_URL") ?? null;

  // Use the first point's coordinates to determine region
  const lat = points[0].latitude;
  const lon = points[0].longitude;

  for (const region of OSRM_REGIONS) {
    if (
      lat >= region.bbox.minLat &&
      lat <= region.bbox.maxLat &&
      lon >= region.bbox.minLon &&
      lon <= region.bbox.maxLon
    ) {
      const url = Deno.env.get(region.envVar);
      if (url) return url;
    }
  }

  // Default fallback
  return Deno.env.get("OSRM_BASE_URL") ?? null;
}

/**
 * Match a trip's GPS points to the road network using OSRM.
 */
export async function matchTripToRoad(
  points: GpsPoint[],
  haversineDistanceKm: number,
  osrmBaseUrl: string
): Promise<MatchResult> {
  // Simplify trace if > 100 points
  const trace = simplifyTrace(points, 100);

  // Build OSRM coordinates string (lon,lat format!)
  const coordinates = trace
    .map((p) => `${p.longitude},${p.latitude}`)
    .join(";");

  // Build timestamps
  const timestamps = trace
    .map((p) => Math.floor(new Date(p.captured_at).getTime() / 1000))
    .join(";");

  // Build radiuses (GPS accuracy, clamped to 20-100m, default 30m)
  // Minimum 20m accounts for OSM road geometry offset from real-world GPS positions,
  // especially in rural areas where OSM data may be less precisely aligned
  const radiuses = trace
    .map((p) => {
      const acc = p.accuracy ?? 30;
      return Math.max(20, Math.min(100, acc));
    })
    .join(";");

  const url = `${osrmBaseUrl}/match/v1/driving/${coordinates}?timestamps=${timestamps}&radiuses=${radiuses}&geometries=polyline6&overview=full&gaps=ignore`;

  const osrmResponse = await fetch(url);

  if (!osrmResponse.ok) {
    return {
      success: false,
      match_status: "failed",
      route_geometry: null,
      road_distance_km: null,
      match_confidence: null,
      match_error: `OSRM returned HTTP ${osrmResponse.status}`,
      geometry_points: 0,
    };
  }

  const osrmData = await osrmResponse.json();

  if (osrmData.code !== "Ok" || !osrmData.matchings?.length) {
    return {
      success: false,
      match_status: "failed",
      route_geometry: null,
      road_distance_km: null,
      match_confidence: null,
      match_error: `OSRM error: ${osrmData.code ?? "no matchings"}`,
      geometry_points: 0,
    };
  }

  // Combine matchings (normally just one with gaps=ignore, but handle edge cases)
  let totalDistance = 0;
  let weightedConfidence = 0;
  const geometries: string[] = [];

  for (const matching of osrmData.matchings) {
    totalDistance += matching.distance; // meters
    weightedConfidence += matching.confidence * matching.distance;
    geometries.push(matching.geometry);
  }

  // Distance-weighted confidence (avoids tiny segments dragging down the score)
  const avgConfidence =
    totalDistance > 0
      ? weightedConfidence / totalDistance
      : osrmData.matchings[0].confidence;
  const roadDistanceKm = totalDistance / 1000;

  // Use the geometry from the longest matching segment (covers most of the route)
  let routeGeometry = geometries[0];
  if (geometries.length > 1) {
    let maxDist = 0;
    for (const matching of osrmData.matchings) {
      if (matching.distance > maxDist) {
        maxDist = matching.distance;
        routeGeometry = matching.geometry;
      }
    }
  }

  const geometryPoints = countPolylinePoints(routeGeometry);

  // Validate: matched points check (primary quality gate)
  const matchedCount = osrmData.tracepoints
    ? osrmData.tracepoints.filter((tp: unknown) => tp !== null).length
    : 0;
  const matchedPct = matchedCount / trace.length;
  if (matchedPct < 0.5) {
    return {
      success: false,
      match_status: "failed",
      route_geometry: null,
      road_distance_km: null,
      match_confidence: avgConfidence,
      match_error: `Only ${Math.round(matchedPct * 100)}% of GPS points matched to roads`,
      geometry_points: 0,
    };
  }

  // Validate: reject only if confidence is extremely low AND few points matched
  // OSRM confidence reflects alternative route count, not match quality.
  // In grid cities, many alternative routes exist → low confidence even for perfect matches.
  if (avgConfidence < 0.05 && matchedPct < 0.8) {
    return {
      success: false,
      match_status: "failed",
      route_geometry: null,
      road_distance_km: null,
      match_confidence: avgConfidence,
      match_error: `Match confidence too low: ${avgConfidence.toFixed(2)} with only ${Math.round(matchedPct * 100)}% points matched`,
      geometry_points: 0,
    };
  }

  // Validate: anomaly check (road distance > 3× haversine)
  if (haversineDistanceKm > 0 && roadDistanceKm > 3 * haversineDistanceKm) {
    return {
      success: false,
      match_status: "anomalous",
      route_geometry: routeGeometry,
      road_distance_km: roadDistanceKm,
      match_confidence: avgConfidence,
      match_error: `Road distance ${roadDistanceKm.toFixed(1)}km exceeds 3× haversine ${haversineDistanceKm.toFixed(1)}km`,
      geometry_points: geometryPoints,
    };
  }

  return {
    success: true,
    match_status: "matched",
    route_geometry: routeGeometry,
    road_distance_km: Math.round(roadDistanceKm * 1000) / 1000, // 3 decimal places
    match_confidence: Math.round(avgConfidence * 100) / 100, // 2 decimal places
    match_error: null,
    geometry_points: geometryPoints,
  };
}

/**
 * Create a Supabase client with service role key.
 */
export function createServiceClient(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
  );
}

/**
 * Fetch GPS points for a trip from the database.
 */
export async function fetchTripGpsPoints(
  supabase: SupabaseClient,
  tripId: string
): Promise<GpsPoint[]> {
  const { data, error } = await supabase
    .from("trip_gps_points")
    .select(
      `
      sequence_order,
      gps_points!inner (
        latitude,
        longitude,
        accuracy,
        captured_at
      )
    `
    )
    .eq("trip_id", tripId)
    .order("sequence_order", { ascending: true });

  if (error) throw new Error(`Failed to fetch GPS points: ${error.message}`);
  if (!data || data.length === 0) return [];

  return data.map((row: Record<string, unknown>) => {
    const gp = row.gps_points as Record<string, unknown>;
    return {
      latitude: gp.latitude as number,
      longitude: gp.longitude as number,
      accuracy: gp.accuracy as number | null,
      captured_at: gp.captured_at as string,
    };
  });
}

/**
 * Store match results in the database via the update_trip_match RPC.
 */
export async function storeMatchResult(
  supabase: SupabaseClient,
  tripId: string,
  result: MatchResult
): Promise<void> {
  const { error } = await supabase.rpc("update_trip_match", {
    p_trip_id: tripId,
    p_match_status: result.match_status,
    p_route_geometry: result.route_geometry,
    p_road_distance_km: result.road_distance_km,
    p_match_confidence: result.match_confidence,
    p_match_error: result.match_error,
  });

  if (error) throw new Error(`Failed to store match result: ${error.message}`);
}
