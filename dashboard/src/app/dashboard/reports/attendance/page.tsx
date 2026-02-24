'use client';

/**
 * Attendance Report Page
 * Spec: 013-reports-export - User Story 4
 *
 * Allows administrators to generate attendance reports showing
 * presence, absences, and attendance patterns.
 */

import { useState, useEffect, useCallback } from 'react';
import { format, subMonths, startOfMonth, endOfMonth, subDays } from 'date-fns';
import { CalendarCheck, FileDown, RefreshCw, Download, Users, CheckCircle, XCircle } from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Label } from '@/components/ui/label';
import { Input } from '@/components/ui/input';
import { Progress } from '@/components/ui/progress';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { ReportProgress } from '@/components/reports/report-progress';
import { ReportDownload } from '@/components/reports/report-download';
import { EmployeeSelector } from '@/components/reports/employee-selector';
import { useReportGeneration } from '@/lib/hooks/use-report-generation';
import { supabaseClient } from '@/lib/supabase/client';
import { exportAttendanceToCsv } from '@/lib/utils/report-export';
import type { AttendanceReportRow, EmployeeOption } from '@/types/reports';

// Date range preset options
const DATE_PRESETS = [
  { value: 'last_7_days', label: 'Last 7 Days' },
  { value: 'last_30_days', label: 'Last 30 Days' },
  { value: 'this_month', label: 'This Month' },
  { value: 'last_month', label: 'Last Month' },
  { value: 'custom', label: 'Custom Range' },
] as const;

type DatePreset = typeof DATE_PRESETS[number]['value'];

/**
 * Get rate color class based on attendance percentage
 */
function getRateColorClass(rate: number): string {
  if (rate >= 95) return 'text-green-600';
  if (rate >= 85) return 'text-lime-600';
  if (rate >= 75) return 'text-yellow-600';
  if (rate >= 60) return 'text-orange-600';
  return 'text-red-600';
}

function getRateBgClass(rate: number): string {
  if (rate >= 95) return 'bg-green-500';
  if (rate >= 85) return 'bg-lime-500';
  if (rate >= 75) return 'bg-yellow-500';
  if (rate >= 60) return 'bg-orange-500';
  return 'bg-red-500';
}

