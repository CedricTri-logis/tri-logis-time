/**
 * Client-side Report Export Utilities
 * Spec: 013-reports-export
 *
 * Handles CSV generation and file downloads for reports
 */

import { format } from 'date-fns';
import type { TimesheetReportRow } from '@/types/reports';

/**
 * Progress callback for large exports
 */
type ProgressCallback = (progress: number) => void;

/**
 * Export metadata for generated files
 */
interface ExportMetadata {
  reportType: string;
  dateRange: string;
  generatedAt: string;
  generatedBy?: string;
  totalRecords: number;
}

/**
 * Chunk size for processing large datasets
 */
const CHUNK_SIZE = 1000;

/**
 * Escape CSV field (handle commas, quotes, newlines)
 */
function escapeCsvField(value: string | number | null | undefined): string {
  if (value === null || value === undefined) return '';
  const str = String(value);
  if (str.includes(',') || str.includes('"') || str.includes('\n')) {
    return `"${str.replace(/"/g, '""')}"`;
  }
  return str;
}

/**
 * Generate CSV header with metadata
 */
function generateMetadataHeader(metadata: ExportMetadata): string[] {
  return [
    `# RAPPORT ${metadata.reportType.toUpperCase()}`,
    `# Période : ${metadata.dateRange}`,
    `# Généré le : ${metadata.generatedAt}`,
    `# Généré par : ${metadata.generatedBy || 'Système'}`,
    `# Nombre d'enregistrements : ${metadata.totalRecords}`,
    '#',
  ];
}

/**
 * Trigger file download in browser with BOM for Excel compatibility
 */
function downloadFile(content: string, filename: string): void {
  // Add BOM for Excel UTF-8 compatibility
  const bom = '\uFEFF';
  const blob = new Blob([bom + content], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);

  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();

  // Cleanup
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}

/**
 * Generate filename for export
 */
function generateFilename(reportType: string, extension: string): string {
  const date = format(new Date(), 'yyyy-MM-dd_HHmmss');
  return `${reportType}_report_${date}.${extension}`;
}

/**
 * Export timesheet report to CSV
 */
export function exportTimesheetToCsv(
  rows: TimesheetReportRow[],
  metadata: ExportMetadata,
  onProgress?: ProgressCallback
): void {
  // Metadata header
  const metadataLines = generateMetadataHeader(metadata);

  // CSV header
  const headers = [
    'Nom de l\'employé',
    'Numéro d\'employé',
    'Date du quart',
    'Pointage arrivée',
    'Pointage départ',
    'Durée (heures)',
    'Statut',
    'Notes',
  ].join(',');

  // Build data rows with progress reporting
  const dataRows: string[] = [];

  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const dataRow = [
      escapeCsvField(row.employee_name),
      escapeCsvField(row.employee_identifier),
      row.shift_date || '',
      row.clocked_in_at ? format(new Date(row.clocked_in_at), 'yyyy-MM-dd HH:mm:ss') : '',
      row.clocked_out_at ? format(new Date(row.clocked_out_at), 'yyyy-MM-dd HH:mm:ss') : '',
      row.duration_minutes ? (row.duration_minutes / 60).toFixed(2) : '',
      row.status,
      escapeCsvField(row.notes),
    ].join(',');
    dataRows.push(dataRow);

    // Report progress
    if (onProgress && i % CHUNK_SIZE === 0) {
      onProgress((i / rows.length) * 100);
    }
  }

  // Combine content
  const content = [...metadataLines, headers, ...dataRows].join('\n');

  // Download
  downloadFile(content, generateFilename('timesheet', 'csv'));
  onProgress?.(100);
}

/**
 * Export shift history to CSV
 */
