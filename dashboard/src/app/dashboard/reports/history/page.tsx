'use client';

/**
 * Report History Page
 * Spec: 013-reports-export - Phase 8
 *
 * Displays history of generated reports with re-download capability
 */

import { useState, useEffect, useCallback } from 'react';

import { History, RefreshCw, Filter } from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { ReportHistoryTable } from '@/components/reports/report-history-table';
import { useReportHistory } from '@/lib/hooks/use-report-history';
import type { ReportType } from '@/types/reports';

// Filter options
const REPORT_TYPE_OPTIONS: { value: ReportType | 'all'; label: string }[] = [
  { value: 'all', label: 'All Report Types' },
  { value: 'timesheet', label: 'Timesheet Reports' },
  { value: 'activity_summary', label: 'Activity Summary' },
  { value: 'attendance', label: 'Attendance Reports' },
  { value: 'shift_history', label: 'Shift History' },
];

const PAGE_SIZE = 20;

export default function ReportHistoryPage() {
  const [reportTypeFilter, setReportTypeFilter] = useState<ReportType | 'all'>('all');

  const { items, isLoading, error, totalCount, hasMore, loadPage, loadMore, refresh } = useReportHistory({
    pageSize: PAGE_SIZE,
    reportType: reportTypeFilter === 'all' ? undefined : reportTypeFilter,
  });

  // Load data on mount and filter change
  useEffect(() => {
    loadPage(0);
  }, [loadPage]);

  // Handle load more
  const handleLoadMore = useCallback(() => {
    loadMore();
  }, [loadMore]);

  // Handle refresh
  const handleRefresh = useCallback(() => {
    refresh();
  }, [refresh]);

  return (
    <div className="space-y-6">
      {/* Page header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 flex items-center gap-2">
            <History className="h-6 w-6" />
            Report History
          </h1>
          <p className="text-sm text-slate-500 mt-1">
            View and download previously generated reports
          </p>
        </div>

        <Button variant="outline" onClick={handleRefresh} disabled={isLoading}>
          <RefreshCw className={`mr-2 h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
          Refresh
        </Button>
      </div>

      {/* Filters */}
      <Card>
        <CardContent className="py-4">
          <div className="flex items-center gap-4">
            <div className="flex items-center gap-2">
              <Filter className="h-4 w-4 text-slate-500" />
              <span className="text-sm font-medium text-slate-700">Filter:</span>
            </div>
            <Select
              value={reportTypeFilter}
              onValueChange={(value) => setReportTypeFilter(value as ReportType | 'all')}
            >
              <SelectTrigger className="w-48">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {REPORT_TYPE_OPTIONS.map((option) => (
                  <SelectItem key={option.value} value={option.value}>
                    {option.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>

            <div className="flex-1 text-right text-sm text-slate-500">
              {totalCount > 0 && `${totalCount} report${totalCount !== 1 ? 's' : ''} found`}
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Error state */}
      {error && (
        <Alert variant="destructive">
          <AlertTitle>Error</AlertTitle>
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      {/* History table */}
      <Card>
        <CardHeader>
          <CardTitle>Generated Reports</CardTitle>
          <CardDescription>
            Reports are available for download for 30 days after generation
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ReportHistoryTable items={items} isLoading={isLoading} onRefresh={handleRefresh} />

          {/* Load more */}
          {hasMore && !isLoading && (
            <div className="mt-4 flex justify-center">
              <Button variant="outline" onClick={handleLoadMore}>
                Load More
              </Button>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Help text */}
      <Alert>
        <History className="h-4 w-4" />
        <AlertTitle>About Report History</AlertTitle>
        <AlertDescription>
          <ul className="list-disc list-inside mt-2 space-y-1 text-sm">
            <li>Generated reports are stored for 30 days</li>
            <li>Click the download button to re-download any available report</li>
            <li>Expired reports cannot be re-downloaded - generate a new report instead</li>
            <li>Scheduled reports appear here when they complete</li>
          </ul>
        </AlertDescription>
      </Alert>
    </div>
  );
}
