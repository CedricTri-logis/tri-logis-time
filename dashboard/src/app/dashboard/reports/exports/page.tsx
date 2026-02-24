'use client';

/**
 * Shift History Export Page
 * Spec: 013-reports-export - User Story 2
 *
 * Allows supervisors/admins to export detailed shift history
 * for individual or multiple employees.
 */

import { useState, useEffect, useCallback } from 'react';
import { format, subDays } from 'date-fns';
import { FileDown, Download, RefreshCw } from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { Label } from '@/components/ui/label';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { ReportProgress } from '@/components/reports/report-progress';
import { ReportDownload } from '@/components/reports/report-download';
import { ReportPreview } from '@/components/reports/report-preview';
import { EmployeeSelector } from '@/components/reports/employee-selector';
import { useReportGeneration } from '@/lib/hooks/use-report-generation';
import { supabaseClient } from '@/lib/supabase/client';
import { exportShiftHistoryToCsv } from '@/lib/utils/report-export';
import type { EmployeeOption, ShiftHistoryExportRow } from '@/types/reports';

export default function ShiftHistoryExportPage() {
  // State
  const [employees, setEmployees] = useState<EmployeeOption[]>([]);
  const [selectedEmployeeIds, setSelectedEmployeeIds] = useState<string[]>([]);
  const [startDate, setStartDate] = useState(format(subDays(new Date(), 30), 'yyyy-MM-dd'));
  const [endDate, setEndDate] = useState(format(new Date(), 'yyyy-MM-dd'));
  const [exportFormat, setExportFormat] = useState<'pdf' | 'csv'>('csv');

  const [previewData, setPreviewData] = useState<ShiftHistoryExportRow[]>([]);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [totalRecords, setTotalRecords] = useState(0);

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
   * Load preview data
   */
  const loadPreview = useCallback(async () => {
    if (selectedEmployeeIds.length === 0) {
      setPreviewData([]);
      return;
    }

    setPreviewLoading(true);
    setPreviewError(null);

    try {
      const { data, error } = await supabaseClient.rpc('get_shift_history_export_data', {
        p_start_date: startDate,
        p_end_date: endDate,
        p_employee_ids: selectedEmployeeIds,
      });

      if (error) throw new Error(error.message);

      const rows = (data || []) as ShiftHistoryExportRow[];
      setPreviewData(rows);
      setTotalRecords(rows.length);
    } catch (err) {
      setPreviewError(err instanceof Error ? err.message : 'Failed to load preview');
      setPreviewData([]);
    } finally {
      setPreviewLoading(false);
    }
  }, [selectedEmployeeIds, startDate, endDate]);

  /**
   * Handle export
   */
  const handleExport = async () => {
    if (selectedEmployeeIds.length === 0) {
      return;
    }

    // For CSV, export directly on client side
    if (exportFormat === 'csv' && previewData.length > 0) {
      exportShiftHistoryToCsv(previewData, {
        reportType: 'Shift History',
        dateRange: `${startDate} to ${endDate}`,
        generatedAt: new Date().toISOString(),
        totalRecords: previewData.length,
      });
      return;
    }

    // For PDF or if no preview data, use server-side generation
    await generate('shift_history', {
      date_range: {
        start: startDate,
        end: endDate,
      },
      employee_filter: selectedEmployeeIds,
      format: exportFormat,
    });
  };

  const isGenerating = state === 'generating' || state === 'polling';
  const canExport = selectedEmployeeIds.length > 0;

  return (
    <div className="space-y-6">
      {/* Page header */}
      <div>
        <h1 className="text-2xl font-bold text-slate-900 flex items-center gap-2">
          <FileDown className="h-6 w-6" />
          Shift History Export
        </h1>
        <p className="text-sm text-slate-500 mt-1">
          Export detailed shift records with GPS data for individual or multiple employees
        </p>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        {/* Configuration Panel */}
        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle>Export Configuration</CardTitle>
              <CardDescription>
                Select employees and date range for the export
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-6">
              {/* Employee selector */}
              <div className="space-y-2">
                <Label>Employees</Label>
                <EmployeeSelector
                  employees={employees}
                  selectedIds={selectedEmployeeIds}
                  onChange={setSelectedEmployeeIds}
                  placeholder="Select employees to export..."
                  maxSelected={50}
                />
                <p className="text-xs text-slate-500">
                  Select up to 50 employees for bulk export
                </p>
              </div>

              {/* Date range */}
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
                    <SelectItem value="csv">
                      CSV - Spreadsheet format for Excel/Sheets
                    </SelectItem>
                    <SelectItem value="pdf">
                      PDF - Formatted document for printing
                    </SelectItem>
                  </SelectContent>
                </Select>
              </div>

              {/* Action buttons */}
              <div className="flex gap-2">
                <Button
                  variant="outline"
                  onClick={loadPreview}
                  disabled={previewLoading || selectedEmployeeIds.length === 0}
                  className="flex-1"
                >
                  <RefreshCw className={`mr-2 h-4 w-4 ${previewLoading ? 'animate-spin' : ''}`} />
                  {previewLoading ? 'Loading...' : 'Preview Data'}
                </Button>
                <Button
                  onClick={handleExport}
                  disabled={isGenerating || !canExport}
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
              reportType="shift_history"
              format={exportFormat}
              recordCount={recordCount || undefined}
            />
          )}

          {/* Preview */}
          {previewData.length > 0 || previewLoading || previewError ? (
            <ReportPreview
              reportType="shift_history"
              data={previewData}
              totalCount={totalRecords}
              isLoading={previewLoading}
              error={previewError}
            />
          ) : (
            <Card className="border-dashed">
              <CardContent className="flex flex-col items-center justify-center py-12 text-center">
                <FileDown className="h-12 w-12 text-slate-300 mb-4" />
                <h3 className="text-lg font-medium text-slate-900 mb-1">
                  {selectedEmployeeIds.length === 0
                    ? 'Select Employees'
                    : 'No Preview Data'}
                </h3>
                <p className="text-sm text-slate-500 max-w-sm">
                  {selectedEmployeeIds.length === 0
                    ? 'Choose one or more employees from the list to export their shift history.'
                    : 'Click "Preview Data" to see a sample of the export data.'}
                </p>
              </CardContent>
            </Card>
          )}
        </div>
      </div>

      {/* Help text */}
      <Alert>
        <FileDown className="h-4 w-4" />
        <AlertTitle>About Shift History Exports</AlertTitle>
        <AlertDescription>
          <ul className="list-disc list-inside mt-2 space-y-1 text-sm">
            <li>CSV exports include all shift details and GPS coordinates</li>
            <li>PDF exports group shifts by employee with summary statistics</li>
            <li>GPS data is available for shifts within the 90-day retention period</li>
            <li>Select multiple employees for bulk export (up to 50 at once)</li>
          </ul>
        </AlertDescription>
      </Alert>
    </div>
  );
}
