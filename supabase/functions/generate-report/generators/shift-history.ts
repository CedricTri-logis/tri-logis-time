/**
 * Shift History Export Generator
 * Spec: 013-reports-export
 *
 * Generates detailed shift history exports with GPS data
 */

export interface ShiftHistoryRow {
  employee_id: string;
  employee_name: string;
  employee_identifier?: string;
  shift_id: string;
  clocked_in_at: string;
  clocked_out_at?: string;
  duration_minutes?: number;
  status: string;
  gps_point_count: number;
  clock_in_latitude?: number;
  clock_in_longitude?: number;
  clock_out_latitude?: number;
  clock_out_longitude?: number;
}

export interface ShiftHistoryData {
  rows: ShiftHistoryRow[];
  metadata: {
    generated_at: string;
    date_range: string;
    generated_by?: string;
  };
}

/**
 * Group shift history rows by employee
 */
export function groupByEmployee(rows: ShiftHistoryRow[]): Map<string, ShiftHistoryRow[]> {
  const grouped = new Map<string, ShiftHistoryRow[]>();

  for (const row of rows) {
    const key = row.employee_id;
    if (!grouped.has(key)) {
      grouped.set(key, []);
    }
    grouped.get(key)!.push(row);
  }

  return grouped;
}

/**
 * Calculate employee summary stats
 */
function calculateEmployeeStats(shifts: ShiftHistoryRow[]): {
  totalShifts: number;
  totalHours: number;
  totalGpsPoints: number;
} {
  const totalMinutes = shifts.reduce((sum, s) => sum + (s.duration_minutes || 0), 0);
  const totalGpsPoints = shifts.reduce((sum, s) => sum + (s.gps_point_count || 0), 0);

  return {
    totalShifts: shifts.length,
    totalHours: Math.round((totalMinutes / 60) * 100) / 100,
    totalGpsPoints,
  };
}

/**
 * Generate HTML for shift history report
 */
export function generateShiftHistoryHtml(data: ShiftHistoryData, template: string): string {
  const { rows, metadata } = data;
  const grouped = groupByEmployee(rows);

  const uniqueEmployees = new Set(rows.map((r) => r.employee_id));

  // Generate employee sections
  const employeeSections: string[] = [];

  grouped.forEach((employeeShifts, employeeId) => {
    const firstShift = employeeShifts[0];
    const stats = calculateEmployeeStats(employeeShifts);

    const section = `
      <div class="employee-section">
        <div class="employee-header">
          <div class="employee-name">${escapeHtml(firstShift.employee_name)}</div>
          <div class="employee-id">ID: ${escapeHtml(firstShift.employee_identifier || employeeId)}</div>
          <div class="employee-stats">
            <div class="stat-item">
              <span class="stat-label">Shifts:</span>
              <span class="stat-value">${stats.totalShifts}</span>
            </div>
            <div class="stat-item">
              <span class="stat-label">Total Hours:</span>
              <span class="stat-value">${stats.totalHours.toFixed(1)}</span>
            </div>
            <div class="stat-item">
              <span class="stat-label">GPS Points:</span>
              <span class="stat-value">${stats.totalGpsPoints.toLocaleString()}</span>
            </div>
          </div>
        </div>
        <table>
          <thead>
            <tr>
              <th>Shift ID</th>
              <th>Clock In</th>
              <th>Clock Out</th>
              <th>Hours</th>
              <th>GPS Points</th>
              <th>Clock In Location</th>
              <th>Clock Out Location</th>
            </tr>
          </thead>
          <tbody>
            ${generateShiftRows(employeeShifts)}
          </tbody>
        </table>
      </div>
    `;

    employeeSections.push(section);
  });

  return template
    .replace(/\{\{DATE_RANGE\}\}/g, metadata.date_range)
    .replace(/\{\{GENERATED_AT\}\}/g, new Date(metadata.generated_at).toLocaleString())
    .replace(/\{\{GENERATED_BY\}\}/g, metadata.generated_by || 'System')
    .replace(/\{\{TOTAL_SHIFTS\}\}/g, rows.length.toString())
    .replace(/\{\{TOTAL_EMPLOYEES\}\}/g, uniqueEmployees.size.toString())
    .replace(/\{\{EMPLOYEE_SECTIONS\}\}/g, employeeSections.join('\n'));
}

/**
 * Generate table rows for a single employee's shifts
 */
function generateShiftRows(shifts: ShiftHistoryRow[]): string {
  return shifts
    .map((shift) => {
      const hours = shift.duration_minutes
        ? (shift.duration_minutes / 60).toFixed(2)
        : '-';
      const clockIn = shift.clocked_in_at
        ? new Date(shift.clocked_in_at).toLocaleString()
        : '-';
      const clockOut = shift.clocked_out_at
        ? new Date(shift.clocked_out_at).toLocaleString()
        : '-';
      const clockInLoc = formatLocation(shift.clock_in_latitude, shift.clock_in_longitude);
      const clockOutLoc = formatLocation(shift.clock_out_latitude, shift.clock_out_longitude);

      return `
        <tr>
          <td>${shift.shift_id.substring(0, 8)}...</td>
          <td>${clockIn}</td>
          <td>${clockOut}</td>
          <td>${hours}</td>
          <td><span class="gps-points">${shift.gps_point_count}</span></td>
          <td class="location-cell">${clockInLoc}</td>
          <td class="location-cell">${clockOutLoc}</td>
        </tr>
      `;
    })
    .join('\n');
}

/**
 * Format latitude/longitude for display
 */
function formatLocation(lat?: number, lng?: number): string {
  if (!lat || !lng) return '-';
  return `${lat.toFixed(6)}, ${lng.toFixed(6)}`;
}

/**
 * Generate CSV content for shift history
 */
export function generateShiftHistoryCsv(data: ShiftHistoryData): string {
  const { rows, metadata } = data;

  const metadataLines = [
    '# SHIFT HISTORY EXPORT',
    `# Date Range: ${metadata.date_range}`,
    `# Generated: ${metadata.generated_at}`,
    `# Total Shifts: ${rows.length}`,
    '#',
  ];

  const header = [
    'Employee Name',
    'Employee ID',
    'Shift ID',
    'Clock In',
    'Clock Out',
    'Duration (Hours)',
    'Status',
    'GPS Points',
    'Clock In Lat',
    'Clock In Lng',
    'Clock Out Lat',
    'Clock Out Lng',
  ].join(',');

  const dataRows = rows.map((row) =>
    [
      escapeCsvField(row.employee_name),
      escapeCsvField(row.employee_identifier || ''),
      row.shift_id,
      row.clocked_in_at || '',
      row.clocked_out_at || '',
      row.duration_minutes ? (row.duration_minutes / 60).toFixed(2) : '',
      row.status,
      row.gps_point_count.toString(),
      row.clock_in_latitude?.toFixed(8) || '',
      row.clock_in_longitude?.toFixed(8) || '',
      row.clock_out_latitude?.toFixed(8) || '',
      row.clock_out_longitude?.toFixed(8) || '',
    ].join(',')
  );

  return [...metadataLines, header, ...dataRows].join('\n');
}

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function escapeCsvField(value: string): string {
  if (value.includes(',') || value.includes('"') || value.includes('\n')) {
    return `"${value.replace(/"/g, '""')}"`;
  }
  return value;
}
