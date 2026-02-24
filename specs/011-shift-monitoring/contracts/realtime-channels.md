# Realtime Channels: Shift Monitoring

**Feature Branch**: `011-shift-monitoring`
**Created**: 2026-01-15

## Overview

Supabase Realtime channel specifications for push-based updates. Uses PostgreSQL Changes to subscribe to table modifications.

---

## shifts-monitoring

Subscribes to shift status changes for supervised employees.

### Channel Configuration

```typescript
const channel = supabase
  .channel('shifts-monitoring')
  .on(
    'postgres_changes',
    {
      event: '*',          // INSERT, UPDATE, DELETE
      schema: 'public',
      table: 'shifts'
    },
    handleShiftChange
  )
  .subscribe()
```

### Events

| Event | Trigger | Payload |
|-------|---------|---------|
| INSERT | Employee clocks in | New shift record |
| UPDATE | Employee clocks out (status → completed) | Old + new shift record |

### Payload Structure

```typescript
interface ShiftRealtimePayload {
  commit_timestamp: string
  eventType: 'INSERT' | 'UPDATE' | 'DELETE'
  new: {
    id: string
    employee_id: string
    status: 'active' | 'completed'
    clocked_in_at: string
    clocked_out_at: string | null
    clock_in_location: { latitude: number; longitude: number } | null
    clock_in_accuracy: number | null
    clock_out_location: { latitude: number; longitude: number } | null
    clock_out_accuracy: number | null
  } | null
  old: {
    id: string
    employee_id: string
    status: 'active' | 'completed'
  } | null
  errors: string[] | null
}
```

### Client-Side Filtering

Since RLS applies at subscription time, client must filter to supervised employees:

```typescript
function handleShiftChange(payload: ShiftRealtimePayload) {
  const employeeId = payload.new?.employee_id || payload.old?.employee_id

  // Only process if employee is in supervised list
  if (!supervisedEmployeeIds.includes(employeeId)) {
    return
  }

  switch (payload.eventType) {
    case 'INSERT':
      // Employee clocked in - add to active list
      addActiveShift(payload.new)
      break
    case 'UPDATE':
      if (payload.new?.status === 'completed') {
        // Employee clocked out - remove from active list
        removeActiveShift(payload.old.id)
      }
      break
  }
}
```

### RLS Considerations

- Supabase Realtime respects RLS policies
- Users only receive events for rows they can SELECT
- Admin/super_admin receive all shift changes
- Managers receive changes for supervised employees only

---

## gps-monitoring

Subscribes to new GPS points for active shifts.

### Channel Configuration

```typescript
const channel = supabase
  .channel('gps-monitoring')
  .on(
    'postgres_changes',
    {
      event: 'INSERT',     // GPS points are immutable, only INSERT
      schema: 'public',
      table: 'gps_points'
    },
    handleGpsPoint
  )
  .subscribe()
```

### Events

| Event | Trigger | Payload |
|-------|---------|---------|
| INSERT | New GPS point captured | GPS point record |

### Payload Structure

```typescript
interface GpsPointRealtimePayload {
  commit_timestamp: string
  eventType: 'INSERT'
  new: {
    id: string
    client_id: string
    shift_id: string
    employee_id: string
    latitude: number
    longitude: number
    accuracy: number
    captured_at: string
    received_at: string
    device_id: string | null
  }
  old: null
  errors: string[] | null
}
```

### Client-Side Processing

```typescript
function handleGpsPoint(payload: GpsPointRealtimePayload) {
  const { employee_id, shift_id, latitude, longitude, accuracy, captured_at } = payload.new

  // Only process if employee is in supervised list
  if (!supervisedEmployeeIds.includes(employee_id)) {
    return
  }

  // Update employee's current location
  updateEmployeeLocation(employee_id, {
    latitude,
    longitude,
    accuracy,
    capturedAt: new Date(captured_at)
  })

  // If viewing shift detail, append to trail
  if (currentViewShiftId === shift_id) {
    appendToGpsTrail({
      id: payload.new.id,
      latitude,
      longitude,
      accuracy,
      capturedAt: new Date(captured_at)
    })
  }
}
```

---

## Connection Management

### Hook Pattern

```typescript
function useRealtimeMonitoring(supervisedEmployeeIds: string[]) {
  const [connectionStatus, setConnectionStatus] = useState<
    'connecting' | 'connected' | 'disconnected'
  >('connecting')

  useEffect(() => {
    const shiftsChannel = supabase
      .channel('shifts-monitoring')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'shifts' }, handleShiftChange)
      .subscribe((status) => {
        setConnectionStatus(status === 'SUBSCRIBED' ? 'connected' : 'connecting')
      })

    const gpsChannel = supabase
      .channel('gps-monitoring')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'gps_points' }, handleGpsPoint)
      .subscribe()

    return () => {
      supabase.removeChannel(shiftsChannel)
      supabase.removeChannel(gpsChannel)
    }
  }, [supervisedEmployeeIds])

  return { connectionStatus }
}
```

### Reconnection Handling

Supabase client handles reconnection automatically. UI should:
1. Show connection status indicator
2. Display "Reconnecting..." when disconnected
3. Show last update timestamp when offline
4. Refetch data on reconnection for consistency

```typescript
useEffect(() => {
  const handleOnline = () => {
    // Refetch to ensure data consistency after reconnection
    refetchTeamData()
  }

  window.addEventListener('online', handleOnline)
  return () => window.removeEventListener('online', handleOnline)
}, [])
```

---

## Performance Considerations

### Batching Updates

For high-frequency GPS updates, consider batching UI updates:

```typescript
const pendingUpdates = useRef<Map<string, LocationUpdate>>(new Map())
const flushInterval = useRef<NodeJS.Timeout>()

function handleGpsPoint(payload: GpsPointRealtimePayload) {
  // Batch updates per employee (keep latest only)
  pendingUpdates.current.set(payload.new.employee_id, {
    latitude: payload.new.latitude,
    longitude: payload.new.longitude,
    accuracy: payload.new.accuracy,
    capturedAt: new Date(payload.new.captured_at)
  })
}

useEffect(() => {
  flushInterval.current = setInterval(() => {
    if (pendingUpdates.current.size > 0) {
      // Apply all pending updates at once
      batchUpdateLocations(pendingUpdates.current)
      pendingUpdates.current.clear()
    }
  }, 1000) // Flush every second

  return () => clearInterval(flushInterval.current)
}, [])
```

### Subscription Scope

- Subscribe to tables, not specific rows (RLS handles filtering)
- Client-side filtering for supervised employees only
- Consider multiple channels for separation of concerns

---

## Error Handling

```typescript
channel.subscribe((status, err) => {
  if (status === 'CHANNEL_ERROR') {
    console.error('Realtime subscription error:', err)
    // Show user-friendly error toast
    toast.error('Real-time updates unavailable. Data may be stale.')
  }

  if (status === 'TIMED_OUT') {
    console.warn('Realtime subscription timed out, retrying...')
  }
})
```
