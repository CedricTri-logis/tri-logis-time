'use client';

/**
 * Team Activity Summary Page
 * Spec: 013-reports-export - User Story 3
 *
 * Allows managers/admins to generate aggregate team metrics
 * for planning and reporting purposes.
 */

import { useState, useCallback } from 'react';
import { format, subMonths, startOfMonth, endOfMonth, subDays } from 'date-fns';
import { BarChart3, FileDown, RefreshCw, Download, TrendingUp, Users, Clock } from 'lucide-react';
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
import { useReportGeneration } from '@/lib/hooks/use-report-generation';
import { supabaseClient } from '@/lib/supabase/client';
import { exportActivitySummaryToCsv } from '@/lib/utils/report-export';
import type { ActivitySummaryData } from '@/types/reports';

// Date range preset options
const DATE_PRESETS = [
  { value: 'last_7_days', label: '7 derniers jours' },
  { value: 'last_30_days', label: '30 derniers jours' },
  { value: 'this_month', label: 'Ce mois-ci' },
  { value: 'last_month', label: 'Mois dernier' },
  { value: 'custom', label: 'Plage personnalisée' },
] as const;

type DatePreset = typeof DATE_PRESETS[number]['value'];

export default function TeamActivitySummaryPage() {
  // State
  const [datePreset, setDatePreset] = useState<DatePreset>('last_30_days');
  const [startDate, setStartDate] = useState(format(subDays(new Date(), 30), 'yyyy-MM-dd'));
  const [endDate, setEndDate] = useState(format(new Date(), 'yyyy-MM-dd'));
  const [exportFormat, setExportFormat] = useState<'pdf' | 'csv'>('pdf');

  const [summaryData, setSummaryData] = useState<ActivitySummaryData[]>([]);
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
    const range = getDateRange();
    setStartDate(range.start);
    setEndDate(range.end);
  };

  /**
   * Load activity summary data
   */
  const loadData = useCallback(async () => {
    setDataLoading(true);
    setDataError(null);

    try {
      const range = getDateRange();

      const { data, error } = await supabaseClient.rpc('get_team_activity_summary', {
        p_start_date: range.start,
        p_end_date: range.end,
        p_team_id: null, // All teams
      });

      if (error) throw new Error(error.message);

      const rows = (data || []) as ActivitySummaryData[];
      setSummaryData(rows);
    } catch (err) {
      setDataError(err instanceof Error ? err.message : 'Échec du chargement des données');
      setSummaryData([]);
    } finally {
      setDataLoading(false);
    }
  }, [getDateRange]);

  /**
   * Handle export
   */
  const handleExport = async () => {
    const range = getDateRange();

    // For CSV, export directly on client side
    if (exportFormat === 'csv' && summaryData.length > 0) {
      exportActivitySummaryToCsv(summaryData, {
        reportType: 'Team Activity Summary',
        dateRange: `${range.start} to ${range.end}`,
        generatedAt: new Date().toISOString(),
        totalRecords: summaryData.length,
      });
      return;
    }

    // For PDF, use server-side generation
    await generate('activity_summary', {
      date_range: {
        start: range.start,
        end: range.end,
      },
      employee_filter: 'all',
      format: exportFormat,
    });
  };

  // Calculate aggregated metrics from data
  const aggregateMetrics = summaryData.reduce(
    (acc, row) => {
      acc.totalHours += row.total_hours || 0;
      acc.totalShifts += row.total_shifts || 0;
      acc.employeesActive = Math.max(acc.employeesActive, row.employees_active || 0);
      return acc;
    },
    { totalHours: 0, totalShifts: 0, employeesActive: 0 }
  );

  const avgHoursPerEmployee =
    aggregateMetrics.employeesActive > 0
      ? (aggregateMetrics.totalHours / aggregateMetrics.employeesActive).toFixed(1)
      : '0';

  const isGenerating = state === 'generating' || state === 'polling';

  return (
    <div className="space-y-6">
      {/* Page header */}
      <div>
        <h1 className="text-2xl font-bold text-slate-900 flex items-center gap-2">
          <BarChart3 className="h-6 w-6" />
          Résumé d&apos;activité de l&apos;équipe
        </h1>
        <p className="text-sm text-slate-500 mt-1">
          Générez des métriques agrégées d&apos;équipe pour la planification et les rapports
        </p>
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        {/* Configuration Panel */}
        <div className="space-y-6">
          <Card>
            <CardHeader>
              <CardTitle>Configuration du rapport</CardTitle>
              <CardDescription>
                Sélectionnez la plage de dates et le format d&apos;export
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-6">
              {/* Date range preset */}
              <div className="space-y-2">
                <Label>Plage de dates</Label>
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
                    <Label htmlFor="start-date">Date de début</Label>
                    <Input
                      id="start-date"
                      type="date"
                      value={startDate}
                      onChange={(e) => setStartDate(e.target.value)}
                      max={endDate}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="end-date">Date de fin</Label>
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

              {/* Format selection */}
              <div className="space-y-2">
                <Label>Format d&apos;export</Label>
                <Select
                  value={exportFormat}
                  onValueChange={(v) => setExportFormat(v as 'pdf' | 'csv')}
                >
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="pdf">
                      PDF - Document formaté avec graphiques
                    </SelectItem>
                    <SelectItem value="csv">
                      CSV - Format tableur pour Excel/Sheets
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
                  {dataLoading ? 'Chargement...' : 'Charger les données'}
                </Button>
                <Button
                  onClick={handleExport}
                  disabled={isGenerating || summaryData.length === 0}
                  className="flex-1"
                >
                  <Download className="mr-2 h-4 w-4" />
                  Exporter {exportFormat.toUpperCase()}
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
              reportType="activity_summary"
              format={exportFormat}
              recordCount={recordCount || undefined}
            />
          )}

          {/* Summary metrics */}
          {summaryData.length > 0 ? (
            <Card>
              <CardHeader>
                <CardTitle>Résumé d&apos;activité</CardTitle>
                <CardDescription>
                  {getDateRange().start} to {getDateRange().end}
                </CardDescription>
              </CardHeader>
              <CardContent>
                {/* Metrics grid */}
                <div className="grid grid-cols-2 gap-4 mb-6">
                  <div className="rounded-lg bg-blue-50 p-4">
                    <div className="flex items-center gap-2 text-blue-600 mb-1">
                      <Clock className="h-4 w-4" />
                      <span className="text-sm font-medium">Heures totales</span>
                    </div>
                    <p className="text-2xl font-bold text-blue-900">
                      {aggregateMetrics.totalHours.toFixed(1)}
                    </p>
                  </div>
                  <div className="rounded-lg bg-green-50 p-4">
                    <div className="flex items-center gap-2 text-green-600 mb-1">
                      <TrendingUp className="h-4 w-4" />
                      <span className="text-sm font-medium">Quarts totaux</span>
                    </div>
                    <p className="text-2xl font-bold text-green-900">
                      {aggregateMetrics.totalShifts}
                    </p>
                  </div>
                  <div className="rounded-lg bg-purple-50 p-4">
                    <div className="flex items-center gap-2 text-purple-600 mb-1">
                      <Users className="h-4 w-4" />
                      <span className="text-sm font-medium">Employés actifs</span>
                    </div>
                    <p className="text-2xl font-bold text-purple-900">
                      {aggregateMetrics.employeesActive}
                    </p>
                  </div>
                  <div className="rounded-lg bg-orange-50 p-4">
                    <div className="flex items-center gap-2 text-orange-600 mb-1">
                      <BarChart3 className="h-4 w-4" />
                      <span className="text-sm font-medium">Moy. heures/employé</span>
                    </div>
                    <p className="text-2xl font-bold text-orange-900">
                      {avgHoursPerEmployee}
                    </p>
                  </div>
                </div>

                {/* Day of week breakdown */}
                {summaryData[0]?.hours_by_day && (
                  <div>
                    <h4 className="text-sm font-medium text-slate-700 mb-3">
                      Heures par jour de la semaine
                    </h4>
                    <div className="flex justify-between items-end gap-1 h-32">
                      {[
                        { key: 'Mon', label: 'Lun' },
                        { key: 'Tue', label: 'Mar' },
                        { key: 'Wed', label: 'Mer' },
                        { key: 'Thu', label: 'Jeu' },
                        { key: 'Fri', label: 'Ven' },
                        { key: 'Sat', label: 'Sam' },
                        { key: 'Sun', label: 'Dim' },
                      ].map(({ key, label }) => {
                        const totalHours = summaryData.reduce(
                          (sum, row) => sum + (row.hours_by_day?.[key] || 0),
                          0
                        );
                        const maxHours = Math.max(
                          ...['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((d) =>
                            summaryData.reduce(
                              (sum, row) => sum + (row.hours_by_day?.[d] || 0),
                              0
                            )
                          ),
                          1
                        );
                        const height = (totalHours / maxHours) * 100;

                        return (
                          <div
                            key={key}
                            className="flex flex-col items-center gap-1 flex-1"
                          >
                            <span className="text-xs text-slate-600">
                              {totalHours.toFixed(0)}h
                            </span>
                            <div
                              className="w-full bg-blue-500 rounded-t transition-all"
                              style={{ height: `${Math.max(height, 4)}%` }}
                            />
                            <span className="text-xs text-slate-500">{label}</span>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                )}
              </CardContent>
            </Card>
          ) : dataLoading ? (
            <Card>
              <CardContent className="flex flex-col items-center justify-center py-12">
                <RefreshCw className="h-8 w-8 text-slate-400 animate-spin mb-4" />
                <p className="text-slate-500">Chargement des données d&apos;activité...</p>
              </CardContent>
            </Card>
          ) : dataError ? (
            <Alert variant="destructive">
              <AlertTitle>Erreur de chargement des données</AlertTitle>
              <AlertDescription>{dataError}</AlertDescription>
            </Alert>
          ) : (
            <Card className="border-dashed">
              <CardContent className="flex flex-col items-center justify-center py-12 text-center">
                <BarChart3 className="h-12 w-12 text-slate-300 mb-4" />
                <h3 className="text-lg font-medium text-slate-900 mb-1">
                  Aucune donnée chargée
                </h3>
                <p className="text-sm text-slate-500 max-w-sm">
                  Sélectionnez une plage de dates et cliquez sur &quot;Charger les données&quot; pour voir les métriques
                  d&apos;activité de l&apos;équipe.
                </p>
              </CardContent>
            </Card>
          )}
        </div>
      </div>

      {/* Help text */}
      <Alert>
        <BarChart3 className="h-4 w-4" />
        <AlertTitle>À propos du résumé d&apos;activité de l&apos;équipe</AlertTitle>
        <AlertDescription>
          <ul className="list-disc list-inside mt-2 space-y-1 text-sm">
            <li>Affiche les heures agrégées, les quarts et les métriques des employés</li>
            <li>La répartition par jour de la semaine aide à identifier les jours chargés/calmes</li>
            <li>L&apos;export PDF inclut des graphiques formatés et des tableaux récapitulatifs</li>
            <li>L&apos;export CSV inclut toutes les données pour une analyse personnalisée</li>
          </ul>
        </AlertDescription>
      </Alert>
    </div>
  );
}