export function exportShiftHistoryToCsv(
  rows: Array<{
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
  }>,
  metadata: ExportMetadata,
  onProgress?: ProgressCallback
): void {
  const metadataLines = generateMetadataHeader(metadata);

  const headers = [
    'Nom de l\'employé',
    'Numéro d\'employé',
    'ID du quart',
    'Pointage arrivée',
    'Pointage départ',
    'Durée (heures)',
    'Statut',
    'Points GPS',
    'Lat arrivée',
    'Lng arrivée',
    'Lat départ',
    'Lng départ',
  ].join(',');

  const dataRows: string[] = [];

  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const dataRow = [
      escapeCsvField(row.employee_name),
      escapeCsvField(row.employee_identifier),
      row.shift_id,
      row.clocked_in_at ? format(new Date(row.clocked_in_at), 'yyyy-MM-dd HH:mm:ss') : '',
      row.clocked_out_at ? format(new Date(row.clocked_out_at), 'yyyy-MM-dd HH:mm:ss') : '',
      row.duration_minutes ? (row.duration_minutes / 60).toFixed(2) : '',
      row.status,
      row.gps_point_count.toString(),
      row.clock_in_latitude?.toFixed(8) || '',
      row.clock_in_longitude?.toFixed(8) || '',
      row.clock_out_latitude?.toFixed(8) || '',
      row.clock_out_longitude?.toFixed(8) || '',
    ].join(',');
    dataRows.push(dataRow);

    if (onProgress && i % CHUNK_SIZE === 0) {
      onProgress((i / rows.length) * 100);
    }
  }

  const content = [...metadataLines, headers, ...dataRows].join('\n');
  downloadFile(content, generateFilename('shift_history', 'csv'));
  onProgress?.(100);
}

/**
 * Export attendance report to CSV
 */
export function exportAttendanceToCsv(
  rows: Array<{
    employee_id: string;
    employee_name: string;
    total_working_days: number;
    days_worked: number;
    days_absent: number;
    attendance_rate: number;
    calendar_data?: Record<string, boolean>;
  }>,
  metadata: ExportMetadata,
  onProgress?: ProgressCallback
): void {
  const metadataLines = generateMetadataHeader(metadata);

  const headers = [
    'Nom de l\'employé',
    'Jours ouvrables totaux',
    'Jours travaillés',
    'Jours absents',
    'Taux de présence (%)',
  ].join(',');

  const dataRows: string[] = [];

  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const dataRow = [
      escapeCsvField(row.employee_name),
      row.total_working_days.toString(),
      row.days_worked.toString(),
      row.days_absent.toString(),
      row.attendance_rate.toFixed(2),
    ].join(',');
    dataRows.push(dataRow);

    if (onProgress && i % CHUNK_SIZE === 0) {
      onProgress((i / rows.length) * 100);
    }
  }

  const content = [...metadataLines, headers, ...dataRows].join('\n');
  downloadFile(content, generateFilename('attendance', 'csv'));
  onProgress?.(100);
}

/**
 * Export activity summary to CSV
 */
export function exportActivitySummaryToCsv(
  rows: Array<{
    period: string;
    total_hours: number;
    total_shifts: number;
    avg_hours_per_employee: number;
    employees_active: number;
    hours_by_day?: Record<string, number>;
  }>,
  metadata: ExportMetadata,
  onProgress?: ProgressCallback
): void {
  const metadataLines = generateMetadataHeader(metadata);

  const headers = [
    'Période',
    'Heures totales',
    'Quarts totaux',
    'Moy. heures/employé',
    'Employés actifs',
    'Heures lun',
    'Heures mar',
    'Heures mer',
    'Heures jeu',
    'Heures ven',
    'Heures sam',
    'Heures dim',
  ].join(',');

  const dataRows: string[] = [];

  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const hbd = row.hours_by_day || {};
    const dataRow = [
      row.period,
      row.total_hours.toFixed(2),
      row.total_shifts.toString(),
      row.avg_hours_per_employee.toFixed(2),
      row.employees_active.toString(),
      (hbd['Mon'] || 0).toFixed(2),
      (hbd['Tue'] || 0).toFixed(2),
      (hbd['Wed'] || 0).toFixed(2),
      (hbd['Thu'] || 0).toFixed(2),
      (hbd['Fri'] || 0).toFixed(2),
      (hbd['Sat'] || 0).toFixed(2),
      (hbd['Sun'] || 0).toFixed(2),
    ].join(',');
    dataRows.push(dataRow);

    if (onProgress && i % CHUNK_SIZE === 0) {
      onProgress((i / rows.length) * 100);
    }
  }

  const content = [...metadataLines, headers, ...dataRows].join('\n');
  downloadFile(content, generateFilename('activity_summary', 'csv'));
  onProgress?.(100);
}

/**
 * Check if export is large (>10,000 records)
 */
export function isLargeExport(recordCount: number): boolean {
  return recordCount > 10000;
}
