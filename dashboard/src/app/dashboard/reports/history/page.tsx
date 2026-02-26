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
  { value: 'all', label: 'Tous les types de rapports' },
  { value: 'timesheet', label: 'Rapports de feuille de temps' },
  { value: 'activity_summary', label: 'Résumé d\'activité' },
  { value: 'attendance', label: 'Rapports de présence' },
  { value: 'shift_history', label: 'Historique des quarts' },
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
            Historique des rapports
          </h1>
          <p className="text-sm text-slate-500 mt-1">
            Consultez et téléchargez les rapports générés précédemment
          </p>
        </div>

        <Button variant="outline" onClick={handleRefresh} disabled={isLoading}>
          <RefreshCw className={`mr-2 h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
          Actualiser
        </Button>
      </div>

      {/* Filters */}
      <Card>
        <CardContent className="py-4">
          <div className="flex items-center gap-4">
            <div className="flex items-center gap-2">
              <Filter className="h-4 w-4 text-slate-500" />
              <span className="text-sm font-medium text-slate-700">Filtrer :</span>
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
              {totalCount > 0 && `${totalCount} rapport${totalCount !== 1 ? 's' : ''} trouvé${totalCount !== 1 ? 's' : ''}`}
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Error state */}
      {error && (
        <Alert variant="destructive">
          <AlertTitle>Erreur</AlertTitle>
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      {/* History table */}
      <Card>
        <CardHeader>
          <CardTitle>Rapports générés</CardTitle>
          <CardDescription>
            Les rapports sont disponibles au téléchargement pendant 30 jours après leur génération
          </CardDescription>
        </CardHeader>
        <CardContent>
          <ReportHistoryTable items={items} isLoading={isLoading} onRefresh={handleRefresh} />

          {/* Load more */}
          {hasMore && !isLoading && (
            <div className="mt-4 flex justify-center">
              <Button variant="outline" onClick={handleLoadMore}>
                Charger plus
              </Button>
            </div>
          )}
        </CardContent>
      </Card>

      {/* Help text */}
      <Alert>
        <History className="h-4 w-4" />
        <AlertTitle>À propos de l&apos;historique des rapports</AlertTitle>
        <AlertDescription>
          <ul className="list-disc list-inside mt-2 space-y-1 text-sm">
            <li>Les rapports générés sont conservés pendant 30 jours</li>
            <li>Cliquez sur le bouton de téléchargement pour re-télécharger un rapport disponible</li>
            <li>Les rapports expirés ne peuvent pas être re-téléchargés - générez un nouveau rapport</li>
            <li>Les rapports programmés apparaissent ici une fois terminés</li>
          </ul>
        </AlertDescription>
      </Alert>
    </div>
  );
}
