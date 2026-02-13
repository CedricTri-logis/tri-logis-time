import { NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';
import fs from 'fs';
import path from 'path';

// Read seed data at runtime from the specs folder
function getSeedData() {
  const seedPath = path.join(process.cwd(), '..', 'specs', '014-seed-locations.json');
  const rawData = fs.readFileSync(seedPath, 'utf-8');
  return JSON.parse(rawData) as Array<{
    name: string;
    location_type: string;
    latitude: number;
    longitude: number;
    radius_meters: number;
    address?: string;
    notes?: string;
    is_active?: boolean;
  }>;
}

/**
 * API route to seed locations from the sample data file.
 * This is meant to be called manually for development/testing purposes.
 *
 * POST /api/seed-locations
 *
 * Query params:
 * - force=true: Seed even if locations already exist
 */
export async function POST(request: Request) {
  try {
    // Get Supabase credentials from environment
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const supabaseServiceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

    if (!supabaseUrl || !supabaseServiceKey) {
      return NextResponse.json(
        { error: 'Missing Supabase configuration. Set SUPABASE_SERVICE_ROLE_KEY.' },
        { status: 500 }
      );
    }

    // Create admin client with service role key
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Check query params
    const { searchParams } = new URL(request.url);
    const force = searchParams.get('force') === 'true';

    // Check if locations already exist
    const { count, error: countError } = await supabase
      .from('locations')
      .select('*', { count: 'exact', head: true });

    if (countError) {
      return NextResponse.json(
        { error: `Failed to check existing locations: ${countError.message}` },
        { status: 500 }
      );
    }

    if (count && count > 0 && !force) {
      return NextResponse.json({
        success: false,
        message: `${count} locations already exist. Use ?force=true to seed anyway.`,
        existingCount: count,
      });
    }

    // Get seed data
    const seedData = getSeedData();

    // Transform seed data to match RPC input format
    const locationsToInsert = seedData.map((loc) => ({
      name: loc.name,
      location_type: loc.location_type as 'office' | 'building' | 'vendor' | 'home' | 'other',
      latitude: loc.latitude,
      longitude: loc.longitude,
      radius_meters: loc.radius_meters,
      address: loc.address || null,
      notes: loc.notes || null,
      is_active: loc.is_active !== false,
    }));

    // Call the bulk_insert_locations RPC
    const { data, error } = await supabase.rpc('bulk_insert_locations', {
      p_locations: locationsToInsert,
    });

    if (error) {
      return NextResponse.json(
        { error: `Failed to insert locations: ${error.message}` },
        { status: 500 }
      );
    }

    // Count results
    const results = data as Array<{ id: string | null; name: string; success: boolean; error_message: string | null }>;
    const successCount = results.filter((r) => r.success).length;
    const failedCount = results.filter((r) => !r.success).length;
    const failures = results.filter((r) => !r.success);

    return NextResponse.json({
      success: true,
      message: `Seeded ${successCount} locations successfully.`,
      totalCount: locationsToInsert.length,
      successCount,
      failedCount,
      failures: failures.length > 0 ? failures : undefined,
    });
  } catch (error) {
    console.error('Seed locations error:', error);
    return NextResponse.json(
      { error: error instanceof Error ? error.message : 'Unknown error' },
      { status: 500 }
    );
  }
}

/**
 * GET endpoint to check seed status
 */
export async function GET() {
  try {
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
    const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

    if (!supabaseUrl || !supabaseAnonKey) {
      return NextResponse.json(
        { error: 'Missing Supabase configuration' },
        { status: 500 }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseAnonKey);

    const { count, error } = await supabase
      .from('locations')
      .select('*', { count: 'exact', head: true });

    if (error) {
      return NextResponse.json(
        { error: `Failed to count locations: ${error.message}` },
        { status: 500 }
      );
    }

    const seedData = getSeedData();
    return NextResponse.json({
      existingCount: count || 0,
      seedDataCount: seedData.length,
      needsSeeding: (count || 0) < seedData.length,
    });
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : 'Unknown error' },
      { status: 500 }
    );
  }
}
