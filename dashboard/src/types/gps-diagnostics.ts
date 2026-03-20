// =============================================================
// GPS Diagnostics Types
// Types for the /dashboard/diagnostics page
// =============================================================

// ---- Event classification ----

export type GpsEventType = 'gap' | 'service_died' | 'slc' | 'recovery' | 'lifecycle';
export type DiagnosticSeverity = 'info' | 'warn' | 'error' | 'critical';

// ---- Summary (KPI cards) ----

export interface GpsSummaryPeriod {
  gapsCount: number;
  serviceDiedCount: number;
  slcCount: number;
  recoveryCount: number;
  recoveryRate: number;
  medianGapMinutes: number;
  maxGapMinutes: number;
  maxGapEmployeeName: string | null;
  maxGapTime: string | null;
}

export interface GpsSummaryRow {
  primary: {
    gaps_count: number;
    service_died_count: number;
    slc_count: number;
    recovery_count: number;
    recovery_rate: number;
    median_gap_minutes: number;
    max_gap_minutes: number;
    max_gap_employee_name: string | null;
    max_gap_time: string | null;
  };
  comparison: {
    gaps_count: number;
    service_died_count: number;
    slc_count: number;
    recovery_count: number;
    recovery_rate: number;
    median_gap_minutes: number;
    max_gap_minutes: number;
  };
}

export function transformSummary(row: GpsSummaryRow): { primary: GpsSummaryPeriod; comparison: GpsSummaryPeriod } {
  const map = (r: GpsSummaryRow['primary'] | GpsSummaryRow['comparison']): GpsSummaryPeriod => ({
    gapsCount: r.gaps_count,
    serviceDiedCount: r.service_died_count,
    slcCount: r.slc_count,
    recoveryCount: r.recovery_count,
    recoveryRate: r.recovery_rate,
    medianGapMinutes: r.median_gap_minutes,
    maxGapMinutes: r.max_gap_minutes,
    maxGapEmployeeName: 'max_gap_employee_name' in r ? (r as GpsSummaryRow['primary']).max_gap_employee_name : null,
    maxGapTime: 'max_gap_time' in r ? (r as GpsSummaryRow['primary']).max_gap_time : null,
  });
  return { primary: map(row.primary), comparison: map(row.comparison) };
}

// ---- Trend (chart) ----

export interface GpsTrendRow {
  day: string;
  gaps_count: number;
  error_count: number;
  recovery_count: number;
}

export interface GpsTrendPoint {
  day: string;
  gapsCount: number;
  errorCount: number;
  recoveryCount: number;
}

export function transformTrendRow(row: GpsTrendRow): GpsTrendPoint {
  return {
    day: row.day,
    gapsCount: row.gaps_count,
    errorCount: row.error_count,
    recoveryCount: row.recovery_count,
  };
}

// ---- Ranking (employee list) ----

export interface GpsRankingRow {
  employee_id: string;
  full_name: string;
  device_platform: string | null;
  device_model: string | null;
  total_gaps: number;
  total_slc: number;
  total_service_died: number;
  total_recoveries: number;
}

export interface GpsRankedEmployee {
  employeeId: string;
  fullName: string;
  devicePlatform: string | null;
  deviceModel: string | null;
  totalGaps: number;
  totalSlc: number;
  totalServiceDied: number;
  totalRecoveries: number;
}

export function transformRankingRow(row: GpsRankingRow): GpsRankedEmployee {
  return {
    employeeId: row.employee_id,
    fullName: row.full_name,
    devicePlatform: row.device_platform,
    deviceModel: row.device_model,
    totalGaps: row.total_gaps,
    totalSlc: row.total_slc,
    totalServiceDied: row.total_service_died,
    totalRecoveries: row.total_recoveries,
  };
}

// ---- Feed (incident table) ----

export interface GpsFeedRow {
  id: string;
  created_at: string;
  employee_id: string;
  full_name: string;
  device_platform: string | null;
  device_model: string | null;
  message: string;
  event_type: GpsEventType;
  severity: DiagnosticSeverity;
  app_version: string | null;
  metadata: Record<string, unknown> | null;
}

