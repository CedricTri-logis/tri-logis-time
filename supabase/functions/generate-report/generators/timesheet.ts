/**
 * Timesheet Report Generator
 * Spec: 013-reports-export
 *
 * Generates timesheet reports with employee shift data grouped by employee
 */

export interface TimesheetRow {
  employee_id: string;
  employee_name: string;
  employee_identifier: string;
  shift_date: string;
  clocked_in_at: string;
  clocked_out_at?: string;
  duration_minutes: number;
  status: string;
  notes?: string;
}

export interface TimesheetReportData {
  rows: TimesheetRow[];
  summary: TimesheetSummary;
  metadata: {
    generated_at: string;
    date_range: string;
    generated_by?: string;
  };
}

export interface TimesheetSummary {
  total_employees: number;
  total_shifts: number;
  total_hours: number;
  incomplete_count: number;
}

/**
 * Calculate summary statistics from timesheet rows
 */
export function calculateTimesheetSummary(rows: TimesheetRow[]): TimesheetSummary {
  const uniqueEmployees = new Set(rows.map((r) => r.employee_id));
  const totalMinutes = rows.reduce((sum, r) => sum + (r.duration_minutes || 0), 0);
  const incompleteCount = rows.filter((r) => r.status === 'incomplete').length;

  return {
    total_employees: uniqueEmployees.size,
    total_shifts: rows.length,
    total_hours: Math.round((totalMinutes / 60) * 100) / 100,
    incomplete_count: incompleteCount,
  };
}

/**
 * Group rows by employee for report display
 */
export function groupByEmployee(rows: TimesheetRow[]): Map<string, TimesheetRow[]> {
  const grouped = new Map<string, TimesheetRow[]>();

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
 * Generate HTML table rows for timesheet report
 */
export function generateTimesheetTableRows(rows: TimesheetRow[]): string {
  const grouped = groupByEmployee(rows);
  const tableRows: string[] = [];

  grouped.forEach((employeeRows, employeeId) => {
    const firstRow = employeeRows[0];
    const employeeTotal = employeeRows.reduce((sum, r) => sum + (r.duration_minutes || 0), 0);

    // Employee header row
    tableRows.push(`
      <tr class="employee-header">
        <td colspan="8">
          ${escapeHtml(firstRow.employee_name)}
          ${firstRow.employee_identifier ? `(${escapeHtml(firstRow.employee_identifier)})` : ''}
        </td>
      </tr>
    `);

    // Shift rows for this employee
    for (const row of employeeRows) {
      const hours = row.duration_minutes ? (row.duration_minutes / 60).toFixed(2) : '-';
      const clockIn = row.clocked_in_at
        ? new Date(row.clocked_in_at).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' })
        : '-';
      const clockOut = row.clocked_out_at
        ? new Date(row.clocked_out_at).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' })
        : '-';
      const shiftDate = row.shift_date
        ? new Date(row.shift_date).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
        : '-';

      tableRows.push(`
        <tr>
          <td></td>
          <td>${escapeHtml(row.employee_identifier || '-')}</td>
          <td>${shiftDate}</td>
          <td>${clockIn}</td>
          <td>${clockOut}</td>
          <td class="hours ${row.duration_minutes && row.duration_minutes > 720 ? 'hours-warning' : ''}">${hours}</td>
          <td>
            <span class="status status-${row.status}">
              ${row.status}
            </span>
          </td>
          <td>${escapeHtml(row.notes || '')}</td>
        </tr>
      `);
    }

    // Employee subtotal row
    tableRows.push(`
      <tr class="employee-subtotal">
        <td colspan="5" style="text-align: right;">Subtotal:</td>
        <td class="hours">${(employeeTotal / 60).toFixed(2)}</td>
        <td colspan="2"></td>
      </tr>
    `);
  });

  return tableRows.join('\n');
}

/**
 * Generate full HTML for timesheet report
 */
export function generateTimesheetHtml(data: TimesheetReportData, template: string): string {
  const { rows, summary, metadata } = data;

  const tableRows = generateTimesheetTableRows(rows);

  return template
    .replace(/\{\{DATE_RANGE\}\}/g, metadata.date_range)
    .replace(/\{\{GENERATED_AT\}\}/g, new Date(metadata.generated_at).toLocaleString())
    .replace(/\{\{GENERATED_BY\}\}/g, metadata.generated_by || 'System')
    .replace(/\{\{TOTAL_EMPLOYEES\}\}/g, summary.total_employees.toString())
    .replace(/\{\{TOTAL_SHIFTS\}\}/g, summary.total_shifts.toString())
    .replace(/\{\{TOTAL_HOURS\}\}/g, summary.total_hours.toFixed(2))
    .replace(/\{\{INCOMPLETE_COUNT\}\}/g, summary.incomplete_count.toString())
    .replace(/\{\{TABLE_ROWS\}\}/g, tableRows);
}

/**
 * Generate CSV content for timesheet report
 */
export function generateTimesheetCsv(data: TimesheetReportData): string {
  const { rows, summary, metadata } = data;

  // Metadata header
  const metadataLines = [
    '# TIMESHEET REPORT',
    `# Date Range: ${metadata.date_range}`,
    `# Generated: ${metadata.generated_at}`,
    `# Total Employees: ${summary.total_employees}`,
    `# Total Shifts: ${summary.total_shifts}`,
    `# Total Hours: ${summary.total_hours}`,
    `# Incomplete Shifts: ${summary.incomplete_count}`,
    '#',
  ];

  // CSV header
  const header = 'Employee Name,Employee ID,Shift Date,Clock In,Clock Out,Hours,Status,Notes';

  // Data rows
  const dataRows = rows.map((row) => {
    return [
      escapeCsvField(row.employee_name),
      escapeCsvField(row.employee_identifier || ''),
      row.shift_date || '',
      row.clocked_in_at || '',
      row.clocked_out_at || '',
      row.duration_minutes ? (row.duration_minutes / 60).toFixed(2) : '',
      row.status,
      escapeCsvField(row.notes || ''),
    ].join(',');
  });

  return [...metadataLines, header, ...dataRows].join('\n');
}

/**
 * Escape HTML special characters
 */
function escapeHtml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

/**
 * Escape CSV field (handle commas, quotes, newlines)
 */
function escapeCsvField(value: string): string {
  if (value.includes(',') || value.includes('"') || value.includes('\n')) {
    return `"${value.replace(/"/g, '""')}"`;
  }
  return value;
}
