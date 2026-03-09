# Same-Location GPS Gap Merge — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Merge consecutive same-location stops separated by GPS gaps into a single row with expandable nested gap sub-rows for individual approval.

**Architecture:** Frontend-only change in `day-approval-detail.tsx`. A new `mergeSameLocationGaps()` utility processes the `ProcessedActivity[]` list after `mergeClockEvents()`, grouping consecutive same-location stop+gap chains into `MergedGroup` objects. New `MergedLocationRow` and `GapSubRow` components render these groups. Existing `ActivityRow` is unchanged for non-merged items.

**Tech Stack:** React, TypeScript, Tailwind CSS, lucide-react icons, existing Supabase RPC endpoints.

---

### Task 1: Add `mergeSameLocationGaps()` utility function

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx` (insert after line 45, before the `formatHours` function)

**Step 1: Define the MergedGroup type and write the merge function**

Insert this code block at line 46 (after the imports, before `formatHours`):

```typescript
// --- Same-location GPS gap merging ---

interface MergedGroup {
  /** The primary stop activity (first stop — used for location info, approval actions) */
  primaryStop: ProcessedActivity<ApprovalActivity>;
  /** All stop activities folded into this group */
  stops: ProcessedActivity<ApprovalActivity>[];
  /** Same-location gap activities nested inside (for expand) */
  gaps: ApprovalActivity[];
  /** Earliest started_at across all stops */
  startedAt: string;
  /** Latest ended_at across all stops */
  endedAt: string;
  /** Full span in minutes (from startedAt to endedAt) */
  spanMinutes: number;
  /** Total gap minutes */
  totalGapMinutes: number;
}

type DisplayItem =
  | { type: 'activity'; pa: ProcessedActivity<ApprovalActivity> }
  | { type: 'merged'; group: MergedGroup };

/**
 * Detect consecutive same-location stop/gap chains and merge them.
 * A "same-location gap" is a gap where start_location_id === end_location_id
 * and both are non-null.
 */
