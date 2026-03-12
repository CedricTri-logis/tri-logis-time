/**
 * Shared clock event merging logic.
 * Merges clock-in/out events into stops when the clock time falls within
 * the stop's time range. Filters micro-shifts and rapid transitions.
 */

/** Minimal interface required for merging — works with both ActivityItem and ApprovalActivity */
export interface MergeableActivity {
  activity_type: 'trip' | 'stop' | 'stop_segment' | 'clock_in' | 'clock_out' | 'gap' | 'lunch';
  shift_id: string;
  started_at: string;
  ended_at: string;
}

export interface ProcessedActivity<T extends MergeableActivity> {
  item: T;
  hasClockIn?: boolean;
  hasClockOut?: boolean;
  clockInActivity?: T;
  clockOutActivity?: T;
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

  // Step 2: Filter out clock events from micro-shifts only
  // Note: rapid clock-out -> clock-in transitions across shifts are kept visible
  // so that each shift's clock events appear in the timeline and shift headers render correctly.
  const filtered = items.filter((item) => {
    if (item.activity_type !== 'clock_in' && item.activity_type !== 'clock_out') return true;
    if (microShiftIds.has(item.shift_id)) return false;
    return true;
  });

  // Step 3: Temporal merge of remaining clock events into stops
  // Use a 60s tolerance — clock-in often fires just before the first GPS cluster,
  // and clock-out just after the last cluster point.
  const MERGE_TOLERANCE_MS = 60_000;
  const mergedIndices = new Set<number>();
  const clockFlags = new Map<number, { clockIn?: boolean; clockOut?: boolean; clockInActivity?: T; clockOutActivity?: T }>();

  for (let i = 0; i < filtered.length; i++) {
    const item = filtered[i];
    if (item.activity_type !== 'clock_in' && item.activity_type !== 'clock_out') continue;

    const clockTime = new Date(item.started_at).getTime();

    // Find the CLOSEST matching stop, not the first — avoids merging both
    // clock_in and clock_out into the same stop when two consecutive stops
    // have overlapping tolerance windows.
    let bestJ = -1;
    let bestDistance = Infinity;
    for (let j = 0; j < filtered.length; j++) {
      if (filtered[j].activity_type !== 'stop' && filtered[j].activity_type !== 'stop_segment' && filtered[j].activity_type !== 'gap') continue;
      if (filtered[j].shift_id !== item.shift_id) continue;
      const stopStart = new Date(filtered[j].started_at).getTime();
      const stopEnd = new Date(filtered[j].ended_at).getTime();
      if (clockTime >= (stopStart - MERGE_TOLERANCE_MS) && clockTime <= (stopEnd + MERGE_TOLERANCE_MS)) {
        // Distance: 0 if clock time is inside the stop, otherwise how far outside
        const distance = clockTime < stopStart ? stopStart - clockTime :
                         clockTime > stopEnd ? clockTime - stopEnd : 0;
        if (distance < bestDistance) {
          bestDistance = distance;
          bestJ = j;
        }
      }
    }
    if (bestJ >= 0) {
      mergedIndices.add(i);
      const existing = clockFlags.get(bestJ) || {};
      if (item.activity_type === 'clock_in') { existing.clockIn = true; existing.clockInActivity = item; }
      if (item.activity_type === 'clock_out') { existing.clockOut = true; existing.clockOutActivity = item; }
      clockFlags.set(bestJ, existing);
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
      clockInActivity: flags?.clockInActivity,
      clockOutActivity: flags?.clockOutActivity,
    });
  }
  return result;
}
