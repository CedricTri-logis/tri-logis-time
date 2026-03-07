import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  routeTripDirect,
  selectOsrmUrlForCoords,
} from "../_shared/osrm-matcher.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { start_lat, start_lng, end_lat, end_lng } = await req.json();

    if (start_lat == null || start_lng == null || end_lat == null || end_lng == null) {
      return new Response(
        JSON.stringify({ success: false, error: "start_lat, start_lng, end_lat, end_lng are required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const osrmBaseUrl = selectOsrmUrlForCoords(start_lat, start_lng);
    if (!osrmBaseUrl) {
      return new Response(
        JSON.stringify({ success: false, error: "No OSRM server for region" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const result = await routeTripDirect(start_lat, start_lng, end_lat, end_lng, osrmBaseUrl);

    return new Response(
      JSON.stringify({
        success: result.success,
        route_geometry: result.route_geometry,
        road_distance_km: result.road_distance_km,
        match_confidence: result.match_confidence,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("route-between-points error:", error);
    return new Response(
      JSON.stringify({ success: false, error: error instanceof Error ? error.message : "Internal error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
