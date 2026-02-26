import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  createServiceClient,
  fetchTripGpsPoints,
  matchTripToRoad,
  storeMatchResult,
  type MatchResult,
} from "../_shared/osrm-matcher.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const MAX_TRIPS = 500;
const DEFAULT_LIMIT = 100;
const OSRM_DELAY_MS = 200;

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const startTime = Date.now();

  try {
    const body = await req.json();
    const {
      trip_ids,
      shift_id,
      reprocess_failed,
      reprocess_all,
      limit,
    } = body as {
      trip_ids?: string[];
      shift_id?: string;
      reprocess_failed?: boolean;
      reprocess_all?: boolean;
      limit?: number;
    };

    if (!trip_ids && !shift_id && !reprocess_failed && !reprocess_all) {
      return new Response(
        JSON.stringify({
          success: false,
          error:
            "At least one of trip_ids, shift_id, reprocess_failed, or reprocess_all must be provided",
          code: "INVALID_REQUEST",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const effectiveLimit = Math.min(limit ?? DEFAULT_LIMIT, MAX_TRIPS);
    const supabase = createServiceClient();
    const osrmBaseUrl = Deno.env.get("OSRM_BASE_URL");

    if (!osrmBaseUrl) {
      return new Response(
        JSON.stringify({
          success: false,
          error: "OSRM_BASE_URL not configured",
          code: "OSRM_UNAVAILABLE",
        }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // Resolve trip IDs based on request type
    let tripIds: string[] = [];

    if (trip_ids && trip_ids.length > 0) {
      tripIds = trip_ids.slice(0, effectiveLimit);
    } else if (shift_id) {
      const { data, error } = await supabase
        .from("trips")
        .select("id")
        .eq("shift_id", shift_id)
        .neq("match_status", "matched")
        .order("created_at", { ascending: true })
        .limit(effectiveLimit);

      if (error) throw new Error(`Failed to fetch trips: ${error.message}`);
      tripIds = (data ?? []).map((t: { id: string }) => t.id);
    } else if (reprocess_all) {
      const { data, error } = await supabase
        .from("trips")
        .select("id")
        .order("created_at", { ascending: false })
        .limit(effectiveLimit);

      if (error) throw new Error(`Failed to fetch trips: ${error.message}`);
      tripIds = (data ?? []).map((t: { id: string }) => t.id);
    } else if (reprocess_failed) {
      const { data, error } = await supabase
        .from("trips")
        .select("id")
        .in("match_status", ["pending", "failed"])
        .lt("match_attempts", 3)
        .order("created_at", { ascending: false })
        .limit(effectiveLimit);

      if (error) throw new Error(`Failed to fetch trips: ${error.message}`);
      tripIds = (data ?? []).map((t: { id: string }) => t.id);
    }

    if (tripIds.length === 0) {
      return new Response(
        JSON.stringify({
          success: true,
          summary: {
            total_requested: 0,
            processed: 0,
            matched: 0,
            failed: 0,
            anomalous: 0,
            skipped: 0,
            duration_seconds: 0,
          },
          results: [],
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    // Process trips sequentially
    const results: Array<{
      trip_id: string;
      status: "matched" | "failed" | "anomalous" | "skipped";
      road_distance_km: number | null;
      match_confidence: number | null;
      error: string | null;
    }> = [];

    let matched = 0;
    let failed = 0;
    let anomalous = 0;
    let skipped = 0;
    let processed = 0;

    for (let i = 0; i < tripIds.length; i++) {
      const tripId = tripIds[i];

      try {
        // Fetch trip details
        const { data: trip, error: tripError } = await supabase
          .from("trips")
          .select("id, distance_km, match_attempts, match_status")
          .eq("id", tripId)
          .single();

        if (tripError || !trip) {
          results.push({
            trip_id: tripId,
            status: "failed",
            road_distance_km: null,
            match_confidence: null,
            error: "Trip not found",
          });
          failed++;
          continue;
        }

        // Skip already matched unless reprocess_all
        if (trip.match_status === "matched" && !reprocess_all) {
          results.push({
            trip_id: tripId,
            status: "skipped",
            road_distance_km: null,
            match_confidence: null,
            error: null,
          });
          skipped++;
          continue;
        }

        // Skip if max attempts reached (unless reprocessing)
        if (trip.match_attempts >= 3 && !reprocess_all && !reprocess_failed) {
          results.push({
            trip_id: tripId,
            status: "skipped",
            road_distance_km: null,
            match_confidence: null,
            error: "Max attempts reached",
          });
          skipped++;
          continue;
        }

        // Reset match_attempts for reprocessed trips
        if (reprocess_all || reprocess_failed) {
          await supabase
            .from("trips")
            .update({ match_status: "processing", match_attempts: 0 })
            .eq("id", tripId);
        } else {
          await supabase
            .from("trips")
            .update({ match_status: "processing" })
            .eq("id", tripId);
        }

        // Fetch GPS points
        const gpsPoints = await fetchTripGpsPoints(supabase, tripId);

        if (gpsPoints.length < 3) {
          const result: MatchResult = {
            success: false,
            match_status: "failed",
            route_geometry: null,
            road_distance_km: null,
            match_confidence: null,
            match_error: `Insufficient GPS points: ${gpsPoints.length}`,
            geometry_points: 0,
          };
          await storeMatchResult(supabase, tripId, result);
          results.push({
            trip_id: tripId,
            status: "failed",
            road_distance_km: null,
            match_confidence: null,
            error: result.match_error,
          });
          failed++;
          continue;
        }

        // Match to road network
        const matchResult = await matchTripToRoad(
          gpsPoints,
          trip.distance_km as number,
          osrmBaseUrl
        );

        await storeMatchResult(supabase, tripId, matchResult);
        processed++;

        results.push({
          trip_id: tripId,
          status: matchResult.match_status,
          road_distance_km: matchResult.road_distance_km,
          match_confidence: matchResult.match_confidence,
          error: matchResult.match_error,
        });

        if (matchResult.match_status === "matched") matched++;
        else if (matchResult.match_status === "anomalous") anomalous++;
        else failed++;

        // Delay between OSRM calls
        if (i < tripIds.length - 1) {
          await delay(OSRM_DELAY_MS);
        }
      } catch (err) {
        results.push({
          trip_id: tripId,
          status: "failed",
          road_distance_km: null,
          match_confidence: null,
          error: err instanceof Error ? err.message : "Unknown error",
        });
        failed++;
      }
    }

    const durationSeconds =
      Math.round(((Date.now() - startTime) / 1000) * 10) / 10;

    return new Response(
      JSON.stringify({
        success: true,
        summary: {
          total_requested: tripIds.length,
          processed,
          matched,
          failed,
          anomalous,
          skipped,
          duration_seconds: durationSeconds,
        },
        results,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (error) {
    console.error("batch-match-trips error:", error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : "Internal error",
        code: "INTERNAL_ERROR",
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
