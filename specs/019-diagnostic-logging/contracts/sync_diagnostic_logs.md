# API Contract: sync_diagnostic_logs RPC

**Type**: Supabase RPC (PostgreSQL function)
**Migration**: 036

## Request

**RPC Name**: `sync_diagnostic_logs`

**Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `p_events` | JSONB | Yes | Array of diagnostic event objects |

**Event Object Schema**:
```json
{
  "id": "uuid-v4-string",
  "employee_id": "uuid-v4-string",
  "shift_id": "uuid-v4-string | null",
  "device_id": "string",
  "event_category": "gps | shift | sync | auth | permission | lifecycle | thermal | error | network",
  "severity": "info | warn | error | critical",
  "message": "string",
  "metadata": { "key": "value" },
  "app_version": "1.0.0+52",
  "platform": "ios | android",
  "os_version": "string | null",
  "created_at": "2026-02-24T12:00:00.000Z"
}
```

**Notes**:
- `debug` severity events are NEVER sent (filtered client-side)
- Max 200 events per call
- `id` is client-generated UUID used for deduplication

## Response

**Success**:
```json
{
  "status": "success",
  "inserted": 195,
  "duplicates": 5,
  "errors": 0
}
```

**Error**:
```json
{
  "status": "error",
  "message": "Invalid event format",
  "inserted": 0,
  "duplicates": 0,
  "errors": 200
}
```

## Server-Side Logic

```sql
CREATE OR REPLACE FUNCTION sync_diagnostic_logs(p_events JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_event JSONB;
  v_inserted INT := 0;
  v_duplicates INT := 0;
  v_errors INT := 0;
  v_caller_id UUID := auth.uid();
BEGIN
  FOR v_event IN SELECT * FROM jsonb_array_elements(p_events)
  LOOP
    BEGIN
      -- Verify caller owns the event
      IF (v_event->>'employee_id')::UUID != v_caller_id THEN
        v_errors := v_errors + 1;
        CONTINUE;
      END IF;

      INSERT INTO diagnostic_logs (
        id, employee_id, shift_id, device_id,
        event_category, severity, message, metadata,
        app_version, platform, os_version, created_at
      ) VALUES (
        (v_event->>'id')::UUID,
        (v_event->>'employee_id')::UUID,
        NULLIF(v_event->>'shift_id', '')::UUID,
        v_event->>'device_id',
        v_event->>'event_category',
        v_event->>'severity',
        v_event->>'message',
        (v_event->'metadata')::JSONB,
        v_event->>'app_version',
        v_event->>'platform',
        v_event->>'os_version',
        (v_event->>'created_at')::TIMESTAMPTZ
      );
      v_inserted := v_inserted + 1;
    EXCEPTION
      WHEN unique_violation THEN
        v_duplicates := v_duplicates + 1;
      WHEN OTHERS THEN
        v_errors := v_errors + 1;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'status', 'success',
    'inserted', v_inserted,
    'duplicates', v_duplicates,
    'errors', v_errors
  );
END;
$$;
```

## Deduplication

- Primary key `id` (UUID) is client-generated
- Server catches `unique_violation` and counts as duplicate (not error)
- Client marks events as synced only after successful response
- Re-sync of already-synced events is harmless (counted as duplicate)

## Rate Limiting

- No explicit rate limit (piggybacks on existing sync cycle ~every 30-60s when online)
- Max 200 events per call prevents oversized payloads
- Multiple batches processed sequentially if >200 pending events

## Security

- `SECURITY DEFINER` to bypass RLS for batch insert
- Validates `employee_id` matches `auth.uid()` per event
- Events from other employees are rejected (counted as error)
