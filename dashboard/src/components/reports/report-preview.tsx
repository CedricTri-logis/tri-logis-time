'use client';

/**
 * Report Preview Component
 * Spec: 013-reports-export
 *
 * Shows a preview of the first 10 rows before generating the full report
 */

import { FileText, AlertCircle } from 'lucide-react';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Skeleton } from '@/components/ui/skeleton';
import { formatBytes } from '@/lib/validations/reports';
import type { ReportType, TimesheetReportRow } from '@/types/reports';

interface ReportPreviewProps {
  reportType: ReportType;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  data: any[];
  totalCount: number;
  isLoading?: boolean;
  error?: string | null;
}

// Maximum rows to show in preview
const PREVIEW_LIMIT = 10;

export function ReportPreview({
  reportType,
  data,
  totalCount,
  isLoading,
  error,
}: ReportPreviewProps) {
  if (isLoading) {
    return (
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2">
            <FileText className="h-5 w-5" />
            Loading Preview...
          </CardTitle>
        </CardHeader>
        <CardContent>
          <div className="space-y-3">
            {[...Array(5)].map((_, i) => (
              <Skeleton key={i} className="h-10 w-full" />
            ))}
          </div>
        </CardContent>
      </Card>
    );
  }

  if (error) {
    return (
      <Alert variant="destructive">
        <AlertCircle className="h-4 w-4" />
        <AlertTitle>Preview Error</AlertTitle>
        <AlertDescription>{error}</AlertDescription>
      </Alert>
    );
  }

  if (!data || data.length === 0) {
    return (
      <Alert>
        <AlertCircle className="h-4 w-4" />
        <AlertTitle>No Data</AlertTitle>
        <AlertDescription>
          No records found for the selected criteria. Try adjusting your filters.
        </AlertDescription>
      </Alert>
    );
  }

  const previewData = data.slice(0, PREVIEW_LIMIT);
  const hasMore = data.length > PREVIEW_LIMIT;

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2">
          <FileText className="h-5 w-5" />
          Report Preview
        </CardTitle>
        <CardDescription>
          Showing {previewData.length} of {totalCount.toLocaleString()} records
          {hasMore && ` (first ${PREVIEW_LIMIT} rows)`}
        </CardDescription>
      </CardHeader>
      <CardContent>
        {renderPreviewTable(reportType, previewData)}

        {hasMore && (
          <div className="mt-4 text-sm text-slate-500 text-center py-2 bg-slate-50 rounded-lg">
            {totalCount - PREVIEW_LIMIT} more rows not shown in preview
          </div>
        )}
      </CardContent>
    </Card>
  );
}

function renderPreviewTable(reportType: ReportType, data: unknown[]): JSX.Element {
  switch (reportType) {
    case 'timesheet':
      return renderTimesheetPreview(data as TimesheetReportRow[]);
    case 'shift_history':
      return renderShiftHistoryPreview(data);
    case 'activity_summary':
      return renderActivitySummaryPreview(data);
    case 'attendance':
      return renderAttendancePreview(data);
    default:
      return <div>Unknown report type</div>;
  }
}

