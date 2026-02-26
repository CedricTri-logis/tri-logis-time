# Contract: batch-match-trips Edge Function

**Type**: Supabase Edge Function (Deno)
**Method**: POST
**Auth**: Authenticated user with manager role (via JWT)

## Request

```typescript
interface BatchMatchTripsRequest {
  // Option 1: Specific trip IDs
  trip_ids?: string[];

  // Option 2: All unmatched trips for a shift
  shift_id?: string;

  // Option 3: Re-process all failed/pending trips (admin only)
  reprocess_failed?: boolean;

  // Option 4: Re-process ALL trips (admin only, overrides existing matches)
  reprocess_all?: boolean;

  // Optional: limit number of trips to process (default: 100)
  limit?: number;
}
```

At least one of `trip_ids`, `shift_id`, `reprocess_failed`, or `reprocess_all` must be provided.

## Response

### Success (200)
```typescript
interface BatchMatchTripsResponse {
  success: true;
  summary: {
    total_requested: number;
    processed: number;
    matched: number;
    failed: number;
    anomalous: number;
    skipped: number;          // Already matched (unless reprocess_all)
    duration_seconds: number;
  };
  results: Array<{
    trip_id: string;
    status: 'matched' | 'failed' | 'anomalous' | 'skipped';
    road_distance_km: number | null;
    match_confidence: number | null;
    error: string | null;
  }>;
}
```

### Error (4xx)
```typescript
interface BatchMatchTripsError {
  success: false;
  error: string;
  code: 'UNAUTHORIZED' | 'INVALID_REQUEST' | 'TOO_MANY_TRIPS' | 'INTERNAL_ERROR';
}
```

## Processing Logic

### Step 1: Resolve Trip IDs
```sql
-- Option 1: Use provided trip_ids directly
-- Option 2: Get trips for shift
SELECT id FROM trips WHERE shift_id = :shift_id AND match_status != 'matched';
-- Option 3: Get all failed/pending
SELECT id FROM trips WHERE match_status IN ('pending', 'failed') AND match_attempts < 3 ORDER BY created_at DESC LIMIT :limit;
-- Option 4: Get all trips
SELECT id FROM trips ORDER BY created_at DESC LIMIT :limit;
```

### Step 2: Process Sequentially
- Process each trip by invoking the same logic as `match-trip-route`
- Add 200ms delay between OSRM calls to avoid overwhelming the server
- Skip trips that are already `matched` (unless `reprocess_all = true`)
- Reset `match_attempts` to 0 for reprocessed trips

### Step 3: Return Summary
Aggregate results and return structured summary.

## Limits

| Parameter | Default | Maximum | Description |
|-----------|---------|---------|-------------|
| `limit` | 100 | 500 | Max trips per batch request |
| Processing time | - | 10 min | Edge Function timeout |
| OSRM delay | 200ms | - | Delay between sequential OSRM calls |

## Authorization

- `reprocess_failed` and `reprocess_all`: Requires manager role
- `trip_ids` and `shift_id`: Requires access to the trips (employee or manager)

## Performance Estimate

At 200ms delay + ~50ms OSRM processing:
- 100 trips ≈ 25 seconds
- 500 trips ≈ 125 seconds (~2 minutes)
- Well within SC-007 requirement (100 trips in <10 minutes)
