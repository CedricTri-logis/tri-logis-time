# Dashboard Hook Contracts: Cleaning Session Tracking

## useCleaningSessions(filters) → CleaningSessionsResult

Fetch paginated cleaning sessions for the dashboard.

**Parameters**:
```typescript
interface CleaningSessionFilters {
  buildingId?: string
  employeeId?: string
  dateFrom: Date
  dateTo: Date
  status?: CleaningSessionStatus
  limit: number     // default 50
  offset: number    // default 0
}
```

**Returns**:
```typescript
interface CleaningSessionsResult {
  sessions: CleaningSession[]
  summary: CleaningSummary
  totalCount: number
  isLoading: boolean
  error: Error | null
  refetch: () => void
}

interface CleaningSummary {
  totalSessions: number
  completed: number
  inProgress: number
  autoClosed: number
  avgDurationMinutes: number
  flaggedCount: number
}
```

**Implementation**: Calls RPC `get_cleaning_dashboard`

---

## useCleaningStatsByBuilding(dateFrom, dateTo) → BuildingStatsResult

Per-building cleaning statistics.

**Returns**:
```typescript
interface BuildingStats {
  buildingId: string
  buildingName: string
  totalStudios: number
  cleanedToday: number
  inProgress: number
  notStarted: number
  avgDurationMinutes: number
}

interface BuildingStatsResult {
  stats: BuildingStats[]
  isLoading: boolean
  error: Error | null
}
```

**Implementation**: Calls RPC `get_cleaning_stats_by_building`

---

## useEmployeeCleaningStats(employeeId?, dateFrom, dateTo) → EmployeeStatsResult

Per-employee cleaning performance.

**Returns**:
```typescript
interface EmployeeCleaningStats {
  employeeName: string
  totalSessions: number
  avgDurationMinutes: number
  sessionsByBuilding: { buildingName: string; count: number; avgDuration: number }[]
  flaggedSessions: number
}
```

**Implementation**: Calls RPC `get_employee_cleaning_stats`

---

## useCleaningSessionMutations() → Mutations

Mutation hooks for supervisor actions.

**Returns**:
```typescript
interface CleaningMutations {
  closeSession: (sessionId: string) => Promise<void>
  isClosing: boolean
}
```

**Implementation**: Calls RPC `manually_close_session`

---

## Types (dashboard/src/types/cleaning.ts)

```typescript
type CleaningSessionStatus = 'in_progress' | 'completed' | 'auto_closed' | 'manually_closed'
type StudioType = 'unit' | 'common_area' | 'conciergerie'

interface CleaningSessionRow {
  id: string
  employee_id: string
  employee_name: string
  studio_id: string
  studio_number: string
  building_name: string
  studio_type: StudioType
  shift_id: string
  status: CleaningSessionStatus
  started_at: string
  completed_at: string | null
  duration_minutes: number | null
  is_flagged: boolean
  flag_reason: string | null
}

interface CleaningSession {
  id: string
  employeeId: string
  employeeName: string
  studioId: string
  studioNumber: string
  buildingName: string
  studioType: StudioType
  shiftId: string
  status: CleaningSessionStatus
  startedAt: Date
  completedAt: Date | null
  durationMinutes: number | null
  isFlagged: boolean
  flagReason: string | null
}
```

---

## Validation Schemas (dashboard/src/lib/validations/cleaning.ts)

```typescript
const cleaningFiltersSchema = z.object({
  buildingId: z.string().uuid().optional(),
  employeeId: z.string().uuid().optional(),
  dateFrom: z.date(),
  dateTo: z.date(),
  status: z.enum(['in_progress', 'completed', 'auto_closed', 'manually_closed']).optional(),
})

const manualCloseSchema = z.object({
  sessionId: z.string().uuid(),
  reason: z.string().max(500).optional(),
})
```
