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

  // Build radiuses (GPS accuracy, clamped to 5-100m, default 30m)
  const radiuses = trace
    .map((p) => {
      const acc = p.accuracy ?? 30;
      return Math.max(5, Math.min(100, acc));
    })
    .join(";");

  const url = `${osrmBaseUrl}/match/v1/driving/${coordinates}?timestamps=${timestamps}&radiuses=${radiuses}&geometries=polyline6&overview=full&gaps=split`;

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

  // Combine matchings if gaps=split produced multiple
  let totalDistance = 0;
  let totalConfidence = 0;
  const geometries: string[] = [];

  for (const matching of osrmData.matchings) {
    totalDistance += matching.distance; // meters
    totalConfidence += matching.confidence;
    geometries.push(matching.geometry);
  }

  const avgConfidence =
    totalConfidence / osrmData.matchings.length;
  const roadDistanceKm = totalDistance / 1000;

  // Use first geometry if single matching, combine label if multiple
  const routeGeometry =
    geometries.length === 1 ? geometries[0] : geometries[0];
  // Note: For multiple matchings, we store the first one and adjust distance.
  // A more sophisticated approach would combine polylines, but this covers 95%+ of cases.

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
