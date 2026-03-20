'use client';

import { useState, useCallback, useMemo } from 'react';
import { AlertCircle, RefreshCw, Pause, Play } from 'lucide-react';
import { Card, CardContent } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { useGpsDiagnosticsSummary } from '@/lib/hooks/use-gps-diagnostics-summary';
import { useGpsDiagnosticsTrend } from '@/lib/hooks/use-gps-diagnostics-trend';
import { useGpsDiagnosticsRanking } from '@/lib/hooks/use-gps-diagnostics-ranking';
import { useGpsDiagnosticsFeed } from '@/lib/hooks/use-gps-diagnostics-feed';
import { GpsKpiCards } from '@/components/diagnostics/gps-kpi-cards';
import { GpsTrendChart } from '@/components/diagnostics/gps-trend-chart';
import { GpsEmployeeRanking } from '@/components/diagnostics/gps-employee-ranking';
import { GpsIncidentFeed } from '@/components/diagnostics/gps-incident-feed';
import { GpsDetailDrawer } from '@/components/diagnostics/gps-detail-drawer';
import type { DrawerState, DiagnosticSeverity, GpsRankedEmployee, GpsFeedItem } from '@/types/gps-diagnostics';

// Date helpers
function todayStart(): string {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.toISOString();
}

function todayEnd(): string {
  const d = new Date();
  d.setDate(d.getDate() + 1);
  d.setHours(0, 0, 0, 0);
  return d.toISOString();
}

function daysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  d.setHours(0, 0, 0, 0);
  return d.toISOString();
}

const DATE_RANGES = [
  { label: "Aujourd'hui", start: () => todayStart(), end: () => todayEnd(), compareStart: () => daysAgo(1), compareEnd: () => todayStart() },
  { label: '7 jours', start: () => daysAgo(7), end: () => todayEnd(), compareStart: () => daysAgo(14), compareEnd: () => daysAgo(7) },
  { label: '14 jours', start: () => daysAgo(14), end: () => todayEnd(), compareStart: () => daysAgo(28), compareEnd: () => daysAgo(14) },
  { label: '30 jours', start: () => daysAgo(30), end: () => todayEnd(), compareStart: () => daysAgo(60), compareEnd: () => daysAgo(30) },
];

