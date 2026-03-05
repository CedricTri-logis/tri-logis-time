/**
 * Shared clock event merging logic.
 * Merges clock-in/out events into stops when the clock time falls within
 * the stop's time range. Filters micro-shifts and rapid transitions.
 */

/** Minimal interface required for merging — works with both ActivityItem and ApprovalActivity */
export interface MergeableActivity {
  activity_type: 'trip' | 'stop' | 'clock_in' | 'clock_out' | 'gap';
  shift_id: string;
  started_at: string;
  ended_at: string;
}

export interface ProcessedActivity<T extends MergeableActivity> {
  item: T;
  hasClockIn?: boolean;
  hasClockOut?: boolean;
}

/**
 * Merge clock events into stops only when the clock event time falls
 * within the stop's time range (i.e., the clock happened inside that cluster).
 * Unmatched clock events (outside any stop) stay as standalone rows.
 * Micro-shifts (clock-in + clock-out < 30s apart on same shift) are hidden entirely.
 * Rapid transitions (clock-out -> clock-in across shifts < 30s) are also hidden.
 */
export function mergeClockEvents<T extends MergeableActivity>(items: T[]): ProcessedActivity<T>[] {
  // Step 1a: Detect micro-shifts (< 30s) and collect their shift_ids to hide
  const microShiftIds = new Set<string>();
  const clockInByShift = new Map<string, T>();
  const clockOutByShift = new Map<string, T>();
  for (const item of items) {
    if (item.activity_type === 'clock_in') clockInByShift.set(item.shift_id, item);
    if (item.activity_type === 'clock_out') clockOutByShift.set(item.shift_id, item);
  }
  for (const [shiftId, clockIn] of clockInByShift) {
    const clockOut = clockOutByShift.get(shiftId);
    if (!clockOut) continue;
    const durationMs = new Date(clockOut.started_at).getTime() - new Date(clockIn.started_at).getTime();
    if (durationMs >= 0 && durationMs < 30_000) {
      microShiftIds.add(shiftId);
    }
  }

  // Step 1b: Detect rapid clock-out -> clock-in transitions across shifts (< 30s gap)
  const rapidTransitionIndices = new Set<number>();
  const clockEventsByTime = items
    .map((item, idx) => ({ item, idx }))
    .filter(({ item }) => item.activity_type === 'clock_in' || item.activity_type === 'clock_out')
    .sort((a, b) => new Date(a.item.started_at).getTime() - new Date(b.item.started_at).getTime());
  for (let k = 0; k < clockEventsByTime.length - 1; k++) {
    const curr = clockEventsByTime[k];
    const next = clockEventsByTime[k + 1];
    if (
      curr.item.activity_type === 'clock_out' &&
      next.item.activity_type === 'clock_in' &&
      curr.item.shift_id !== next.item.shift_id
    ) {
      const gap = new Date(next.item.started_at).getTime() - new Date(curr.item.started_at).getTime();
      if (gap >= 0 && gap < 30_000) {
        rapidTransitionIndices.add(curr.idx);
        rapidTransitionIndices.add(next.idx);
      }
    }
  }

  // Step 2: Filter out clock events from micro-shifts and rapid transitions
  const filtered = items.filter((item, idx) => {
    if (item.activity_type !== 'clock_in' && item.activity_type !== 'clock_out') return true;
    if (microShiftIds.has(item.shift_id)) return false;
    if (rapidTransitionIndices.has(idx)) return false;
    return true;
  });

  // Step 3: Temporal merge of remaining clock events into stops
  // Use a 60s tolerance — clock-in often fires just before the first GPS cluster,
  // and clock-out just after the last cluster point.
  const MERGE_TOLERANCE_MS = 60_000;
  const mergedIndices = new Set<number>();
  const clockFlags = new Map<number, { clockIn?: boolean; clockOut?: boolean }>();

  for (let i = 0; i < filtered.length; i++) {
    const item = filtered[i];
    if (item.activity_type !== 'clock_in' && item.activity_type !== 'clock_out') continue;

    const clockTime = new Date(item.started_at).getTime();

    for (let j = 0; j < filtered.length; j++) {
      if (filtered[j].activity_type !== 'stop' && filtered[j].activity_type !== 'gap') continue;
      const stopStart = new Date(filtered[j].started_at).getTime();
      const stopEnd = new Date(filtered[j].ended_at).getTime();
      if (clockTime >= (stopStart - MERGE_TOLERANCE_MS) && clockTime <= (stopEnd + MERGE_TOLERANCE_MS)) {
        mergedIndices.add(i);
        const existing = clockFlags.get(j) || {};
        if (item.activity_type === 'clock_in') existing.clockIn = true;
        if (item.activity_type === 'clock_out') existing.clockOut = true;
        clockFlags.set(j, existing);
        break;
      }
    }
  }

  const result: ProcessedActivity<T>[] = [];
  for (let i = 0; i < filtered.length; i++) {
    if (mergedIndices.has(i)) continue;
    const flags = clockFlags.get(i);
    result.push({
      item: filtered[i],
      hasClockIn: flags?.clockIn,
      hasClockOut: flags?.clockOut,
    });
  }
  return result;
}