function renderTimesheetPreview(data: TimesheetReportRow[]): JSX.Element {
  return (
    <div className="overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Employee</TableHead>
            <TableHead>Date</TableHead>
            <TableHead>Clock In</TableHead>
            <TableHead>Clock Out</TableHead>
            <TableHead className="text-right">Hours</TableHead>
            <TableHead>Status</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {data.map((row, index) => (
            <TableRow key={index}>
              <TableCell className="font-medium">
                {row.employee_name}
                {row.employee_identifier && (
                  <span className="text-slate-400 ml-1">({row.employee_identifier})</span>
                )}
              </TableCell>
              <TableCell>
                {row.shift_date
                  ? new Date(row.shift_date).toLocaleDateString()
                  : '-'}
              </TableCell>
              <TableCell>
                {row.clocked_in_at
                  ? new Date(row.clocked_in_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
                  : '-'}
              </TableCell>
              <TableCell>
                {row.clocked_out_at
                  ? new Date(row.clocked_out_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
                  : '-'}
              </TableCell>
              <TableCell className="text-right font-mono">
                {row.duration_minutes ? (row.duration_minutes / 60).toFixed(2) : '-'}
              </TableCell>
              <TableCell>
                <span
                  className={`inline-flex px-2 py-0.5 rounded-full text-xs font-medium ${
                    row.status === 'complete'
                      ? 'bg-green-100 text-green-800'
                      : 'bg-amber-100 text-amber-800'
                  }`}
                >
                  {row.status}
                </span>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}

function renderShiftHistoryPreview(data: unknown[]): JSX.Element {
  const rows = data as Array<{
    employee_name: string;
    shift_id: string;
    clocked_in_at: string;
    clocked_out_at?: string;
    duration_minutes?: number;
    gps_point_count: number;
  }>;

  return (
    <div className="overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Employee</TableHead>
            <TableHead>Clock In</TableHead>
            <TableHead>Clock Out</TableHead>
            <TableHead className="text-right">Hours</TableHead>
            <TableHead className="text-right">GPS Points</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row, index) => (
            <TableRow key={index}>
              <TableCell className="font-medium">{row.employee_name}</TableCell>
              <TableCell>
                {row.clocked_in_at ? new Date(row.clocked_in_at).toLocaleString() : '-'}
              </TableCell>
              <TableCell>
                {row.clocked_out_at ? new Date(row.clocked_out_at).toLocaleString() : '-'}
              </TableCell>
              <TableCell className="text-right font-mono">
                {row.duration_minutes ? (row.duration_minutes / 60).toFixed(2) : '-'}
              </TableCell>
              <TableCell className="text-right">{row.gps_point_count}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}

function renderActivitySummaryPreview(data: unknown[]): JSX.Element {
  const rows = data as Array<{
    period: string;
    total_hours: number;
    total_shifts: number;
    avg_hours_per_employee: number;
    employees_active: number;
  }>;

  return (
    <div className="overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Period</TableHead>
            <TableHead className="text-right">Total Hours</TableHead>
            <TableHead className="text-right">Total Shifts</TableHead>
            <TableHead className="text-right">Avg Hours/Emp</TableHead>
            <TableHead className="text-right">Active Employees</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row, index) => (
            <TableRow key={index}>
              <TableCell className="font-medium">{row.period}</TableCell>
              <TableCell className="text-right font-mono">{row.total_hours?.toFixed(2) || '0'}</TableCell>
              <TableCell className="text-right">{row.total_shifts || 0}</TableCell>
              <TableCell className="text-right font-mono">{row.avg_hours_per_employee?.toFixed(2) || '0'}</TableCell>
              <TableCell className="text-right">{row.employees_active || 0}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}

function renderAttendancePreview(data: unknown[]): JSX.Element {
  const rows = data as Array<{
    employee_name: string;
    total_working_days: number;
    days_worked: number;
    days_absent: number;
    attendance_rate: number;
  }>;

  return (
    <div className="overflow-x-auto">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Employee</TableHead>
            <TableHead className="text-right">Working Days</TableHead>
            <TableHead className="text-right">Days Worked</TableHead>
            <TableHead className="text-right">Days Absent</TableHead>
            <TableHead className="text-right">Attendance Rate</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((row, index) => (
            <TableRow key={index}>
              <TableCell className="font-medium">{row.employee_name}</TableCell>
              <TableCell className="text-right">{row.total_working_days}</TableCell>
              <TableCell className="text-right">{row.days_worked}</TableCell>
              <TableCell className="text-right">{row.days_absent}</TableCell>
              <TableCell className="text-right">
                <span
                  className={`font-mono ${
                    row.attendance_rate >= 90
                      ? 'text-green-600'
                      : row.attendance_rate >= 70
                      ? 'text-amber-600'
                      : 'text-red-600'
                  }`}
                >
                  {row.attendance_rate?.toFixed(1)}%
                </span>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
