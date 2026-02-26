import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  createServiceClient,
  fetchTripGpsPoints,
  matchTripToRoad,
  storeMatchResult,
} from "../_shared/osrm-matcher.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { trip_id } = await req.json();

    if (!trip_id) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "trip_id is required",
          code: "INVALID_REQUEST",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = createServiceClient();
    const osrmBaseUrl = Deno.env.get("OSRM_BASE_URL");

    if (!osrmBaseUrl) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "OSRM_BASE_URL not configured",
          code: "OSRM_UNAVAILABLE",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Fetch trip details
    const { data: trip, error: tripError } = await supabase
      .from("trips")
      .select("id, distance_km, match_attempts, match_status, transport_mode")
      .eq("id", trip_id)
      .single();

    if (tripError || !trip) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "Trip not found",
          code: "TRIP_NOT_FOUND",
        }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Skip walking trips — OSRM only has driving profiles
    if (trip.transport_mode === "walking") {
      return new Response(
        JSON.stringify({
          success: true,
          trip_id,
          match_status: "skipped",
          reason: "Walking trips do not require road matching",
        }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Check max attempts
    if (trip.match_attempts >= 3) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "Maximum matching attempts reached",
          code: "MAX_ATTEMPTS_REACHED",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Set status to processing
    await supabase
      .from("trips")
      .update({ match_status: "processing" })
      .eq("id", trip_id);

    // Fetch GPS points
    const gpsPoints = await fetchTripGpsPoints(supabase, trip_id);

    if (gpsPoints.length < 3) {
      const result = {
        success: false,
        match_status: "failed" as const,
        route_geometry: null,
        road_distance_km: null,
        match_confidence: null,
        match_error: `Insufficient GPS points: ${gpsPoints.length} (minimum 3)`,
        geometry_points: 0,
      };
      await storeMatchResult(supabase, trip_id, result);

      return new Response(
        JSON.stringify({
          success: false,
          error: result.match_error,
          code: "INSUFFICIENT_POINTS",
        }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Match to road network
    const haversineDistanceKm = trip.distance_km as number;
    const matchResult = await matchTripToRoad(
      gpsPoints,
      haversineDistanceKm,
      osrmBaseUrl
    );

    // Store results
    await storeMatchResult(supabase, trip_id, matchResult);

    // Calculate distance change percentage
    const distanceChangePct =
      matchResult.road_distance_km && haversineDistanceKm > 0
        ? Math.round(
            ((matchResult.road_distance_km - haversineDistanceKm) /
              haversineDistanceKm) *
              100 *
              10
          ) / 10
        : null;

    return new Response(
      JSON.stringify({
        success: matchResult.success,
        trip_id,
        match_status: matchResult.match_status,
        road_distance_km: matchResult.road_distance_km,
        match_confidence: matchResult.match_confidence,
        geometry_points: matchResult.geometry_points,
        haversine_distance_km: haversineDistanceKm,
        distance_change_pct: distanceChangePct,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("match-trip-route error:", error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : "Internal error",
        code: "INTERNAL_ERROR",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
