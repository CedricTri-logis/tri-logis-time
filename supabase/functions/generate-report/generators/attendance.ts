/**
 * Attendance Report Generator
 * Spec: 013-reports-export
 *
 * Generates attendance reports with presence/absence tracking and rates
 */

export interface AttendanceRow {
  employee_id: string;
  employee_name: string;
  total_working_days: number;
  days_worked: number;
  days_absent: number;
  attendance_rate: number;
  calendar_data?: Record<string, boolean>;
}

export interface AttendanceData {
  rows: AttendanceRow[];
  metadata: {
    generated_at: string;
    date_range: string;
    generated_by?: string;
  };
}

/**
 * Get rate class based on attendance percentage
 */
function getRateClass(rate: number): string {
  if (rate >= 95) return 'excellent';
  if (rate >= 85) return 'good';
  if (rate >= 75) return 'average';
  if (rate >= 60) return 'poor';
  return 'critical';
}

/**
 * Generate HTML for attendance report
 */
export function generateAttendanceHtml(
  data: AttendanceData,
  template: string
): string {
  const { rows, metadata } = data;

  // Calculate summary metrics
  const totalEmployees = rows.length;
  const workingDays = rows.length > 0 ? rows[0].total_working_days : 0;
  const totalShifts = rows.reduce((sum, row) => sum + row.days_worked, 0);
  const totalAbsences = rows.reduce((sum, row) => sum + row.days_absent, 0);
  const avgAttendanceRate =
    totalEmployees > 0
      ? rows.reduce((sum, row) => sum + (row.attendance_rate || 0), 0) / totalEmployees
      : 0;

  // Generate table rows
  const tableRows = rows
    .map((row) => {
      const rateClass = getRateClass(row.attendance_rate || 0);

      return `
        <tr>
          <td>${row.employee_name || '-'}</td>
          <td>${row.days_worked} / ${row.total_working_days}</td>
          <td>${row.days_absent}</td>
          <td>
            <div class="rate-bar-container">
              <div class="rate-bar">
                <div class="rate-bar-fill ${rateClass}" style="width: ${row.attendance_rate || 0}%;"></div>
              </div>
              <span class="rate-value">${(row.attendance_rate || 0).toFixed(1)}%</span>
            </div>
          </td>
        </tr>
      `;
    })
    .join('\n');

  return template
    .replace(/\{\{DATE_RANGE\}\}/g, metadata.date_range)
    .replace(/\{\{GENERATED_AT\}\}/g, new Date(metadata.generated_at).toLocaleString())
    .replace(/\{\{GENERATED_BY\}\}/g, metadata.generated_by || 'System')
    .replace(/\{\{TOTAL_EMPLOYEES\}\}/g, totalEmployees.toString())
    .replace(/\{\{WORKING_DAYS\}\}/g, workingDays.toString())
    .replace(/\{\{AVG_ATTENDANCE_RATE\}\}/g, avgAttendanceRate.toFixed(1))
    .replace(/\{\{TOTAL_SHIFTS\}\}/g, totalShifts.toString())
    .replace(/\{\{TOTAL_ABSENCES\}\}/g, totalAbsences.toString())
    .replace(/\{\{TABLE_ROWS\}\}/g, tableRows);
}

/**
 * Generate CSV for attendance report
 */
export function generateAttendanceCsv(data: AttendanceData): string {
  const { rows, metadata } = data;

  // Calculate summary
  const avgRate =
    rows.length > 0
      ? rows.reduce((sum, row) => sum + (row.attendance_rate || 0), 0) / rows.length
      : 0;

  const metadataLines = [
    '# ATTENDANCE REPORT',
    `# Date Range: ${metadata.date_range}`,
    `# Generated: ${metadata.generated_at}`,
    `# Total Employees: ${rows.length}`,
    `# Average Attendance Rate: ${avgRate.toFixed(1)}%`,
    '#',
  ];

  const header = [
    'Employee Name',
    'Employee ID',
    'Total Working Days',
    'Days Worked',
    'Days Absent',
    'Attendance Rate (%)',
  ].join(',');

  const dataRows = rows.map((row) => {
    return [
      `"${row.employee_name || ''}"`,
      row.employee_id,
      row.total_working_days.toString(),
      row.days_worked.toString(),
      row.days_absent.toString(),
      (row.attendance_rate || 0).toFixed(2),
    ].join(',');
  });

  return [...metadataLines, header, ...dataRows].join('\n');
}

/**
 * Generate detailed attendance CSV with calendar data
 */
export function generateAttendanceDetailedCsv(data: AttendanceData): string {
  const { rows, metadata } = data;

  // Get all dates from calendar data if available
  const allDates = new Set<string>();
  rows.forEach((row) => {
    if (row.calendar_data) {
      Object.keys(row.calendar_data).forEach((date) => allDates.add(date));
    }
  });

  const sortedDates = Array.from(allDates).sort();

  const metadataLines = [
    '# ATTENDANCE REPORT (DETAILED)',
    `# Date Range: ${metadata.date_range}`,
    `# Generated: ${metadata.generated_at}`,
    '#',
    '# Calendar Legend: 1 = Worked, 0 = Absent',
    '#',
  ];

  const header = [
    'Employee Name',
    'Total Working Days',
    'Days Worked',
    'Days Absent',
    'Attendance Rate (%)',
    ...sortedDates,
  ].join(',');

  const dataRows = rows.map((row) => {
    const calendarValues = sortedDates.map((date) => {
      if (!row.calendar_data) return '';
      return row.calendar_data[date] ? '1' : '0';
    });

    return [
      `"${row.employee_name || ''}"`,
      row.total_working_days.toString(),
      row.days_worked.toString(),
      row.days_absent.toString(),
      (row.attendance_rate || 0).toFixed(2),
      ...calendarValues,
    ].join(',');
  });

  return [...metadataLines, header, ...dataRows].join('\n');
}