function mergeSameLocationGaps(items: ProcessedActivity<ApprovalActivity>[]): DisplayItem[] {
  const result: DisplayItem[] = [];
  let i = 0;

  while (i < items.length) {
    const pa = items[i];

    // Only attempt merge starting from a stop
    if (pa.item.activity_type !== 'stop') {
      result.push({ type: 'activity', pa });
      i++;
      continue;
    }

    // Look ahead: collect stop→sameLocationGap→stop→... chains
    const stops: ProcessedActivity<ApprovalActivity>[] = [pa];
    const gaps: ApprovalActivity[] = [];
    let j = i + 1;

    while (j < items.length) {
      const next = items[j];

      // Next must be a same-location gap
      if (
        next.item.activity_type === 'gap' &&
        next.item.start_location_id &&
        next.item.end_location_id &&
        next.item.start_location_id === next.item.end_location_id
      ) {
        // And after the gap, there should be a stop at the same location
        const afterGap = items[j + 1];
        if (
          afterGap &&
          afterGap.item.activity_type === 'stop' &&
          afterGap.item.matched_location_id === pa.item.matched_location_id
        ) {
          gaps.push(next.item);
          stops.push(afterGap);
          j += 2; // skip gap + stop
          continue;
        }
      }
      break;
    }

    if (gaps.length === 0) {
      // No merging happened — emit as normal activity
      result.push({ type: 'activity', pa });
      i++;
    } else {
      // Build merged group
      const startedAt = stops[0].item.started_at;
      const endedAt = stops[stops.length - 1].item.ended_at;
      const spanMs = new Date(endedAt).getTime() - new Date(startedAt).getTime();
      const totalGapMinutes = gaps.reduce((sum, g) => sum + g.duration_minutes, 0);

      result.push({
        type: 'merged',
        group: {
          primaryStop: pa,
          stops,
          gaps,
          startedAt,
          endedAt,
          spanMinutes: Math.round(spanMs / 60000),
          totalGapMinutes,
        },
      });
      i = j; // skip past all consumed items
    }
  }

  return result;
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/cedric/Desktop/Desktop\ -\ Cedric\'s\ MacBook\ Pro\ -\ 1/PROJECT/TEST/GPS_Tracker/dashboard && npx tsc --noEmit --pretty 2>&1 | head -30`
Expected: No errors related to `mergeSameLocationGaps`

**Step 3: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: add mergeSameLocationGaps utility for same-location GPS gap grouping"
```

---

### Task 2: Wire `mergeSameLocationGaps` into the render pipeline

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx` (around lines 518-521 and 869-894)

**Step 1: Add displayItems memo after processedActivities**

After the existing `processedActivities` memo (line ~521), add:

```typescript
  // Merge same-location GPS gaps into grouped rows
  const displayItems = useMemo(() => {
    return mergeSameLocationGaps(processedActivities);
  }, [processedActivities]);
```

**Step 2: Update visibleNeedsReviewCount to use displayItems**

The existing `visibleNeedsReviewCount` memo (lines 523-529) stays the same — it already works on `processedActivities` which is correct since it counts all individual activities.

**Step 3: Update the table body render loop**

Replace the `processedActivities.map(...)` block (lines ~869-894) with:

```typescript
                    displayItems.map((item, idx) => {
                      if (item.type === 'merged') {
                        const group = item.group;
                        const key = `merged-${group.primaryStop.item.activity_id}`;
                        return (
                          <MergedLocationRow
                            key={key}
                            group={group}
                            isApproved={isApproved}
                            isSaving={isSaving}
                            isExpanded={expandedId === key}
                            onToggle={() => setExpandedId(expandedId === key ? null : key)}
                            onOverride={handleOverride}
                          />
                        );
                      }

                      const pa = item.pa;
                      const key = `${pa.item.activity_type}-${pa.item.activity_id}`;
                      const isTrip = pa.item.activity_type === 'trip';

                      return isTrip ? (
                        <TripConnectorRow
                          key={key}
                          pa={pa}
                          isApproved={isApproved}
                          isSaving={isSaving}
                          isExpanded={expandedId === key}
                          onToggle={() => setExpandedId(expandedId === key ? null : key)}
                          onOverride={handleOverride}
                        />
                      ) : (
                        <ActivityRow
                          key={key}
                          pa={pa}
                          isApproved={isApproved}
                          isSaving={isSaving}
                          isExpanded={expandedId === key}
                          onToggle={() => setExpandedId(expandedId === key ? null : key)}
                          onOverride={handleOverride}
                        />
                      );
                    })
```

**Step 4: Verify it compiles** (MergedLocationRow doesn't exist yet — expect that error only)

Run: `cd /Users/cedric/Desktop/Desktop\ -\ Cedric\'s\ MacBook\ Pro\ -\ 1/PROJECT/TEST/GPS_Tracker/dashboard && npx tsc --noEmit --pretty 2>&1 | head -30`
Expected: Error about `MergedLocationRow` not being defined (that's Task 3)

**Step 5: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: wire mergeSameLocationGaps into approval detail render pipeline"
```

---

### Task 3: Create `MergedLocationRow` component

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx` (insert before `ActivityRow` at line ~1126)

**Step 1: Write the MergedLocationRow component**

Insert before the `// --- Individual activity row ---` comment:

```typescript
// --- Merged same-location row (stops + nested GPS gaps) ---

function MergedLocationRow({
  group,
  isApproved,
  isSaving,
  isExpanded,
  onToggle,
  onOverride,
}: {
  group: MergedGroup;
  isApproved: boolean;
  isSaving: boolean;
  isExpanded: boolean;
  onToggle: () => void;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
}) {
  const activity = group.primaryStop.item;
  const { hasClockIn, hasClockOut } = group.primaryStop;
  // Also check if last stop has clock-out merged
  const lastStopHasClockOut = group.stops[group.stops.length - 1].hasClockOut;
  const hasOverride = activity.override_status !== null;
  const hasUnreviewedGaps = group.gaps.some(g => {
    const final = g.override_status ?? g.auto_status;
    return final === 'needs_review';
  });

  const statusConfig = {
    approved: {
      row: hasOverride
        ? 'bg-green-100 border-l-[6px] border-l-green-600 hover:bg-green-200/70'
        : 'bg-green-50 border-l-4 border-l-green-500 hover:bg-green-100/80',
      badge: 'bg-green-100 text-green-700 border-green-200 ring-1 ring-green-600/10',
      icon: CheckCircle2,
      label: 'Approuve',
      btnApprove: 'text-green-700 bg-green-100 border-green-300 shadow-sm',
      btnReject: 'text-gray-400 hover:text-red-600 hover:bg-red-50 border-transparent',
      text: hasOverride ? 'text-green-950 font-bold' : 'text-green-900 font-medium',
      subtext: 'text-green-700/70',
    },
    rejected: {
      row: hasOverride
        ? 'bg-red-100 border-l-[6px] border-l-red-600 hover:bg-red-200/70'
        : 'bg-red-50 border-l-4 border-l-red-500 hover:bg-red-100/80',
      badge: 'bg-red-100 text-red-700 border-red-200 ring-1 ring-red-600/10',
      icon: XCircle,
      label: 'Rejete',
      btnApprove: 'text-gray-400 hover:text-green-600 hover:bg-green-50 border-transparent',
      btnReject: 'text-red-700 bg-red-100 border-red-300 shadow-sm',
      text: hasOverride ? 'text-red-950 font-bold' : 'text-red-900 font-medium',
      subtext: 'text-red-700/70',
    },
    needs_review: {
      row: 'bg-amber-50 border-l-4 border-l-amber-500 hover:bg-amber-100/80 shadow-[inset_0_0_0_1px_rgba(251,191,36,0.1)]',
      badge: 'bg-amber-100 text-amber-800 border-amber-200 ring-2 ring-amber-500/20',
      icon: AlertTriangle,
      label: 'A verifier',
      btnApprove: 'text-gray-500 hover:text-green-600 hover:bg-green-50 border-gray-200',
      btnReject: 'text-gray-500 hover:text-red-600 hover:bg-red-50 border-gray-200',
      text: 'text-amber-950 font-bold',
      subtext: 'text-amber-800/80',
    }
  }[activity.final_status];

  // Yellow tint override when unreviewed gaps exist
  const rowClassName = hasUnreviewedGaps
    ? `${statusConfig.row} ring-2 ring-amber-400/40 bg-gradient-to-r from-amber-50/80 to-transparent`
    : statusConfig.row;

  return (
    <>
      <tr
        className={`${rowClassName} cursor-pointer transition-all duration-200 group border-b border-white/50`}
        onClick={onToggle}
      >
        {/* Action / Approbation — applies to stop only */}
        <td className="px-3 py-3 text-center">
          {!isApproved ? (
            <div className="flex items-center justify-center gap-2" onClick={(e) => e.stopPropagation()}>
              <div className="relative group/btn">
                {activity.override_status === 'approved' && (
                  <>
                    <div className="absolute -inset-1 rounded-full border border-blue-500/40 shadow-[0_0_12px_rgba(59,130,246,0.3)]" />
                    <div className="absolute -inset-[3px] rounded-full border border-blue-500/10" />
                  </>
                )}
                <Button
                  variant="outline"
                  size="icon"
                  className={`h-9 w-9 rounded-full transition-all relative z-0 hover:scale-105 active:scale-95 border-2 ${
                    activity.override_status === 'approved'
                      ? 'border-blue-600 bg-white text-green-600 shadow-sm'
                      : statusConfig.btnApprove + ' border-transparent shadow-none'
                  }`}
                  onClick={() => onOverride(activity, 'approved')}
                  disabled={isSaving}
                >
                  <CheckCircle2 className={`h-4.5 w-4.5 ${activity.override_status === 'approved' ? 'stroke-[2.5px]' : ''}`} />
                </Button>
              </div>
              <div className="relative group/btn">
                {activity.override_status === 'rejected' && (
                  <>
                    <div className="absolute -inset-1 rounded-full border border-blue-500/40 shadow-[0_0_12px_rgba(59,130,246,0.3)]" />
                    <div className="absolute -inset-[3px] rounded-full border border-blue-500/10" />
                  </>
                )}
                <Button
                  variant="outline"
                  size="icon"
                  className={`h-9 w-9 rounded-full transition-all relative z-0 hover:scale-105 active:scale-95 border-2 ${
                    activity.override_status === 'rejected'
                      ? 'border-blue-600 bg-white text-red-600 shadow-sm'
                      : statusConfig.btnReject + ' border-transparent shadow-none'
                  }`}
                  onClick={() => onOverride(activity, 'rejected')}
                  disabled={isSaving}
                >
                  <XCircle className={`h-4.5 w-4.5 ${activity.override_status === 'rejected' ? 'stroke-[2.5px]' : ''}`} />
                </Button>
              </div>
            </div>
          ) : (
            <div className="flex justify-center">
              <Badge variant="outline" className={`font-bold text-[10px] px-2.5 py-0.5 rounded-full shadow-sm ${statusConfig.badge}`}>
                {(() => { const StatusIcon = statusConfig.icon; return <StatusIcon className="h-3 w-3 mr-1" />; })()}
                {statusConfig.label}
              </Badge>
            </div>
          )}
        </td>

        {/* Clock-in/out indicator */}
        <td className="px-2 py-3 text-center">
          <div className="flex items-center justify-center gap-0.5">
            {hasClockIn && <span title="Debut de quart"><LogIn className="h-3.5 w-3.5 text-emerald-600" /></span>}
            {lastStopHasClockOut && <span title="Fin de quart"><LogOut className="h-3.5 w-3.5 text-red-600" /></span>}
          </div>
        </td>

        {/* Type icon */}
        <td className="px-2 py-3 text-center">
          <div className="flex justify-center bg-white/80 rounded-lg p-1.5 shadow-sm border border-black/5 group-hover:scale-110 transition-transform">
            <ApprovalActivityIcon activity={activity} />
          </div>
        </td>

        {/* Duree — full span */}
        <td className="px-3 py-3 whitespace-nowrap">
          <div className={`flex items-center gap-1.5 tabular-nums text-xs ${statusConfig.text}`}>
            {formatDurationMinutes(group.spanMinutes)}
          </div>
          {/* GPS gap badge */}
          {group.totalGapMinutes > 0 && (
            <div className={`text-[10px] mt-0.5 flex items-center gap-1 ${hasUnreviewedGaps ? 'text-amber-600 font-semibold' : 'text-amber-600/70'}`}>
              <WifiOff className="h-3 w-3" />
              <span>
                {group.gaps.length > 1 ? `${group.gaps.length} gaps \u00b7 ` : ''}
                {formatDurationMinutes(group.totalGapMinutes)} GPS perdu
              </span>
            </div>
          )}
        </td>

        {/* Details */}
        <td className="px-3 py-3 max-w-[300px]">
          <div className="space-y-1">
            <div className={`text-xs flex items-center gap-1.5 ${statusConfig.text}`}>
              <span className={activity.location_name ? 'font-bold underline decoration-current/20' : ''}>
                {activity.location_name || 'Arret non associe'}
              </span>
            </div>
            <div className="flex items-center gap-1.5">
              <span className={`text-[10px] leading-tight italic ${statusConfig.subtext}`}>
                {activity.auto_reason}
              </span>
            </div>
          </div>
        </td>

        {/* Horaire — full span */}
        <td className="px-3 py-3 whitespace-nowrap">
          <div className="flex flex-col">
            <span className={`text-xs font-black ${statusConfig.text}`}>{formatTime(group.startedAt)}</span>
            <span className={`text-[10px] font-medium ${statusConfig.subtext}`}>{formatTime(group.endedAt)}</span>
          </div>
        </td>

        {/* Distance — dash for merged location rows */}
        <td className="px-3 py-3 text-right tabular-nums whitespace-nowrap">
          <span className="opacity-20 text-xs font-bold">&mdash;</span>
        </td>

        {/* Expand chevron */}
        <td className="px-3 py-3 text-center">
          <div className={`rounded-full p-1 transition-colors ${isExpanded ? 'bg-muted' : 'group-hover:bg-muted'}`}>
            {isExpanded
              ? <ChevronUp className="h-4 w-4 text-primary" />
              : <ChevronDown className="h-4 w-4 text-muted-foreground" />
            }
          </div>
        </td>
      </tr>

      {/* Expanded: nested GPS gap sub-rows */}
      {isExpanded && (
        <tr>
          <td colSpan={8} className="p-0 border-b">
            <div className="px-6 py-4 bg-amber-50/30 border-t border-amber-200/50">
              {/* Bulk approve button */}
              {!isApproved && hasUnreviewedGaps && (
                <div className="flex items-center gap-2 mb-3">
                  <Button
                    variant="outline"
                    size="sm"
                    className="text-xs h-7 bg-green-50 text-green-700 border-green-300 hover:bg-green-100"
                    disabled={isSaving}
                    onClick={() => {
                      group.gaps.forEach(gap => {
                        const final = gap.override_status ?? gap.auto_status;
                        if (final === 'needs_review') {
                          onOverride(gap, 'approved');
                        }
                      });
                    }}
                  >
                    <CheckCircle2 className="h-3 w-3 mr-1" />
                    Tout approuver ({group.gaps.filter(g => (g.override_status ?? g.auto_status) === 'needs_review').length})
                  </Button>
                </div>
              )}

              {/* Individual gap rows */}
              <div className="space-y-2">
                {group.gaps.map((gap) => (
                  <GapSubRow
                    key={gap.activity_id}
                    gap={gap}
                    isApproved={isApproved}
                    isSaving={isSaving}
                    onOverride={onOverride}
                  />
                ))}
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  );
}
```

**Step 2: Verify it compiles** (GapSubRow doesn't exist yet — expect that error)

Run: `cd /Users/cedric/Desktop/Desktop\ -\ Cedric\'s\ MacBook\ Pro\ -\ 1/PROJECT/TEST/GPS_Tracker/dashboard && npx tsc --noEmit --pretty 2>&1 | head -30`
Expected: Error about `GapSubRow` not being defined (that's Task 4)

**Step 3: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: add MergedLocationRow component for same-location GPS gap groups"
```

---

### Task 4: Create `GapSubRow` component

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx` (insert right before `MergedLocationRow`)

**Step 1: Write the GapSubRow component**

Insert before `MergedLocationRow`:

```typescript
// --- GPS gap sub-row inside merged location row ---

function GapSubRow({
  gap,
  isApproved,
  isSaving,
  onOverride,
}: {
  gap: ApprovalActivity;
  isApproved: boolean;
  isSaving: boolean;
  onOverride: (activity: ApprovalActivity, status: 'approved' | 'rejected') => void;
}) {
  const finalStatus = gap.override_status ?? gap.auto_status;
  const hasOverride = gap.override_status !== null;

  const config = {
    approved: {
      bg: 'bg-green-50 border-green-200',
      text: 'text-green-800',
      sub: 'text-green-600/70',
    },
    rejected: {
      bg: 'bg-red-50 border-red-200',
      text: 'text-red-800',
      sub: 'text-red-600/70',
    },
    needs_review: {
      bg: 'bg-amber-50 border-amber-300',
      text: 'text-amber-900',
      sub: 'text-amber-700/80',
    },
  }[finalStatus];

  return (
    <div className={`flex items-center gap-3 px-3 py-2 rounded-lg border ${config.bg} ${hasOverride ? 'ring-1 ring-blue-400/30' : ''}`}>
      <WifiOff className="h-3.5 w-3.5 text-purple-500 flex-shrink-0" />

      <div className="flex-1 min-w-0">
        <div className={`text-xs font-medium ${config.text}`}>
          Signal GPS perdu
        </div>
        <div className={`text-[10px] ${config.sub}`}>
          {formatTime(gap.started_at)} — {formatTime(gap.ended_at)} · {formatDurationMinutes(gap.duration_minutes)}
        </div>
      </div>

      {/* Approve / Reject */}
      {!isApproved ? (
        <div className="flex items-center gap-1.5" onClick={(e) => e.stopPropagation()}>
          <div className="relative">
            {gap.override_status === 'approved' && (
              <div className="absolute -inset-0.5 rounded-full border border-blue-500/40 shadow-[0_0_8px_rgba(59,130,246,0.2)]" />
            )}
            <Button
              variant="outline"
              size="icon"
              className={`h-7 w-7 rounded-full transition-all relative z-0 border ${
                gap.override_status === 'approved'
                  ? 'border-blue-500 bg-white text-green-600'
                  : finalStatus === 'approved'
                    ? 'text-green-600 bg-green-50 border-green-300'
                    : 'text-gray-400 hover:text-green-600 hover:bg-green-50 border-gray-200'
              }`}
              onClick={() => onOverride(gap, 'approved')}
              disabled={isSaving}
            >
              <CheckCircle2 className="h-3.5 w-3.5" />
            </Button>
          </div>
          <div className="relative">
            {gap.override_status === 'rejected' && (
              <div className="absolute -inset-0.5 rounded-full border border-blue-500/40 shadow-[0_0_8px_rgba(59,130,246,0.2)]" />
            )}
            <Button
              variant="outline"
              size="icon"
              className={`h-7 w-7 rounded-full transition-all relative z-0 border ${
                gap.override_status === 'rejected'
                  ? 'border-blue-500 bg-white text-red-600'
                  : finalStatus === 'rejected'
                    ? 'text-red-600 bg-red-50 border-red-300'
                    : 'text-gray-400 hover:text-red-600 hover:bg-red-50 border-gray-200'
              }`}
              onClick={() => onOverride(gap, 'rejected')}
              disabled={isSaving}
            >
              <XCircle className="h-3.5 w-3.5" />
            </Button>
          </div>
        </div>
      ) : (
        <Badge
          variant="outline"
          className={`text-[10px] px-2 py-0.5 rounded-full ${
            finalStatus === 'approved' ? 'bg-green-100 text-green-700 border-green-200' :
            finalStatus === 'rejected' ? 'bg-red-100 text-red-700 border-red-200' :
            'bg-amber-100 text-amber-700 border-amber-200'
          }`}
        >
          {finalStatus === 'approved' ? 'Approuve' : finalStatus === 'rejected' ? 'Rejete' : 'A verifier'}
        </Badge>
      )}
    </div>
  );
}
```

**Step 2: Verify full compilation**

Run: `cd /Users/cedric/Desktop/Desktop\ -\ Cedric\'s\ MacBook\ Pro\ -\ 1/PROJECT/TEST/GPS_Tracker/dashboard && npx tsc --noEmit --pretty 2>&1 | head -30`
Expected: No type errors

**Step 3: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "feat: add GapSubRow component for individual GPS gap approval"
```

---

### Task 5: Fix bulk approve to work sequentially and update durationStats

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx`

**Step 1: Fix the bulk approve in MergedLocationRow**

The `forEach` loop calling `onOverride` won't work correctly because `handleOverride` is async and each call refreshes `detail` state. Replace the bulk approve `onClick` with a sequential approach:

In the `MergedLocationRow` component, replace the bulk approve button's `onClick`:

```typescript
                    onClick={async () => {
                      for (const gap of group.gaps) {
                        const final = gap.override_status ?? gap.auto_status;
                        if (final === 'needs_review') {
                          await onOverride(gap, 'approved');
                        }
                      }
                    }}
```

Note: This works because each `handleOverride` call updates `detail` state via `setDetail(data)`, and the gap `activity_id` is stable (deterministic UUID from the SQL). The next call uses the same stable ID.

**Step 2: Update durationStats to account for merged gaps**

In the `durationStats` useMemo (around line 532-545), the gap total already includes same-location gaps, which is correct — no change needed here. The summary badges show total gap time regardless of merge status.

**Step 3: Verify the full app renders**

Run: `cd /Users/cedric/Desktop/Desktop\ -\ Cedric\'s\ MacBook\ Pro\ -\ 1/PROJECT/TEST/GPS_Tracker/dashboard && npm run build 2>&1 | tail -20`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "fix: sequential bulk approve for merged GPS gaps"
```

---

### Task 6: Visual verification and edge case handling

**Files:**
- Modify: `dashboard/src/components/approvals/day-approval-detail.tsx` (if needed)

**Step 1: Test with Keven Aubry's March 6 data**

Open the dashboard at localhost, navigate to the approval grid, find Keven Aubry on March 6, 2026. Verify:
- The two 284-288_Dallaire stops are merged into one row
- The row shows full span (08:22-15:55)
- The GPS gap badge shows "4h13 GPS perdu"
- The row has a yellow tint (amber ring)
- Clicking expands to show the gap sub-row
- The gap sub-row has approve/reject buttons
- Approving the gap removes the yellow tint
- The main row's approve/reject works independently

**Step 2: Verify non-merged activities are unchanged**

Check that:
- Different-location gaps still show as "Deplacement non trace"
- Clock-in/out gaps still show as "Temps non suivi"
- Trips still show as TripConnectorRow
- Lunch breaks still show normally

**Step 3: Commit if any fixes were needed**

```bash
git add dashboard/src/components/approvals/day-approval-detail.tsx
git commit -m "fix: edge cases in same-location GPS gap merging"
```

---

Plan complete and saved to `docs/plans/2026-03-07-same-location-gps-gap-merge.md`. Two execution options:

**1. Subagent-Driven (this session)** — I dispatch fresh subagent per task, review between tasks, fast iteration

**2. Parallel Session (separate)** — Open new session with executing-plans, batch execution with checkpoints

Which approach?
