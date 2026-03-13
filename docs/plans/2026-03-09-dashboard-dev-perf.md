# Dashboard Dev Performance Optimization Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce Next.js dev-mode compile/recompile time by splitting the 2078-line mega-component, eliminating the blocking `getUser()` network call from middleware, and removing `output: 'standalone'` in dev.

**Architecture:** Three independent optimizations: (1) split `day-approval-detail.tsx` into ~6 focused files so webpack only recompiles the changed module, (2) replace middleware's synchronous Supabase `getUser()` with fast JWT-based `getSession()` and defer server-side verification to route handlers, (3) conditionally disable `output: 'standalone'` in dev mode.

**Tech Stack:** Next.js 16.1, React 19, Supabase SSR, TypeScript

---

## Task 1: Split day-approval-detail.tsx — Extract utility functions & constants

**Files:**
- Create: `dashboard/src/components/approvals/approval-utils.ts`
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Create `approval-utils.ts` with the extracted helpers**

Move these out of the main file into a pure utility module (no React):

```ts
// approval-utils.ts
import { CheckCircle2, XCircle, AlertTriangle } from 'lucide-react';
import type { ApprovalAutoStatus, ProjectSession } from '@/types/mileage';

// --- Project session overlap helpers ---

export interface ProjectSlice {
  type: 'session' | 'gap';
  session?: ProjectSession;
  started_at: string;
  ended_at: string;
  duration_minutes: number;
}

// Copy getProjectSlices() here (lines 62-140)
export function getProjectSlices(...) { ... }

// Copy MergedGroup interface + DisplayItem type + mergeSameLocationGaps() (lines 184-283)
export interface MergedGroup { ... }
export type DisplayItem = ...;
export function mergeSameLocationGaps(...) { ... }

// Copy formatHours + formatDate (lines 292-306)
export function formatHours(minutes: number): string { ... }
export function formatDate(dateStr: string): string { ... }

// Copy STATUS_BADGE (lines 308-324)
export const STATUS_BADGE: Record<ApprovalAutoStatus, { className: string; icon: typeof CheckCircle2; label: string }> = { ... };
```

**Step 2: Update imports in `day-approval-detail.tsx`**

Replace the inline definitions with:
```ts
import {
  getProjectSlices, mergeSameLocationGaps, formatHours, formatDate,
  STATUS_BADGE, type ProjectSlice, type MergedGroup, type DisplayItem,
} from './approval-utils';
```

Delete lines 48-324 from the main file (the moved code).

**Step 3: Verify the dev server still compiles**

Run: `cd dashboard && npm run dev`
Expected: No TypeScript errors, page loads normally.

**Step 4: Commit**

```bash
git add dashboard/src/components/approvals/approval-utils.ts dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "refactor: extract approval-utils from day-approval-detail (perf)"
```

---

## Task 2: Split day-approval-detail.tsx — Extract TripExpandDetail

**Files:**
- Create: `dashboard/src/components/approvals/trip-expand-detail.tsx`
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Create `trip-expand-detail.tsx`**

Move the `TripExpandDetail` component (lines ~365-486) into its own file. It fetches trip GPS points and renders `GoogleTripRouteMap`. Copy only the imports it needs.

```tsx
'use client';

import { useState, useEffect } from 'react';
import { Loader2, AlertTriangle } from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';
import { GoogleTripRouteMap } from '@/components/trips/google-trip-route-map';
import { detectTripStops, detectGpsClusters } from '@/lib/utils/detect-trip-stops';
import { formatDuration, formatDistance } from '@/lib/utils/activity-display';
import type { ApprovalActivity, TripGpsPoint } from '@/types/mileage';

export function TripExpandDetail({ activity }: { activity: ApprovalActivity }) {
  // ... (move the component body verbatim)
}
```

**Step 2: Update `day-approval-detail.tsx`**

Replace the inline `TripExpandDetail` with:
```ts
import { TripExpandDetail } from './trip-expand-detail';
```

Delete the old function from the file.

**Step 3: Verify dev server compiles**

Run: `cd dashboard && npm run dev`

**Step 4: Commit**

```bash
git add dashboard/src/components/approvals/trip-expand-detail.tsx dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "refactor: extract TripExpandDetail component (perf)"
```

---

## Task 3: Split day-approval-detail.tsx — Extract GapExpandDetail & StopExpandDetail

**Files:**
- Create: `dashboard/src/components/approvals/gap-expand-detail.tsx`
- Create: `dashboard/src/components/approvals/stop-expand-detail.tsx`
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Create `gap-expand-detail.tsx`**

Move `GapExpandDetail` (lines ~501-620). It renders `StationaryClustersMap`.

```tsx
'use client';

import { useState, useEffect } from 'react';
import { Loader2 } from 'lucide-react';
import { supabaseClient } from '@/lib/supabase/client';
import { StationaryClustersMap } from '@/components/mileage/stationary-clusters-map';
import type { StationaryCluster } from '@/components/mileage/stationary-clusters-map';
import { formatDuration } from '@/lib/utils/activity-display';
import type { ApprovalActivity } from '@/types/mileage';

export function GapExpandDetail({ activity }: { activity: ApprovalActivity }) {
  // ... move body
}
```

**Step 2: Create `stop-expand-detail.tsx`**

Move `StopExpandDetail` (lines ~621-685). It renders project slices.

