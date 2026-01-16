'use client';

/**
 * Timesheet Report Page
 * Spec: 013-reports-export - User Story 1
 *
 * Allows administrators to generate comprehensive timesheet reports
 * for pay period processing with PDF/CSV export options.
 */

import { useState, useEffect, useCallback } from 'react';
import { format, subMonths, startOfMonth, endOfMonth } from 'date-fns';
import { Clock, FileDown, RefreshCw } from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import { ReportConfigForm } from '@/components/reports/report-config-form';
import { ReportProgress } from '@/components/reports/report-progress';
import { ReportDownload } from '@/components/reports/report-download';
import { ReportPreview } from '@/components/reports/report-preview';
import { useReportGeneration } from '@/lib/hooks/use-report-generation';
import { supabaseClient } from '@/lib/supabase/client';
import { resolveDateRange } from '@/lib/validations/reports';
import { exportTimesheetToCsv } from '@/lib/utils/report-export';
import type { ReportConfigInput } from '@/lib/validations/reports';
import type { TimesheetReportRow, EmployeeOption } from '@/types/reports';

export default function TimesheetReportPage() {
  // State
  const [employees, setEmployees] = useState<EmployeeOption[]>([]);
  const [previewData, setPreviewData] = useState<TimesheetReportRow[]>([]);
  const [previewLoading, setPreviewLoading] = useState(false);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [totalRecords, setTotalRecords] = useState(0);
  const [lastConfig, setLastConfig] = useState<ReportConfigInput | null>(null);

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
    countRecords,
  } = useReportGeneration({
    onSuccess: (url) => {
      console.log('Report ready:', url);
    },
    onError: (err) => {
      console.error('Report error:', err);
    },
  });

  // Load supervised employees list
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
   * Load preview data based on config
   */
  const loadPreview = useCallback(async (config: ReportConfigInput) => {
    setPreviewLoading(true);
    setPreviewError(null);

    try {
      const { start, end } = resolveDateRange(config.date_range);

      // Parse employee filter
      let employeeIds: string[] | null = null;
      if (config.employee_filter !== 'all') {
        if (typeof config.employee_filter === 'string') {
          if (config.employee_filter.startsWith('employee:')) {
            employeeIds = [config.employee_filter.replace('employee:', '')];
          }
        } else if (Array.isArray(config.employee_filter)) {
          employeeIds = config.employee_filter;
        }
      }

      // Fetch preview data
      const { data, error } = await supabaseClient.rpc('get_timesheet_report_data', {
        p_start_date: start,
        p_end_date: end,
        p_employee_ids: employeeIds,
        p_include_incomplete: config.options?.include_incomplete_shifts ?? false,
      });

      if (error) throw new Error(error.message);

      const rows = (data || []) as TimesheetReportRow[];
      setPreviewData(rows);
      setTotalRecords(rows.length);
      setLastConfig(config);
    } catch (err) {
      setPreviewError(err instanceof Error ? err.message : 'Failed to load preview');
      setPreviewData([]);
    } finally {
      setPreviewLoading(false);
    }
  }, []);

  /**
   * Handle form submission
   */
  const handleSubmit = async (config: ReportConfigInput) => {
    setLastConfig(config);

    // If CSV format, export directly on client
    if (config.format === 'csv' && previewData.length > 0) {
      const { start, end } = resolveDateRange(config.date_range);
      exportTimesheetToCsv(previewData, {
        reportType: 'Timesheet',
        dateRange: `${start} to ${end}`,
        generatedAt: new Date().toISOString(),
        totalRecords: previewData.length,
      });
      return;
    }

    // For PDF, use server-side generation
    await generate('timesheet', {
      date_range: config.date_range,
      employee_filter: config.employee_filter,
      format: config.format,
      options: config.options,
    });
  };

  /**
   * Handle preview refresh
   */
  const handleRefreshPreview = () => {
    if (lastConfig) {
      loadPreview(lastConfig);
    }
  };

  const isGenerating = state === 'generating' || state === 'polling' || state === 'counting';

  return (
    <div className="space-y-6">
      {/* Page header */}
      <div>
        <h1 className="text-2xl font-bold text-slate-900 flex items-center gap-2">
          <Clock className="h-6 w-6" />
          Timesheet Report
        </h1>
        <p className="text-sm text-slate-500 mt-1">
          Generate comprehensive timesheet reports for pay period processing
        </p>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        {/* Configuration Panel */}
        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle>Report Configuration</CardTitle>
              <CardDescription>
                Select the date range, employees, and export format
              </CardDescription>
            </CardHeader>
            <CardContent>
              <ReportConfigForm
                onSubmit={handleSubmit}
                isLoading={isGenerating}
                employees={employees}
                showEmployeeFilter={true}
                showIncompleteOption={true}
                showGroupByOption={true}
                defaultFormat="pdf"
                submitLabel="Generate Timesheet Report"
              />
            </CardContent>
          </Card>

          {/* Preview Button */}
          <Button
            variant="outline"
            onClick={() => lastConfig && loadPreview(lastConfig)}
            disabled={previewLoading || !lastConfig}
            className="w-full"
          >
            <RefreshCw className={`mr-2 h-4 w-4 ${previewLoading ? 'animate-spin' : ''}`} />
            {previewLoading ? 'Loading Preview...' : 'Preview Report Data'}
          </Button>
        </div>

        {/* Results Panel */}
        <div className="space-y-6">
          {/* Progress indicator */}
          {state !== 'idle' && state !== 'completed' && (
            <ReportProgress
              state={state}
              progress={progress}
              error={error}
              recordCount={recordCount}
              isAsync={isAsync}
              onRetry={() => lastConfig && handleSubmit(lastConfig)}
            />
          )}

          {/* Download card */}
          {state === 'completed' && downloadUrl && (
            <ReportDownload
              downloadUrl={downloadUrl}
              reportType="timesheet"
              format="pdf"
              fileSize={recordCount ? recordCount * 100 : undefined}
              recordCount={recordCount || undefined}
            />
          )}

          {/* Preview */}
          {previewData.length > 0 || previewLoading || previewError ? (
            <ReportPreview
              reportType="timesheet"
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
                  No Preview Data
                </h3>
                <p className="text-sm text-slate-500 max-w-sm">
                  Configure your report options and click &quot;Preview Report Data&quot; to see
                  a sample of the data that will be included.
                </p>
              </CardContent>
            </Card>
          )}
        </div>
      </div>

      {/* Help text */}
      <Alert>
        <Clock className="h-4 w-4" />
        <AlertTitle>About Timesheet Reports</AlertTitle>
        <AlertDescription>
          <ul className="list-disc list-inside mt-2 space-y-1 text-sm">
            <li>PDF reports are formatted for printing and include summary statistics</li>
            <li>CSV exports can be opened in Excel or Google Sheets for further analysis</li>
            <li>Reports exceeding 1,000 records are processed in the background</li>
            <li>Generated reports are available for 30 days in your report history</li>
          </ul>
        </AlertDescription>
      </Alert>
    </div>
  );
}