export default function DiagnosticsPage() {
  // Filters
  const [dateRangeIdx, setDateRangeIdx] = useState(1); // Default: 7 jours
  const [employeeFilter, setEmployeeFilter] = useState<string | null>(null);
  const [activeSeverities, setActiveSeverities] = useState<DiagnosticSeverity[]>(['warn', 'error', 'critical']);
  const [autoRefresh, setAutoRefresh] = useState(true);

  // Drawer
  const [drawer, setDrawer] = useState<DrawerState>({
    isOpen: false,
    employeeId: null,
    employeeName: null,
    devicePlatform: null,
    deviceModel: null,
  });

  const range = DATE_RANGES[dateRangeIdx];
  const startDate = useMemo(() => range.start(), [dateRangeIdx]);
  const endDate = useMemo(() => range.end(), [dateRangeIdx]);
  const compareStartDate = useMemo(() => range.compareStart(), [dateRangeIdx]);
  const compareEndDate = useMemo(() => range.compareEnd(), [dateRangeIdx]);

  // Data hooks
  const summary = useGpsDiagnosticsSummary(startDate, endDate, compareStartDate, compareEndDate, employeeFilter);
  const trend = useGpsDiagnosticsTrend(startDate, endDate, employeeFilter);
  const ranking = useGpsDiagnosticsRanking(startDate, endDate);
  const feed = useGpsDiagnosticsFeed(startDate, endDate, activeSeverities, employeeFilter, autoRefresh);

  // Handlers
  const openDrawerForEmployee = useCallback((emp: GpsRankedEmployee) => {
    setDrawer({
      isOpen: true,
      employeeId: emp.employeeId,
      employeeName: emp.fullName,
      devicePlatform: emp.devicePlatform,
      deviceModel: emp.deviceModel,
    });
  }, []);

  const openDrawerForFeedItem = useCallback((item: GpsFeedItem) => {
    setDrawer({
      isOpen: true,
      employeeId: item.employeeId,
      employeeName: item.fullName,
      devicePlatform: item.devicePlatform,
      deviceModel: item.deviceModel,
    });
  }, []);

  const closeDrawer = useCallback(() => {
    setDrawer((prev) => ({ ...prev, isOpen: false }));
  }, []);

  const toggleSeverity = useCallback((sev: DiagnosticSeverity) => {
    setActiveSeverities((prev) =>
      prev.includes(sev) ? prev.filter((s) => s !== sev) : [...prev, sev]
    );
  }, []);

  // Find ranking data for drawer employee
  const drawerRankingData = useMemo(() => {
    if (!drawer.employeeId) return null;
    return ranking.data.find((e) => e.employeeId === drawer.employeeId) ?? null;
  }, [drawer.employeeId, ranking.data]);

  const hasError = summary.error || trend.error || ranking.error || feed.error;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 className="text-2xl font-bold text-slate-900">GPS Diagnostics</h2>
          <div className="flex items-center gap-2 mt-1">
            <p className="text-sm text-slate-500">
              Monitoring des coupures GPS
            </p>
            <button
              onClick={() => setAutoRefresh((v) => !v)}
              className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium cursor-pointer ${
                autoRefresh ? 'bg-green-100 text-green-700' : 'bg-slate-100 text-slate-500'
              }`}
            >
              {autoRefresh ? <Play className="h-3 w-3" /> : <Pause className="h-3 w-3" />}
              {autoRefresh ? 'Live 30s' : 'Paused'}
            </button>
          </div>
        </div>
        <div className="flex gap-2 flex-wrap items-center">
          {DATE_RANGES.map((r, idx) => (
            <button
              key={r.label}
              onClick={() => setDateRangeIdx(idx)}
              className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-colors cursor-pointer ${
                dateRangeIdx === idx
                  ? 'bg-slate-900 text-white'
                  : 'bg-white border border-slate-200 text-slate-600 hover:bg-slate-50'
              }`}
            >
              {r.label}
            </button>
          ))}
          <Select
            value={employeeFilter ?? 'all'}
            onValueChange={(val) => setEmployeeFilter(val === 'all' ? null : val)}
          >
            <SelectTrigger className="w-[180px] h-9">
              <SelectValue placeholder="Tous les employés" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Tous les employés</SelectItem>
              {ranking.data.map((emp) => (
                <SelectItem key={emp.employeeId} value={emp.employeeId}>
                  {emp.fullName}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      {/* Error banner */}
      {hasError && (
        <Card className="border-red-200 bg-red-50">
          <CardContent className="flex items-center gap-3 py-3">
            <AlertCircle className="h-5 w-5 text-red-600" />
            <div className="text-sm text-red-700 flex-1">
              Erreur lors du chargement des données diagnostiques
            </div>
            <Button variant="outline" size="sm" onClick={() => summary.refetch()}>
              <RefreshCw className="h-3 w-3 mr-1" /> Réessayer
            </Button>
          </CardContent>
        </Card>
      )}

      {/* KPI Cards */}
      <GpsKpiCards
        primary={summary.data?.primary ?? null}
        comparison={summary.data?.comparison ?? null}
        isLoading={summary.isLoading}
      />

      {/* Chart + Ranking grid */}
      <div className="grid gap-6 lg:grid-cols-5">
        <div className="lg:col-span-3">
          <GpsTrendChart data={trend.data} isLoading={trend.isLoading} />
        </div>
        <div className="lg:col-span-2">
          <GpsEmployeeRanking
            data={ranking.data}
            isLoading={ranking.isLoading}
            onSelect={openDrawerForEmployee}
          />
        </div>
      </div>

      {/* Incident Feed */}
      <GpsIncidentFeed
        items={feed.items}
        isLoading={feed.isLoading}
        hasMore={feed.hasMore}
        onLoadMore={feed.loadMore}
        onRowClick={openDrawerForFeedItem}
        activeSeverities={activeSeverities}
        onToggleSeverity={toggleSeverity}
      />

      {/* Detail Drawer */}
      {drawer.employeeId && (
        <GpsDetailDrawer
          drawer={drawer}
          onClose={closeDrawer}
          startDate={startDate}
          endDate={endDate}
          rankingData={drawerRankingData}
        />
      )}

      {/* Drawer overlay */}
      {drawer.isOpen && (
        <div
          className="fixed inset-0 bg-black/20 z-40"
          onClick={closeDrawer}
        />
      )}
    </div>
  );
}