export interface GpsFeedItem {
  id: string;
  createdAt: Date;
  employeeId: string;
  fullName: string;
  devicePlatform: string | null;
  deviceModel: string | null;
  message: string;
  eventType: GpsEventType;
  severity: DiagnosticSeverity;
  appVersion: string | null;
  metadata: Record<string, unknown> | null;
}

export function transformFeedRow(row: GpsFeedRow): GpsFeedItem {
  return {
    id: row.id,
    createdAt: new Date(row.created_at),
    employeeId: row.employee_id,
    fullName: row.full_name,
    devicePlatform: row.device_platform,
    deviceModel: row.device_model,
    message: row.message,
    eventType: row.event_type,
    severity: row.severity,
    appVersion: row.app_version,
    metadata: row.metadata,
  };
}

// ---- Employee GPS Gaps (drawer) ----

export interface GpsGapRow {
  shift_id: string;
  gap_start: string;
  gap_end: string;
  gap_minutes: number;
  shift_clocked_in_at: string;
}

export interface GpsGap {
  shiftId: string;
  gapStart: Date;
  gapEnd: Date;
  gapMinutes: number;
  shiftClockedInAt: Date;
}

export function transformGapRow(row: GpsGapRow): GpsGap {
  return {
    shiftId: row.shift_id,
    gapStart: new Date(row.gap_start),
    gapEnd: new Date(row.gap_end),
    gapMinutes: row.gap_minutes,
    shiftClockedInAt: new Date(row.shift_clocked_in_at),
  };
}

// ---- Employee Events (drawer timeline) ----

export interface GpsEventRow {
  id: string;
  created_at: string;
  event_category: string;
  severity: DiagnosticSeverity;
  message: string;
  metadata: Record<string, unknown> | null;
  app_version: string | null;
}

export interface GpsEvent {
  id: string;
  createdAt: Date;
  eventCategory: string;
  severity: DiagnosticSeverity;
  message: string;
  metadata: Record<string, unknown> | null;
  appVersion: string | null;
}

export function transformEventRow(row: GpsEventRow): GpsEvent {
  return {
    id: row.id,
    createdAt: new Date(row.created_at),
    eventCategory: row.event_category,
    severity: row.severity,
    message: row.message,
    metadata: row.metadata,
    appVersion: row.app_version,
  };
}

// ---- Drawer state ----

export interface DrawerState {
  isOpen: boolean;
  employeeId: string | null;
  employeeName: string | null;
  devicePlatform: string | null;
  deviceModel: string | null;
}

// ---- GPS Gaps By Day (diagnostics section) ----

export interface GpsGapByDayRow {
  day: string;
  employee_id: string;
  full_name: string;
  device_platform: string | null;
  device_model: string | null;
  shift_id: string;
  gap_start: string;
  gap_end: string;
  gap_minutes: number;
}

export interface GpsGapByDay {
  day: string;
  employeeId: string;
  fullName: string;
  devicePlatform: string | null;
  deviceModel: string | null;
  shiftId: string;
  gapStart: Date;
  gapEnd: Date;
  gapMinutes: number;
}

export function transformGapByDayRow(row: GpsGapByDayRow): GpsGapByDay {
  return {
    day: row.day,
    employeeId: row.employee_id,
    fullName: row.full_name,
    devicePlatform: row.device_platform,
    deviceModel: row.device_model,
    shiftId: row.shift_id,
    gapStart: new Date(row.gap_start),
    gapEnd: new Date(row.gap_end),
    gapMinutes: row.gap_minutes,
  };
}

// Grouped structure for the component
export interface GapsByDayGroup {
  day: string;
  totalGaps: number;
  totalEmployees: number;
  employees: GapsByEmployeeGroup[];
}

export interface GapsByEmployeeGroup {
  employeeId: string;
  fullName: string;
  devicePlatform: string | null;
  deviceModel: string | null;
  gaps: { gapStart: Date; gapEnd: Date; gapMinutes: number }[];
  totalMinutes: number;
}
