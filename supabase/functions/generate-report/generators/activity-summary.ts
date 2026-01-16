/**
 * Activity Summary Report Generator
 * Spec: 013-reports-export
 *
 * Generates team activity summary reports with aggregate metrics
 */

export interface ActivitySummaryRow {
  period: string;
  total_hours: number;
  total_shifts: number;
  avg_hours_per_employee: number;
  employees_active: number;
  hours_by_day?: Record<string, number>;
}

export interface ActivitySummaryData {
  rows: ActivitySummaryRow[];
  metadata: {
    generated_at: string;
    date_range: string;
    team_name?: string;
    generated_by?: string;
  };
}

const DAY_ORDER = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/**
 * Generate HTML for activity summary report
 */
export function generateActivitySummaryHtml(
  data: ActivitySummaryData,
  template: string
): string {
  const { rows, metadata } = data;

  // Aggregate all data if multiple rows
  const totals = rows.reduce(
    (acc, row) => {
      acc.totalHours += row.total_hours || 0;
      acc.totalShifts += row.total_shifts || 0;
      acc.employeesActive = Math.max(acc.employeesActive, row.employees_active || 0);

      // Aggregate hours by day
      if (row.hours_by_day) {
        Object.entries(row.hours_by_day).forEach(([day, hours]) => {
          acc.hoursByDay[day] = (acc.hoursByDay[day] || 0) + hours;
        });
      }

      return acc;
    },
    {
      totalHours: 0,
      totalShifts: 0,
      employeesActive: 0,
      hoursByDay: {} as Record<string, number>,
    }
  );

  const avgHours =
    totals.employeesActive > 0
      ? (totals.totalHours / totals.employeesActive).toFixed(1)
      : '0';

  // Find busiest and slowest days
  const dayEntries = Object.entries(totals.hoursByDay);
  const sortedDays = dayEntries.sort((a, b) => b[1] - a[1]);
  const busiestDay = sortedDays.length > 0 ? `${sortedDays[0][0]} (${sortedDays[0][1].toFixed(1)}h)` : 'N/A';
  const slowestDay =
    sortedDays.length > 0
      ? `${sortedDays[sortedDays.length - 1][0]} (${sortedDays[sortedDays.length - 1][1].toFixed(1)}h)`
      : 'N/A';

  // Generate day bars for chart
  const maxHours = Math.max(...Object.values(totals.hoursByDay), 1);
  const dayBars = DAY_ORDER.map((day) => {
    const hours = totals.hoursByDay[day] || 0;
    const height = (hours / maxHours) * 100;
    return `
      <div class="day-bar">
        <div class="value">${hours.toFixed(0)}h</div>
        <div class="bar" style="height: ${Math.max(height, 2)}%;"></div>
        <div class="label">${day}</div>
      </div>
    `;
  }).join('\n');

  return template
    .replace(/\{\{DATE_RANGE\}\}/g, metadata.date_range)
    .replace(/\{\{GENERATED_AT\}\}/g, new Date(metadata.generated_at).toLocaleString())
    .replace(/\{\{GENERATED_BY\}\}/g, metadata.generated_by || 'System')
    .replace(/\{\{TEAM_NAME\}\}/g, metadata.team_name || 'All Teams')
    .replace(/\{\{TOTAL_HOURS\}\}/g, totals.totalHours.toFixed(1))
    .replace(/\{\{TOTAL_SHIFTS\}\}/g, totals.totalShifts.toString())
    .replace(/\{\{ACTIVE_EMPLOYEES\}\}/g, totals.employeesActive.toString())
    .replace(/\{\{AVG_HOURS\}\}/g, avgHours)
    .replace(/\{\{BUSIEST_DAY\}\}/g, busiestDay)
    .replace(/\{\{SLOWEST_DAY\}\}/g, slowestDay)
    .replace(/\{\{DAY_BARS\}\}/g, dayBars);
}

/**
 * Generate CSV for activity summary
 */
export function generateActivitySummaryCsv(data: ActivitySummaryData): string {
  const { rows, metadata } = data;

  const metadataLines = [
    '# TEAM ACTIVITY SUMMARY',
    `# Date Range: ${metadata.date_range}`,
    `# Generated: ${metadata.generated_at}`,
    `# Team: ${metadata.team_name || 'All Teams'}`,
    '#',
  ];

  const header = [
    'Period',
    'Total Hours',
    'Total Shifts',
    'Avg Hours/Employee',
    'Active Employees',
    ...DAY_ORDER.map((d) => `${d} Hours`),
  ].join(',');

  const dataRows = rows.map((row) => {
    const hbd = row.hours_by_day || {};
    return [
      row.period,
      row.total_hours.toFixed(2),
      row.total_shifts.toString(),
      row.avg_hours_per_employee.toFixed(2),
      row.employees_active.toString(),
      ...DAY_ORDER.map((d) => (hbd[d] || 0).toFixed(2)),
    ].join(',');
  });

  return [...metadataLines, header, ...dataRows].join('\n');
}