```tsx
'use client';

import { MapPin } from 'lucide-react';
import { LOCATION_TYPE_ICON_MAP } from '@/lib/constants/location-icons';
import { LOCATION_TYPE_LABELS } from '@/lib/validations/location';
import { formatTime } from '@/lib/utils/activity-display';
import { getProjectSlices, type ProjectSlice } from './approval-utils';
import type { ApprovalActivity, ProjectSession } from '@/types/mileage';
import type { LocationType } from '@/types/location';

export function StopExpandDetail({ activity, projectSessions }: {
  activity: ApprovalActivity;
  projectSessions?: ProjectSession[];
}) {
  // ... move body (note: it may need projectSessions passed as prop)
}
```

**Step 3: Update imports in `day-approval-detail.tsx`**

```ts
import { GapExpandDetail } from './gap-expand-detail';
import { StopExpandDetail } from './stop-expand-detail';
```

**Step 4: Verify dev server compiles**

**Step 5: Commit**

```bash
git add dashboard/src/components/approvals/gap-expand-detail.tsx dashboard/src/components/approvals/stop-expand-detail.tsx dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "refactor: extract GapExpandDetail + StopExpandDetail (perf)"
```

---

## Task 4: Split day-approval-detail.tsx — Extract row components

**Files:**
- Create: `dashboard/src/components/approvals/approval-rows.tsx`
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Create `approval-rows.tsx`**

Move the bottom-of-file row components (lines ~1230-2077):
- `TripConnectorRow`
- `GapSubRow`
- `MergedLocationRow`
- `ActivityRow`
- `ApprovalActivityIcon` (lines 328-361)
- `ProjectCell` (lines ~142-182)

These are the heaviest JSX blocks. Group them together since they share types and rendering patterns.

```tsx
'use client';

import { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
// ... all needed imports

import { getProjectSlices, STATUS_BADGE, type ProjectSlice } from './approval-utils';
import { TripExpandDetail } from './trip-expand-detail';
import { GapExpandDetail } from './gap-expand-detail';
import { StopExpandDetail } from './stop-expand-detail';

export function ProjectCell({ slices }: { slices: ProjectSlice[] }) { ... }
export function ApprovalActivityIcon({ activity }: { activity: ApprovalActivity }) { ... }
export function TripConnectorRow({ ... }) { ... }
export function GapSubRow({ ... }) { ... }
export function MergedLocationRow({ ... }) { ... }
export function ActivityRow({ ... }) { ... }
```

**Step 2: Update `day-approval-detail.tsx`**

```ts
import {
  ProjectCell, ApprovalActivityIcon,
  TripConnectorRow, GapSubRow, MergedLocationRow, ActivityRow,
} from './approval-rows';
```

After this task, `day-approval-detail.tsx` should contain ONLY the main `DayApprovalDetail` component (~550 lines: state, fetchDetail, processedActivities, durationStats, and the Sheet/panel JSX).

**Step 3: Verify dev server compiles + test the approval detail panel manually**

**Step 4: Commit**

```bash
git add dashboard/src/components/approvals/approval-rows.tsx dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "refactor: extract approval row components — day-approval-detail now ~550 lines"
```

---

## Task 5: Middleware — Replace getUser() with getSession()

**Files:**
- Modify: `dashboard/src/middleware.ts`

**Context:** `getUser()` makes a network round-trip to Supabase's auth server (ca-central-1) on every page load — ~500ms-1s. `getSession()` only reads the JWT from the cookie and validates it locally — ~0ms network. The trade-off: the JWT could theoretically be stale (revoked user still has a valid token until expiry). This is acceptable for middleware route-guarding because:
- JWTs expire every hour by default
- Actual data-fetching in server components/route handlers can still call `getUser()` when needed
- The role cache already accepts 5-min staleness

**Step 1: Edit middleware.ts**

Replace line 36:
```ts
// BEFORE
const { data: { user } } = await supabase.auth.getUser();

// AFTER
const { data: { session } } = await supabase.auth.getSession();
const user = session?.user ?? null;
```

That's it. The rest of the middleware logic stays the same — `user` is still `User | null`.

**Step 2: Verify dev server loads and login/redirect still works**

Run: `cd dashboard && npm run dev`
Test: Navigate to `/dashboard` — should redirect to `/login` when not authenticated. Login, then navigate — should load normally.

**Step 3: Commit**

```bash
git add dashboard/src/middleware.ts
git commit -m "perf: replace getUser() with getSession() in middleware — eliminates ~500ms network call"
```

---

## Task 6: Disable `output: 'standalone'` in dev mode

**Files:**
- Modify: `dashboard/next.config.ts`

**Context:** `output: 'standalone'` triggers additional build optimizations (tree-shaking server dependencies, creating a minimal `node_modules` copy) that slow down dev compilation. It's only needed for Vercel production deploys.

**Step 1: Edit next.config.ts**

Replace line 8:
```ts
// BEFORE
output: 'standalone',

// AFTER
...(process.env.NODE_ENV === 'production' ? { output: 'standalone' as const } : {}),
```

**Step 2: Verify**

Run: `cd dashboard && npm run dev` — should start faster.
Run: `cd dashboard && npm run build` — should still produce standalone output.

**Step 3: Commit**

```bash
git add dashboard/next.config.ts
git commit -m "perf: only enable standalone output in production builds"
```

---

## Expected Results

| Optimization | Before | After |
|---|---|---|
| **day-approval-detail.tsx** | 2,078 lines (webpack recompiles all on any edit) | ~550 lines main + 5 focused modules (~200-400 lines each) |
| **Middleware getUser()** | ~500ms-1s network call per page load | ~0ms (local JWT read) |
| **standalone output** | Always on (dev + prod) | Only in `npm run build` |

The three optimizations are independent and can be done in any order. Tasks 1-4 should be done sequentially (each builds on the previous split). Tasks 5 and 6 can be done in parallel with each other or with Tasks 1-4.