export default function AttendanceReportPage() {
  // State
  const [employees, setEmployees] = useState<EmployeeOption[]>([]);
  const [selectedEmployeeIds, setSelectedEmployeeIds] = useState<string[]>([]);
  const [datePreset, setDatePreset] = useState<DatePreset>('last_month');
  const [startDate, setStartDate] = useState(() => {
    const lastMonth = subMonths(new Date(), 1);
    return format(startOfMonth(lastMonth), 'yyyy-MM-dd');
  });
  const [endDate, setEndDate] = useState(() => {
    const lastMonth = subMonths(new Date(), 1);
    return format(endOfMonth(lastMonth), 'yyyy-MM-dd');
  });
  const [exportFormat, setExportFormat] = useState<'pdf' | 'csv'>('pdf');

  const [attendanceData, setAttendanceData] = useState<AttendanceReportRow[]>([]);
  const [dataLoading, setDataLoading] = useState(false);
  const [dataError, setDataError] = useState<string | null>(null);

  // Report generation hook
  const {
    generate,
    state,
    progress,
    error,
    downloadUrl,
    recordCount,
    isAsync,
    reset,
  } = useReportGeneration();

  // Load employees
  useEffect(() => {
    async function loadEmployees() {
      const { data, error } = await supabaseClient.rpc('get_supervised_employees_list');
      if (data && !error) {
        setEmployees(data as EmployeeOption[]);
      }
    }
    loadEmployees();
  }, []);

  /**
   * Get resolved date range based on preset
   */
  const getDateRange = useCallback(() => {
    const now = new Date();

    switch (datePreset) {
      case 'last_7_days':
        return {
          start: format(subDays(now, 7), 'yyyy-MM-dd'),
          end: format(now, 'yyyy-MM-dd'),
        };
      case 'last_30_days':
        return {
          start: format(subDays(now, 30), 'yyyy-MM-dd'),
          end: format(now, 'yyyy-MM-dd'),
        };
      case 'this_month':
        return {
          start: format(startOfMonth(now), 'yyyy-MM-dd'),
          end: format(now, 'yyyy-MM-dd'),
        };
      case 'last_month':
        const lastMonth = subMonths(now, 1);
        return {
          start: format(startOfMonth(lastMonth), 'yyyy-MM-dd'),
          end: format(endOfMonth(lastMonth), 'yyyy-MM-dd'),
        };
      case 'custom':
      default:
        return { start: startDate, end: endDate };
    }
  }, [datePreset, startDate, endDate]);

  /**
   * Handle preset change
   */
  const handlePresetChange = (value: string) => {
    setDatePreset(value as DatePreset);

    // Update date inputs to reflect the preset
    const now = new Date();
    switch (value) {
      case 'last_7_days':
        setStartDate(format(subDays(now, 7), 'yyyy-MM-dd'));
        setEndDate(format(now, 'yyyy-MM-dd'));
        break;
      case 'last_30_days':
        setStartDate(format(subDays(now, 30), 'yyyy-MM-dd'));
        setEndDate(format(now, 'yyyy-MM-dd'));
        break;
      case 'this_month':
        setStartDate(format(startOfMonth(now), 'yyyy-MM-dd'));
        setEndDate(format(now, 'yyyy-MM-dd'));
        break;
      case 'last_month':
        const lastMonth = subMonths(now, 1);
        setStartDate(format(startOfMonth(lastMonth), 'yyyy-MM-dd'));
        setEndDate(format(endOfMonth(lastMonth), 'yyyy-MM-dd'));
        break;
    }
  };

  /**
   * Load attendance data
   */
  const loadData = useCallback(async () => {
    setDataLoading(true);
    setDataError(null);

    try {
      const range = getDateRange();

      const { data, error } = await supabaseClient.rpc('get_attendance_report_data', {
        p_start_date: range.start,
        p_end_date: range.end,
        p_employee_ids: selectedEmployeeIds.length > 0 ? selectedEmployeeIds : null,
      });

      if (error) throw new Error(error.message);

      const rows = (data || []) as AttendanceReportRow[];
      setAttendanceData(rows);
    } catch (err) {
      setDataError(err instanceof Error ? err.message : 'Failed to load data');
      setAttendanceData([]);
    } finally {
      setDataLoading(false);
    }
  }, [getDateRange, selectedEmployeeIds]);

  /**
   * Handle export
   */
  const handleExport = async () => {
    const range = getDateRange();

    // For CSV, export directly on client side
    if (exportFormat === 'csv' && attendanceData.length > 0) {
      exportAttendanceToCsv(attendanceData, {
        reportType: 'Attendance',
        dateRange: `${range.start} to ${range.end}`,
        generatedAt: new Date().toISOString(),
        totalRecords: attendanceData.length,
      });
      return;
    }

    // For PDF, use server-side generation
    await generate('attendance', {
      date_range: {
        start: range.start,
        end: range.end,
      },
      employee_filter: selectedEmployeeIds.length > 0 ? selectedEmployeeIds : 'all',
      format: exportFormat,
    });
  };

  // Calculate summary metrics
  const summaryMetrics = attendanceData.reduce(
    (acc, row) => {
      acc.totalEmployees += 1;
      acc.totalDaysWorked += row.days_worked;
      acc.totalDaysAbsent += row.days_absent;
      acc.avgRate += row.attendance_rate || 0;
      return acc;
    },
    { totalEmployees: 0, totalDaysWorked: 0, totalDaysAbsent: 0, avgRate: 0 }
  );

  if (summaryMetrics.totalEmployees > 0) {
    summaryMetrics.avgRate /= summaryMetrics.totalEmployees;
  }

  const workingDays = attendanceData.length > 0 ? attendanceData[0].total_working_days : 0;
  const isGenerating = state === 'generating' || state === 'polling';

  return (
    <div className="space-y-6">
      {/* Page header */}
      <div>
        <h1 className="text-2xl font-bold text-slate-900 flex items-center gap-2">
          <CalendarCheck className="h-6 w-6" />
          Attendance Report
        </h1>
        <p className="text-sm text-slate-500 mt-1">
          Generate attendance reports showing presence, absences, and patterns
        </p>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        {/* Configuration Panel */}
        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle>Report Configuration</CardTitle>
              <CardDescription>
                Select date range and employees to include
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-6">
              {/* Date range preset */}
              <div className="space-y-2">
                <Label>Date Range</Label>
                <Select value={datePreset} onValueChange={handlePresetChange}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {DATE_PRESETS.map((preset) => (
                      <SelectItem key={preset.value} value={preset.value}>
                        {preset.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>

              {/* Custom date inputs */}
              {datePreset === 'custom' && (
                <div className="grid gap-4 sm:grid-cols-2">
                  <div className="space-y-2">
                    <Label htmlFor="start-date">Start Date</Label>
                    <Input
                      id="start-date"
                      type="date"
                      value={startDate}
                      onChange={(e) => setStartDate(e.target.value)}
                      max={endDate}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="end-date">End Date</Label>
                    <Input
                      id="end-date"
                      type="date"
                      value={endDate}
                      onChange={(e) => setEndDate(e.target.value)}
                      min={startDate}
                      max={format(new Date(), 'yyyy-MM-dd')}
                    />
                  </div>
                </div>
              )}

              {/* Employee selector */}
              <div className="space-y-2">
                <Label>Employees (optional)</Label>
                <EmployeeSelector
                  employees={employees}
                  selectedIds={selectedEmployeeIds}
                  onChange={setSelectedEmployeeIds}
                  placeholder="All employees"
                  maxSelected={50}
                />
                <p className="text-xs text-slate-500">
                  Leave empty to include all employees
                </p>
              </div>

              {/* Format selection */}
              <div className="space-y-2">
                <Label>Export Format</Label>
                <Select
                  value={exportFormat}
                  onValueChange={(v) => setExportFormat(v as 'pdf' | 'csv')}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="pdf">
                      PDF - Formatted report with charts
                    </SelectItem>
                    <SelectItem value="csv">
                      CSV - Spreadsheet format for Excel/Sheets
                    </SelectItem>
                  </SelectContent>
                </Select>
              </div>

              {/* Action buttons */}
              <div className="flex gap-2">
                <Button
                  variant="outline"
                  onClick={loadData}
                  disabled={dataLoading}
                  className="flex-1"
                >
                  <RefreshCw className={`mr-2 h-4 w-4 ${dataLoading ? 'animate-spin' : ''}`} />
                  {dataLoading ? 'Loading...' : 'Load Data'}
                </Button>
                <Button
                  onClick={handleExport}
                  disabled={isGenerating || attendanceData.length === 0}
                  className="flex-1"
                >
                  <Download className="mr-2 h-4 w-4" />
                  Export {exportFormat.toUpperCase()}
                </Button>
              </div>
            </CardContent>
          </Card>
        </div>

        {/* Results Panel */}
        <div className="space-y-6">
          {/* Progress */}
          {state !== 'idle' && state !== 'completed' && (
            <ReportProgress
              state={state}
              progress={progress}
              error={error}
              recordCount={recordCount}
              isAsync={isAsync}
            />
          )}

          {/* Download */}
          {state === 'completed' && downloadUrl && (
            <ReportDownload
              downloadUrl={downloadUrl}
              reportType="attendance"
              format={exportFormat}
              recordCount={recordCount || undefined}
            />
          )}

          {/* Summary and Data */}
          {attendanceData.length > 0 ? (
            <Card>
              <CardHeader>
                <CardTitle>Attendance Summary</CardTitle>
                <CardDescription>
                  {getDateRange().start} to {getDateRange().end}
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-6">
                {/* Summary metrics */}
                <div className="grid grid-cols-2 gap-4">
                  <div className="rounded-lg bg-slate-50 p-4">
                    <div className="flex items-center gap-2 text-slate-600 mb-1">
                      <Users className="h-4 w-4" />
                      <span className="text-sm font-medium">Employees</span>
                    </div>
                    <p className="text-2xl font-bold text-slate-900">
                      {summaryMetrics.totalEmployees}
                    </p>
                  </div>
                  <div className="rounded-lg bg-slate-50 p-4">
                    <div className="flex items-center gap-2 text-slate-600 mb-1">
                      <CalendarCheck className="h-4 w-4" />
                      <span className="text-sm font-medium">Working Days</span>
                    </div>
                    <p className="text-2xl font-bold text-slate-900">
                      {workingDays}
                    </p>
                  </div>
                  <div className="rounded-lg bg-green-50 p-4">
                    <div className="flex items-center gap-2 text-green-600 mb-1">
                      <CheckCircle className="h-4 w-4" />
                      <span className="text-sm font-medium">Days Worked</span>
                    </div>
                    <p className="text-2xl font-bold text-green-900">
                      {summaryMetrics.totalDaysWorked}
                    </p>
                  </div>
                  <div className="rounded-lg bg-red-50 p-4">
                    <div className="flex items-center gap-2 text-red-600 mb-1">
                      <XCircle className="h-4 w-4" />
                      <span className="text-sm font-medium">Days Absent</span>
                    </div>
                    <p className="text-2xl font-bold text-red-900">
                      {summaryMetrics.totalDaysAbsent}
                    </p>
                  </div>
                </div>

                {/* Average attendance */}
                <div className="rounded-lg border p-4">
                  <div className="flex justify-between items-center mb-2">
                    <span className="text-sm font-medium text-slate-700">
                      Average Attendance Rate
                    </span>
                    <span className={`text-lg font-bold ${getRateColorClass(summaryMetrics.avgRate)}`}>
                      {summaryMetrics.avgRate.toFixed(1)}%
                    </span>
                  </div>
                  <Progress
                    value={summaryMetrics.avgRate}
                    className="h-2"
                  />
                </div>

                {/* Employee breakdown */}
                <div>
                  <h4 className="text-sm font-medium text-slate-700 mb-3">
                    Employee Breakdown
                  </h4>
                  <div className="space-y-2 max-h-64 overflow-y-auto">
                    {attendanceData.map((row) => (
                      <div
                        key={row.employee_id}
                        className="flex items-center justify-between p-2 rounded-lg hover:bg-slate-50"
                      >
                        <span className="text-sm text-slate-900 truncate flex-1">
                          {row.employee_name}
                        </span>
                        <div className="flex items-center gap-3">
                          <span className="text-xs text-slate-500">
                            {row.days_worked}/{row.total_working_days}
                          </span>
                          <div className="w-16 h-1.5 bg-slate-200 rounded-full overflow-hidden">
                            <div
                              className={`h-full rounded-full ${getRateBgClass(row.attendance_rate)}`}
                              style={{ width: `${row.attendance_rate}%` }}
                            />
                          </div>
                          <span className={`text-sm font-medium w-14 text-right ${getRateColorClass(row.attendance_rate)}`}>
                            {row.attendance_rate.toFixed(0)}%
                          </span>
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              </CardContent>
            </Card>
          ) : dataLoading ? (
            <Card>
              <CardContent className="flex flex-col items-center justify-center py-12">
                <RefreshCw className="h-8 w-8 text-slate-400 animate-spin mb-4" />
                <p className="text-slate-500">Loading attendance data...</p>
              </CardContent>
            </Card>
          ) : dataError ? (
            <Alert variant="destructive">
              <AlertTitle>Error Loading Data</AlertTitle>
              <AlertDescription>{dataError}</AlertDescription>
            </Alert>
          ) : (
            <Card className="border-dashed">
              <CardContent className="flex flex-col items-center justify-center py-12 text-center">
                <CalendarCheck className="h-12 w-12 text-slate-300 mb-4" />
                <h3 className="text-lg font-medium text-slate-900 mb-1">
                  No Data Loaded
                </h3>
                <p className="text-sm text-slate-500 max-w-sm">
                  Select a date range and click &quot;Load Data&quot; to see attendance
                  information.
                </p>
              </CardContent>
            </Card>
          )}
        </div>
      </div>

      {/* Help text */}
      <Alert>
        <CalendarCheck className="h-4 w-4" />
        <AlertTitle>About Attendance Reports</AlertTitle>
        <AlertDescription>
          <ul className="list-disc list-inside mt-2 space-y-1 text-sm">
            <li>Attendance is calculated based on completed shifts (clock in and out)</li>
            <li>Working days exclude weekends (Saturday and Sunday)</li>
            <li>PDF reports include visual attendance rate indicators</li>
            <li>CSV exports include detailed daily breakdown</li>
          </ul>
        </AlertDescription>
      </Alert>
    </div>
  );
}
